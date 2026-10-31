package isureal

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo/v5"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

type searchUsersRequest struct {
	Q              string `query:"q"`
	BeforeUsername string `query:"beforeUsername"`
	BeforeID       string `query:"beforeId"`
}

type searchUsersResponse struct {
	Items   []relationshipUserResponse `json:"items"`
	HasMore bool                       `json:"hasMore"`
}

func normalizeSearchText(value string) string {
	return norm.NFC.String(cases.Fold().String(norm.NFC.String(value)))
}

const userRowFingerprintExpr = `hashtextextended(id || ':' || updated_at::text || ':' || status || ':' || display_name || ':' || bio || ':' || account_type || ':' || COALESCE(profile_image_id, ''), 0)`
const userRowFingerprintExprU = `hashtextextended(u.id || ':' || u.updated_at::text || ':' || u.status || ':' || u.display_name || ':' || u.bio || ':' || u.account_type || ':' || COALESCE(u.profile_image_id, ''), 0)`

type cachedSearchUser struct {
	User
	UpdatedAt       time.Time
	RowFP           int64
	NormUsername    string
	NormDisplayName string
}

type userSearchCacheStore struct {
	mu           sync.Mutex
	loaded       bool
	byID         map[string]cachedSearchUser
	sortedActive []cachedSearchUser
	maxUpdatedAt time.Time
	totalFP      int64
}

var globalUserSearchCache = &userSearchCacheStore{
	byID: make(map[string]cachedSearchUser),
}

func compareSearchUsers(a, b cachedSearchUser) int {
	if c := cmp.Compare(a.Username, b.Username); c != 0 {
		return c
	}
	return cmp.Compare(a.ID, b.ID)
}

func buildCachedSearchUser(u User, updatedAt time.Time, rowFP int64) (cachedSearchUser, error) {
	if err := u.setImageKey(); err != nil {
		return cachedSearchUser{}, err
	}
	return cachedSearchUser{
		User:            u,
		UpdatedAt:       updatedAt,
		RowFP:           rowFP,
		NormUsername:    normalizeSearchText(u.Username),
		NormDisplayName: normalizeSearchText(u.DisplayName),
	}, nil
}

func (c *userSearchCacheStore) rebuildSortedLocked() {
	active := make([]cachedSearchUser, 0, len(c.byID))
	var maxUpd time.Time
	var xorFP int64
	for _, entry := range c.byID {
		xorFP ^= entry.RowFP
		if entry.UpdatedAt.After(maxUpd) {
			maxUpd = entry.UpdatedAt
		}
		if entry.Status == "active" {
			active = append(active, entry)
		}
	}
	slices.SortFunc(active, compareSearchUsers)
	c.sortedActive = active
	c.maxUpdatedAt = maxUpd
	c.totalFP = xorFP
}

func (c *userSearchCacheStore) reloadFullLocked(ctx context.Context, db *sqlx.DB) error {
	var rows []struct {
		User
		UpdatedAt time.Time `db:"updated_at"`
		RowFP     int64     `db:"row_fp"`
	}
	query := `SELECT ` + strings.Join(userColumns, ", ") + `, updated_at, ` + userRowFingerprintExpr + ` AS row_fp FROM users`
	if err := db.SelectContext(ctx, &rows, query); err != nil {
		return err
	}
	byID := make(map[string]cachedSearchUser, len(rows))
	for _, r := range rows {
		entry, err := buildCachedSearchUser(r.User, r.UpdatedAt, r.RowFP)
		if err != nil {
			return err
		}
		byID[r.ID] = entry
	}
	c.byID = byID
	c.rebuildSortedLocked()
	c.loaded = true
	return nil
}

func (c *userSearchCacheStore) getActiveUsers(ctx context.Context, db *sqlx.DB) ([]cachedSearchUser, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.loaded {
		if err := c.reloadFullLocked(ctx, db); err != nil {
			return nil, err
		}
		return c.sortedActive, nil
	}

	cutoff := c.maxUpdatedAt.Add(-5 * time.Second)
	var deltaRows []struct {
		TotalCount     int        `db:"total_count"`
		DBFingerprint  int64      `db:"db_fp"`
		ID             *string    `db:"id"`
		Username       *string    `db:"username"`
		SecretKeyHash  *string    `db:"secret_key_hash"`
		DisplayName    *string    `db:"display_name"`
		Bio            *string    `db:"bio"`
		ProfileImageID *string    `db:"profile_image_id"`
		Region         *string    `db:"region"`
		AccountType    *string    `db:"account_type"`
		Status         *string    `db:"status"`
		UpdatedAt      *time.Time `db:"updated_at"`
		RowFP          *int64     `db:"row_fp"`
	}
	deltaQuery := `
		WITH stats AS (
			SELECT count(*) AS total_count,
			       COALESCE(bit_xor(` + userRowFingerprintExpr + `), 0) AS db_fp
			FROM users
		)
		SELECT s.total_count, s.db_fp,
		       u.id, u.username, u.secret_key_hash, u.display_name, u.bio, u.profile_image_id,
		       u.region, u.account_type, u.status, u.updated_at,
		       ` + userRowFingerprintExprU + ` AS row_fp
		FROM stats s
		LEFT JOIN users u ON u.updated_at >= $1
	`
	if err := db.SelectContext(ctx, &deltaRows, deltaQuery, cutoff); err != nil {
		return nil, err
	}
	if len(deltaRows) == 0 {
		return c.sortedActive, nil
	}

	totalCount := deltaRows[0].TotalCount
	dbFP := deltaRows[0].DBFingerprint

	changed := false
	for _, r := range deltaRows {
		if r.ID == nil {
			continue
		}
		if existing, ok := c.byID[*r.ID]; ok && existing.RowFP == *r.RowFP {
			continue
		}
		u := User{
			ID:             *r.ID,
			Username:       *r.Username,
			SecretKeyHash:  *r.SecretKeyHash,
			DisplayName:    *r.DisplayName,
			Bio:            *r.Bio,
			ProfileImageID: r.ProfileImageID,
			Region:         *r.Region,
			AccountType:    *r.AccountType,
			Status:         *r.Status,
		}
		entry, err := buildCachedSearchUser(u, *r.UpdatedAt, *r.RowFP)
		if err != nil {
			return nil, err
		}
		if existing, ok := c.byID[u.ID]; ok {
			c.totalFP ^= existing.RowFP
		}
		c.byID[u.ID] = entry
		c.totalFP ^= entry.RowFP
		if entry.UpdatedAt.After(c.maxUpdatedAt) {
			c.maxUpdatedAt = entry.UpdatedAt
		}
		changed = true
	}

	if len(c.byID) != totalCount || c.totalFP != dbFP {
		if err := c.reloadFullLocked(ctx, db); err != nil {
			return nil, err
		}
		return c.sortedActive, nil
	}

	if changed {
		c.rebuildSortedLocked()
	}
	return c.sortedActive, nil
}

func searchUsersHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input searchUsersRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		if !validUserText(input.Q, 1, 100) {
			return NewAPIError(http.StatusBadRequest, "invalid_relationship")
		}
		if (input.BeforeUsername == "") != (input.BeforeID == "") {
			return NewAPIError(http.StatusBadRequest, "invalid_pagination")
		}
		ctx := c.Request().Context()
		viewer := GetSession(c).UserID
		users, err := globalUserSearchCache.getActiveUsers(ctx, h.DB)
		if err != nil {
			return err
		}
		blocked, err := getBlockedUserIDs(ctx, h.DB, viewer)
		if err != nil {
			return err
		}
		startIdx := 0
		if input.BeforeUsername != "" {
			target := cachedSearchUser{User: User{Username: input.BeforeUsername, ID: input.BeforeID}}
			idx, found := slices.BinarySearchFunc(users, target, compareSearchUsers)
			if found {
				startIdx = idx + 1
			} else {
				startIdx = idx
			}
		}
		query := normalizeSearchText(input.Q)
		items := make([]relationshipUserResponse, 0)
		for i := startIdx; i < len(users); i++ {
			entry := users[i]
			if entry.ID == viewer {
				continue
			}
			if !strings.Contains(entry.NormUsername, query) && !strings.Contains(entry.NormDisplayName, query) {
				continue
			}
			if blocked[entry.ID] {
				continue
			}
			user := entry.User
			if user.AccountType != "certified_public" {
				user.Bio = ""
			}
			items = append(items, newRelationshipUserResponse(user))
			if len(items) == 51 {
				break
			}
		}
		hasMore := len(items) > 50
		if hasMore {
			items = items[:50]
		}
		return c.JSON(http.StatusOK, searchUsersResponse{Items: items, HasMore: hasMore})
	}
}

type getUserRequest struct {
	UserID string `param:"userId"`
}

type getUserResponse relationshipUserResponse

func getUserHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input getUserRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		ctx := c.Request().Context()
		viewer := GetSession(c).UserID
		user, err := getUser(ctx, h.DB, input.UserID)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "relationship_not_found")
		}
		if err != nil {
			return err
		}
		blocked, err := isBlocked(ctx, h.DB, viewer, user.ID)
		if err != nil {
			return err
		}
		if blocked {
			return NewAPIError(http.StatusNotFound, "relationship_not_found")
		}
		friends, err := getFriendIDs(ctx, h.DB, viewer)
		if err != nil {
			return err
		}
		if user.AccountType != "certified_public" && !slices.Contains(friends, user.ID) {
			user.Bio = ""
		}
		return c.JSON(http.StatusOK, getUserResponse(newRelationshipUserResponse(user)))
	}
}

func newRelationshipUserResponse(user User) relationshipUserResponse {
	return relationshipUserResponse{ID: user.ID, Username: user.Username, DisplayName: user.DisplayName, ProfileImageURL: newGetMeResponse(user).ProfileImageURL, Bio: user.Bio, AccountType: user.AccountType}
}

package isureal

import (
	"cmp"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

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

type cachedSearchUser struct {
	User
	NormUsername    string
	NormDisplayName string
}

type userSearchCacheStore struct {
	mu           sync.Mutex
	loaded       bool
	usernameByID map[string]string
	sortedActive []cachedSearchUser
	activePtr    atomic.Pointer[[]cachedSearchUser]
}

var globalUserSearchCache = &userSearchCacheStore{
	usernameByID: make(map[string]string),
}

func compareSearchUsers(a, b cachedSearchUser) int {
	if c := cmp.Compare(a.Username, b.Username); c != 0 {
		return c
	}
	return cmp.Compare(a.ID, b.ID)
}

func buildCachedSearchUser(u User) (cachedSearchUser, error) {
	if err := u.setImageKey(); err != nil {
		return cachedSearchUser{}, err
	}
	return cachedSearchUser{
		User:            u,
		NormUsername:    normalizeSearchText(u.Username),
		NormDisplayName: normalizeSearchText(u.DisplayName),
	}, nil
}

func (c *userSearchCacheStore) reloadFullLocked(ctx context.Context, db *sqlx.DB) error {
	var rows []User
	query := `SELECT ` + strings.Join(userColumns, ", ") + ` FROM users WHERE status = 'active'`
	if err := db.SelectContext(ctx, &rows, query); err != nil {
		return err
	}
	usernameByID := make(map[string]string, len(rows))
	active := make([]cachedSearchUser, 0, len(rows))
	for _, u := range rows {
		entry, err := buildCachedSearchUser(u)
		if err != nil {
			return err
		}
		usernameByID[u.ID] = u.Username
		active = append(active, entry)
	}
	slices.SortFunc(active, compareSearchUsers)
	c.usernameByID = usernameByID
	c.sortedActive = active
	c.loaded = true
	c.activePtr.Store(&active)
	return nil
}

func (c *userSearchCacheStore) ReloadAll(ctx context.Context, db *sqlx.DB) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reloadFullLocked(ctx, db)
}

func (c *userSearchCacheStore) UpsertUser(u User) {
	if u.Status != "active" {
		c.DeleteUser(u.ID)
		return
	}
	entry, err := buildCachedSearchUser(u)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.loaded {
		return
	}
	c.usernameByID[u.ID] = u.Username
	idx, found := slices.BinarySearchFunc(c.sortedActive, entry, compareSearchUsers)
	var next []cachedSearchUser
	if found {
		next = slices.Clone(c.sortedActive)
		next[idx] = entry
	} else {
		next = make([]cachedSearchUser, len(c.sortedActive)+1)
		copy(next[:idx], c.sortedActive[:idx])
		next[idx] = entry
		copy(next[idx+1:], c.sortedActive[idx:])
	}
	c.sortedActive = next
	c.activePtr.Store(&next)
}

func (c *userSearchCacheStore) DeleteUser(userID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.loaded {
		return
	}
	username, ok := c.usernameByID[userID]
	if !ok {
		return
	}
	delete(c.usernameByID, userID)
	target := cachedSearchUser{User: User{Username: username, ID: userID}}
	idx, found := slices.BinarySearchFunc(c.sortedActive, target, compareSearchUsers)
	if !found {
		return
	}
	next := make([]cachedSearchUser, len(c.sortedActive)-1)
	copy(next[:idx], c.sortedActive[:idx])
	copy(next[idx:], c.sortedActive[idx+1:])
	c.sortedActive = next
	c.activePtr.Store(&next)
}

func (c *userSearchCacheStore) ApplyNotify(ctx context.Context, db *sqlx.DB, payload string) {
	if payload == "" || payload == "*" {
		_ = c.ReloadAll(ctx, db)
		return
	}
	var msg struct {
		Op             string  `json:"op"`
		ID             string  `json:"id"`
		Username       string  `json:"username"`
		SecretKeyHash  string  `json:"secret_key_hash"`
		DisplayName    string  `json:"display_name"`
		Bio            string  `json:"bio"`
		ProfileImageID *string `json:"profile_image_id"`
		Region         string  `json:"region"`
		AccountType    string  `json:"account_type"`
		Status         string  `json:"status"`
	}
	if err := json.Unmarshal([]byte(payload), &msg); err != nil {
		_ = c.ReloadAll(ctx, db)
		return
	}
	if msg.Op == "delete" || msg.Status != "active" {
		c.DeleteUser(msg.ID)
		return
	}
	c.UpsertUser(User{
		ID:             msg.ID,
		Username:       msg.Username,
		SecretKeyHash:  msg.SecretKeyHash,
		DisplayName:    msg.DisplayName,
		Bio:            msg.Bio,
		ProfileImageID: msg.ProfileImageID,
		Region:         msg.Region,
		AccountType:    msg.AccountType,
		Status:         msg.Status,
	})
}

func (c *userSearchCacheStore) getActiveUsers(ctx context.Context, db *sqlx.DB) ([]cachedSearchUser, error) {
	if ptr := c.activePtr.Load(); ptr != nil {
		return *ptr, nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if ptr := c.activePtr.Load(); ptr != nil {
		return *ptr, nil
	}
	if err := c.reloadFullLocked(ctx, db); err != nil {
		return nil, err
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
		var row struct {
			User
			IsBlocked bool `db:"is_blocked"`
			IsFriend  bool `db:"is_friend"`
		}
		err := h.DB.GetContext(ctx, &row, `
			SELECT `+strings.Join(userColumns, ", ")+`,
			       EXISTS(SELECT 1 FROM block_relations WHERE (blocker_id = $2 AND blocked_id = u.id) OR (blocker_id = u.id AND blocked_id = $2)) AS is_blocked,
			       EXISTS(SELECT 1 FROM friendships WHERE user_low_id = $3 AND user_high_id = $4) AS is_friend
			FROM users u
			WHERE u.id = $1 AND u.status = 'active'
		`, input.UserID, viewer, min(viewer, input.UserID), max(viewer, input.UserID))
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "relationship_not_found")
		}
		if err != nil {
			return err
		}
		if row.IsBlocked {
			return NewAPIError(http.StatusNotFound, "relationship_not_found")
		}
		user := row.User
		if err := user.setImageKey(); err != nil {
			return err
		}
		if user.AccountType != "certified_public" && !row.IsFriend {
			user.Bio = ""
		}
		return c.JSON(http.StatusOK, getUserResponse(newRelationshipUserResponse(user)))
	}
}

func newRelationshipUserResponse(user User) relationshipUserResponse {
	return relationshipUserResponse{ID: user.ID, Username: user.Username, DisplayName: user.DisplayName, ProfileImageURL: newGetMeResponse(user).ProfileImageURL, Bio: user.Bio, AccountType: user.AccountType}
}

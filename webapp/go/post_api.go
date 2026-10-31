package isureal

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"image/jpeg"
	"io"
	"mime/multipart"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v5"
)

type createPostRequest struct {
	Image        *multipart.FileHeader `form:"image"`
	Caption      string                `form:"caption"`
	Visibility   string                `form:"visibility"`
	LocationKind string                `form:"location_kind"`
	Latitude     *float64              `form:"latitude"`
	Longitude    *float64              `form:"longitude"`
	Locality     *string               `form:"locality"`
}

type postAuthorResponse struct {
	ID              string  `json:"id"`
	Username        string  `json:"username"`
	DisplayName     string  `json:"displayName"`
	ProfileImageURL *string `json:"profileImageUrl"`
	Bio             string  `json:"bio"`
	AccountType     string  `json:"accountType"`
}

type createPostResponse struct {
	ID              string             `json:"id"`
	Author          postAuthorResponse `json:"author"`
	PostingWindowID string             `json:"postingWindowId"`
	ImageURL        string             `json:"imageUrl"`
	Caption         string             `json:"caption"`
	Visibility      string             `json:"visibility"`
	Location        PostLocation       `json:"location"`
	PostedAt        time.Time          `json:"postedAt"`
	OnTime          bool               `json:"onTime"`
	LateSeconds     int64              `json:"lateSeconds"`
}

func createPostHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input createPostRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		if input.Image == nil || !validUserText(input.Caption, 0, 1000) {
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}
		switch input.Visibility {
		case "friends", "friends_of_friends", "public":
		default:
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}
		location := PostLocation{
			Kind: input.LocationKind, Latitude: input.Latitude,
			Longitude: input.Longitude, Locality: input.Locality,
		}
		if !location.valid() {
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}
		imageFile, err := input.Image.Open()
		if err != nil {
			return err
		}
		defer imageFile.Close()
		imageData, err := io.ReadAll(imageFile)
		if err != nil {
			return err
		}
		// 投稿画像は元データを保存するため、寸法の確認だけで全画素を展開しない。
		config, err := jpeg.DecodeConfig(bytes.NewReader(imageData))
		if err != nil {
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}
		if config.Width > 4096 || config.Height > 4096 {
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}

		ctx := c.Request().Context()
		userID := GetSession(c).UserID

		// 画像の INSERT は users と posting_windows の行ロックを取る前に、トランザクションの外で済ませる。
		// (数百 KB の bytea の書き込みの間、同じリージョンの投稿と投稿期間の切り替えを止めないため。)
		// 以降の処理が失敗したら孤児になるので、下の defer で消す。孤児は posts / profile / realmoji の
		// どれからも参照されず、image_api.go は参照のない画像を配信しない。
		imageID := uuid.NewString()
		imageCreatedAt := time.Now().UTC()
		if _, err := h.DB.ExecContext(ctx, `INSERT INTO image_objects (id, owner_user_id, data, media_type, created_at) VALUES ($1, $2, $3, 'image/jpeg', $4)`, imageID, userID, imageData, imageCreatedAt); err != nil {
			return err
		}
		committed := false
		defer func() {
			if committed {
				return
			}
			// リクエストが中断されていても消す。created_at を条件に入れてパーティションを絞る。
			cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			_, _ = h.DB.ExecContext(cleanupCtx, `DELETE FROM image_objects WHERE id = $1 AND created_at = $2`, imageID, imageCreatedAt)
		}()

		postID := uuid.NewString()
		var row struct {
			User
			WindowID       *string    `db:"window_id"`
			OnTimeDeadline *time.Time `db:"on_time_deadline"`
			InsertedPostID *string    `db:"inserted_post_id"`
			PostedAt       *time.Time `db:"posted_at"`
		}
		const createPostCTE = `
			WITH u AS (
				SELECT id, username, secret_key_hash, display_name, bio, profile_image_id, region, account_type, status
				FROM users
				WHERE id = $1 AND status = 'active'
				FOR NO KEY UPDATE
			), w AS (
				SELECT pw.id, pw.local_date, pw.starts_at, pw.on_time_deadline
				FROM posting_windows pw
				JOIN u ON pw.region = u.region
				WHERE pw.ended_at IS NULL
				FOR UPDATE OF pw
			), ts AS (
				SELECT clock_timestamp() AS posted_at FROM w
			), counts AS (
				SELECT count(*) FILTER (WHERE p.deleted_at IS NULL) AS active,
				       count(*) FILTER (WHERE p.deleted_at IS NOT NULL) AS deleted
				FROM posts p
				JOIN posting_windows pw2 ON pw2.id = p.posting_window_id
				JOIN w ON pw2.local_date = w.local_date
				WHERE p.author_id = $1
			), ins AS (
				INSERT INTO posts (id, author_id, posting_window_id, image_id, caption, visibility,
				                   location_kind, latitude, longitude, locality, posted_at)
				SELECT $2, u.id, w.id, $3, $4, $5, $6, $7, $8, $9, ts.posted_at
				FROM u, w, counts c, ts
				WHERE c.active = 0 AND c.deleted < 2 AND ts.posted_at >= w.starts_at
				RETURNING id, posted_at
			)
			SELECT u.id, u.username, u.secret_key_hash, u.display_name, u.bio, u.profile_image_id, u.region, u.account_type, u.status,
			       w.id AS window_id,
			       w.on_time_deadline,
			       (SELECT id FROM ins) AS inserted_post_id,
			       (SELECT posted_at FROM ins) AS posted_at
			FROM u
			LEFT JOIN w ON true
		`
		err = h.DB.GetContext(ctx, &row, createPostCTE,
			userID, postID, imageID, input.Caption, input.Visibility,
			location.Kind, location.Latitude, location.Longitude, location.Locality)
		if err == nil && row.WindowID == nil {
			// 切り替え待ちの間に旧期間の行が終了すると、この文のスナップショットには新期間の行が見えず window_id が NULL になる。
			// 新期間を読み直すために1回再実行する。
			err = h.DB.GetContext(ctx, &row, createPostCTE,
				userID, postID, imageID, input.Caption, input.Visibility,
				location.Kind, location.Latitude, location.Longitude, location.Locality)
		}
		if err != nil {
			return err
		}
		if row.WindowID == nil || row.InsertedPostID == nil || row.PostedAt == nil {
			return NewAPIError(http.StatusConflict, "post_slot_unavailable")
		}
		committed = true
		user := row.User
		if err := user.setImageKey(); err != nil {
			return err
		}
		post := Post{
			ID:              postID,
			AuthorID:        userID,
			PostingWindowID: *row.WindowID,
			ImageID:         imageID,
			Caption:         input.Caption,
			Visibility:      input.Visibility,
			PostLocation:    location,
			PostedAt:        *row.PostedAt,
			OnTimeDeadline:  *row.OnTimeDeadline,
			WindowEndedAt:   nil,
		}
		h.ImageCache.Put(imageID, imageData)
		return c.JSON(http.StatusCreated, newPostResponse(post, user))
	}
}

func newPostResponse(post Post, user User) createPostResponse {
	response := createPostResponse{
		ID: post.ID,
		Author: postAuthorResponse{
			ID: user.ID, Username: user.Username, DisplayName: user.DisplayName,
			ProfileImageURL: newGetMeResponse(user).ProfileImageURL,
			Bio:             user.Bio, AccountType: user.AccountType,
		},
		PostingWindowID: post.PostingWindowID, ImageURL: signedImageURL(user, post.ImageID),
		Caption: post.Caption, Visibility: post.Visibility, Location: post.PostLocation,
		PostedAt: post.PostedAt, OnTime: !post.PostedAt.After(post.OnTimeDeadline),
	}
	if !response.OnTime {
		response.LateSeconds = int64(post.PostedAt.Sub(post.OnTimeDeadline) / time.Second)
	}
	return response
}

type getMyCurrentPostResponse createPostResponse

func getMyCurrentPostHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		ctx := c.Request().Context()
		session := GetSession(c)
		var post Post
		err := h.DB.GetContext(ctx, &post, `
			SELECT `+postColumns+`
			FROM posts p
			JOIN posting_windows w ON w.id = p.posting_window_id
			JOIN posting_windows current ON current.region = $2 AND current.ended_at IS NULL
			                            AND current.local_date = w.local_date
			WHERE p.author_id = $1 AND p.deleted_at IS NULL
		`, session.UserID, session.Region)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "post_not_found")
		}
		if err != nil {
			return err
		}
		return c.JSON(http.StatusOK, getMyCurrentPostResponse(newPostResponse(post, session.User)))
	}
}

type getPostRequest struct {
	PostID string `param:"postId"`
}

type getPostResponse createPostResponse

func getPostHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input getPostRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		ctx := c.Request().Context()
		post, err := getPostWithAuthor(ctx, h.DB, input.PostID)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "post_not_found")
		}
		if err != nil {
			return err
		}
		viewer, err := loadViewerContext(ctx, h.DB, GetSession(c).UserID)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err != nil || !viewer.canView(post.Post) {
			return NewAPIError(http.StatusNotFound, "post_not_found")
		}
		return c.JSON(http.StatusOK, getPostResponse(newPostResponse(post.Post, post.Author)))
	}
}

type updatePostRequest struct {
	PostID     string  `param:"postId" json:"-"`
	Caption    *string `json:"caption"`
	Visibility *string `json:"visibility"`
}

type updatePostResponse createPostResponse

func updatePostHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input updatePostRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		if input.Caption == nil && input.Visibility == nil {
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}
		if input.Caption != nil && !validUserText(*input.Caption, 0, 1000) {
			return NewAPIError(http.StatusBadRequest, "invalid_post")
		}
		if input.Visibility != nil {
			switch *input.Visibility {
			case "friends", "friends_of_friends", "public":
			default:
				return NewAPIError(http.StatusBadRequest, "invalid_post")
			}
		}
		ctx := c.Request().Context()
		session := GetSession(c)
		userID := session.UserID
		tx, err := h.DB.BeginTxx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		var lockedUserID string
		if err := tx.GetContext(ctx, &lockedUserID, `SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE`, userID); err != nil {
			return err
		}
		post, err := getPost(ctx, tx, input.PostID)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "post_not_found")
		}
		if err != nil {
			return err
		}
		if post.AuthorID != userID || post.WindowEndedAt != nil {
			return NewAPIError(http.StatusForbidden, "post_not_editable")
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE posts
			SET caption = COALESCE($2, caption),
			    visibility = COALESCE($3, visibility)
			WHERE id = $1
		`, post.ID, input.Caption, input.Visibility); err != nil {
			return err
		}
		if input.Caption != nil {
			post.Caption = *input.Caption
		}
		if input.Visibility != nil {
			post.Visibility = *input.Visibility
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		return c.JSON(http.StatusOK, updatePostResponse(newPostResponse(post, session.User)))
	}
}

type deletePostRequest struct {
	PostID string `param:"postId" json:"-"`
}

func deletePostHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input deletePostRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		ctx := c.Request().Context()
		userID := GetSession(c).UserID
		tx, err := h.DB.BeginTxx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		var lockedUserID string
		if err := tx.GetContext(ctx, &lockedUserID, `SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE`, userID); err != nil {
			return err
		}
		post, err := getPost(ctx, tx, input.PostID)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "post_not_found")
		}
		if err != nil {
			return err
		}
		if post.AuthorID != userID {
			return NewAPIError(http.StatusForbidden, "post_not_editable")
		}
		window, err := getPostingWindow(ctx, tx, post.PostingWindowID)
		if err != nil {
			return err
		}
		var deletions int
		if err := tx.GetContext(ctx, &deletions, `
   SELECT count(*) FROM posts p JOIN posting_windows w ON w.id = p.posting_window_id
   WHERE p.author_id = $1 AND w.local_date = $2 AND p.deleted_at IS NOT NULL
  `, userID, window.LocalDate); err != nil {
			return err
		}
		if deletions >= 2 {
			return NewAPIError(http.StatusConflict, "post_slot_unavailable")
		}
		if _, err := tx.ExecContext(ctx, `UPDATE posts SET deleted_at = clock_timestamp() WHERE id = $1`, post.ID); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		return c.NoContent(http.StatusNoContent)
	}
}

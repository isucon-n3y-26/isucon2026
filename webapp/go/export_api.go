package isureal

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo/v5"
)

type exportPostResponse struct {
	createPostResponse
	ImagePath string `json:"imagePath"`
}

func exportPostsHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		ctx := c.Request().Context()
		userID := GetSession(c).UserID
		author, err := getUser(ctx, h.DB, userID)
		if err != nil {
			return err
		}
		var posts []Post
		if err := h.DB.SelectContext(ctx, &posts, `
   SELECT `+postColumns+`
   FROM posts p
   JOIN posting_windows w ON w.id = p.posting_window_id
   WHERE p.author_id = $1 AND p.deleted_at IS NULL
   ORDER BY p.posted_at, p.id
  `, userID); err != nil {
			return err
		}

		imageDataByID := make(map[string][]byte, len(posts))
		missingSet := make(map[string]struct{})
		var missingIDs []string
		for _, post := range posts {
			if _, ok := imageDataByID[post.ImageID]; ok {
				continue
			}
			if _, missing := missingSet[post.ImageID]; missing {
				continue
			}
			if data, ok := h.ImageCache.Get(post.ImageID); ok {
				imageDataByID[post.ImageID] = data
			} else {
				missingSet[post.ImageID] = struct{}{}
				missingIDs = append(missingIDs, post.ImageID)
			}
		}

		if len(missingIDs) > 0 {
			query, args, err := sqlx.In(`SELECT id, data FROM image_objects WHERE id IN (?)`, missingIDs)
			if err != nil {
				return err
			}
			var rows []struct {
				ID   string `db:"id"`
				Data []byte `db:"data"`
			}
			if err := h.DB.SelectContext(ctx, &rows, sqlx.Rebind(sqlx.DOLLAR, query), args...); err != nil {
				return err
			}
			for _, row := range rows {
				imageDataByID[row.ID] = row.Data
				h.ImageCache.Put(row.ID, row.Data)
			}
		}

		var body bytes.Buffer
		writer := zip.NewWriter(&body)
		defer writer.Close()
		items := make([]exportPostResponse, 0, len(posts))
		for _, post := range posts {
			imageData, ok := imageDataByID[post.ImageID]
			if !ok {
				continue
			}
			imagePath := fmt.Sprintf("images/%06d.jpg", len(items)+1)
			image, err := writer.CreateHeader(&zip.FileHeader{Name: imagePath, Method: zip.Store})
			if err != nil {
				return err
			}
			if _, err := image.Write(imageData); err != nil {
				return err
			}
			items = append(items, exportPostResponse{createPostResponse: newPostResponse(post, author), ImagePath: imagePath})
		}
		manifest, err := writer.Create("posts.json")
		if err != nil {
			return err
		}
		if err := json.NewEncoder(manifest).Encode(items); err != nil {
			return err
		}
		if err := writer.Close(); err != nil {
			return err
		}
		c.Response().Header().Set(echo.HeaderContentDisposition, `attachment; filename="isureal-posts.zip"`)
		c.Response().Header().Set(echo.HeaderCacheControl, "no-store")
		return c.Blob(http.StatusOK, "application/zip", body.Bytes())
	}
}

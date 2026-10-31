package isureal

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo/v5"
)

type getNotificationsResponse struct {
	ID              string    `json:"id" db:"id"`
	PostingWindowID string    `json:"postingWindowId" db:"posting_window_id"`
	Region          string    `json:"region" db:"region"`
	CreatedAt       time.Time `json:"createdAt" db:"created_at"`
}

func getNotificationsHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		ctx := c.Request().Context()
		session := GetSession(c)
		userID := session.UserID
		notificationEvents, unsubscribe := h.notificationHub.subscribe(userID)
		defer unsubscribe()
		baselineWindowID, err := getCurrentNotificationWindowID(ctx, h.DB, userID, session.Region)
		if err != nil {
			return err
		}

		response := c.Response()
		response.Header().Set("Content-Type", "text/event-stream")
		response.WriteHeader(http.StatusOK)
		controller := http.NewResponseController(response)
		if err := controller.Flush(); err != nil {
			return nil
		}
		checkAndDeliver := func() (bool, error) {
			var row struct {
				ValidRecipient  bool       `db:"valid_recipient"`
				ID              *string    `db:"id"`
				PostingWindowID *string    `db:"posting_window_id"`
				Region          *string    `db:"region"`
				CreatedAt       *time.Time `db:"created_at"`
			}
			err := h.DB.GetContext(ctx, &row, `
				SELECT (u.region = $2) AS valid_recipient,
				       n.id, w.id AS posting_window_id, w.region, n.created_at
				FROM users u
				LEFT JOIN posting_windows w ON w.region = $2 AND w.id <> $3 AND w.ended_at IS NULL
				LEFT JOIN notifications n ON n.posting_window_id = w.id AND n.user_id = u.id
				WHERE u.id = $1 AND u.status = 'active'
				LIMIT 1
			`, userID, session.Region, baselineWindowID)
			if errors.Is(err, sql.ErrNoRows) {
				return true, nil
			}
			if err != nil {
				return true, err
			}
			if !row.ValidRecipient {
				return true, nil
			}
			if row.ID == nil {
				return false, nil
			}
			notification := getNotificationsResponse{
				ID:              *row.ID,
				PostingWindowID: *row.PostingWindowID,
				Region:          *row.Region,
				CreatedAt:       *row.CreatedAt,
			}
			data, err := json.Marshal(notification)
			if err != nil {
				return true, err
			}
			if _, err := fmt.Fprintf(response, "data: %s\n\n", data); err != nil {
				return true, err
			}
			if err := controller.Flush(); err != nil {
				return true, err
			}
			return true, nil
		}
		for {
			select {
			case <-ctx.Done():
				return nil
			case <-notificationEvents:
				// Notifications are persisted in the table, so the event only wakes
				// this handler. The next iteration reads the committed row.
				done, err := checkAndDeliver()
				if err != nil {
					if ctx.Err() == nil {
						c.Logger().Error("failed to deliver notification", "error", err)
					}
					return nil
				}
				if done {
					return nil
				}
			}
		}
	}
}

func getCurrentNotificationWindowID(ctx context.Context, db *sqlx.DB, userID, region string) (string, error) {
	var windowID string
	err := db.GetContext(ctx, &windowID, `
    SELECT w.id
    FROM posting_windows w
    JOIN notifications n ON n.posting_window_id = w.id AND n.user_id = $1
    WHERE w.region = $2 AND w.ended_at IS NULL
    LIMIT 1
   `, userID, region)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return windowID, err
}

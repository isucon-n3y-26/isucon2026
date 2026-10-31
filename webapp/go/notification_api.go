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
		baselineWindowID, err := getCurrentNotificationWindowID(ctx, h.DB, userID, session.Region)
		if err != nil {
			return err
		}
		notificationEvents, unsubscribe := h.notificationHub.subscribe()
		defer unsubscribe()

		response := c.Response()
		response.Header().Set("Content-Type", "text/event-stream")
		response.WriteHeader(http.StatusOK)
		controller := http.NewResponseController(response)
		if err := controller.Flush(); err != nil {
			return nil
		}
		// Revalidate account and region changes infrequently while waiting. Notification
		// delivery itself is event-driven through PostgreSQL LISTEN/NOTIFY.
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		checkRecipient := func() bool {
			user, err := getUser(ctx, h.DB, userID)
			if err != nil {
				if !errors.Is(err, sql.ErrNoRows) && ctx.Err() == nil {
					c.Logger().Error("failed to get notification recipient", "error", err)
				}
				return false
			}
			return user.Region == session.Region
		}
		deliverNotification := func() (bool, error) {
			var notification getNotificationsResponse
			err := h.DB.GetContext(ctx, &notification, `
    SELECT n.id, w.id AS posting_window_id, w.region, n.created_at
    FROM posting_windows w
    JOIN notifications n ON n.posting_window_id = w.id AND n.user_id = $1
    WHERE w.region = $2 AND w.id <> $3 AND w.ended_at IS NULL
    LIMIT 1
   `, userID, session.Region, baselineWindowID)
			if errors.Is(err, sql.ErrNoRows) {
				return false, nil
			}
			if err != nil {
				return false, err
			}
			data, err := json.Marshal(notification)
			if err != nil {
				return false, err
			}
			if _, err := fmt.Fprintf(response, "data: %s\n\n", data); err != nil {
				return false, err
			}
			if err := controller.Flush(); err != nil {
				return false, err
			}
			return true, nil
		}
		if !checkRecipient() {
			return nil
		}
		delivered, err := deliverNotification()
		if err != nil {
			if ctx.Err() == nil {
				c.Logger().Error("failed to deliver notification", "error", err)
			}
			return nil
		}
		if delivered {
			return nil
		}
		for {
			select {
			case <-ctx.Done():
				return nil
			case <-notificationEvents:
				// Notifications are persisted in the table, so the event only wakes
				// this handler. The next iteration reads the committed row.
				if !checkRecipient() {
					return nil
				}
				delivered, err := deliverNotification()
				if err != nil {
					if ctx.Err() == nil {
						c.Logger().Error("failed to deliver notification", "error", err)
					}
					return nil
				}
				if delivered {
					return nil
				}
			case <-ticker.C:
				if !checkRecipient() {
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

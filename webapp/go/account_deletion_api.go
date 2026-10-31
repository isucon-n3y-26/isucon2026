package isureal

import (
	"database/sql"
	"errors"
	"net/http"

	"github.com/labstack/echo/v5"
)

func deleteAccountHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		ctx := c.Request().Context()
		userID := GetSession(c).UserID
		var deletedID string
		err := h.DB.GetContext(ctx, &deletedID, `
			WITH locked AS (
				SELECT id FROM users WHERE id = $1 AND status = 'active' FOR NO KEY UPDATE
			), upd_user AS (
				UPDATE users
				SET status = 'deleted', deleted_at = clock_timestamp(), updated_at = clock_timestamp()
				WHERE id = (SELECT id FROM locked)
				RETURNING id
			), upd_sess AS (
				UPDATE login_sessions
				SET active = false, invalidated_at = clock_timestamp(), reason = 'account_deletion'
				WHERE user_id = (SELECT id FROM upd_user) AND active = true
			), notified AS (
				SELECT pg_notify($2, id) FROM upd_user
			)
			SELECT u.id FROM upd_user u LEFT JOIN notified n ON true
		`, userID, notificationRecipientChangedChannel)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusNotFound, "account_not_found")
		}
		if err != nil {
			return err
		}
		globalUserSearchCache.DeleteUser(userID)
		return c.NoContent(http.StatusNoContent)
	}
}

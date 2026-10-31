package isureal

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"

	"github.com/labstack/echo/v5"
)

type certifyUserRequest struct {
	UserID string `param:"userId" json:"-"`
}

func certifyUserHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input certifyUserRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		var user User
		err := h.DB.GetContext(c.Request().Context(), &user, `UPDATE users SET account_type='certified_public', updated_at=clock_timestamp() WHERE id=$1 AND status='active' AND account_type='regular' RETURNING `+strings.Join(userColumns, ", "), input.UserID)
		if errors.Is(err, sql.ErrNoRows) {
			return NewAPIError(http.StatusConflict, "certification_conflict")
		}
		if err != nil {
			return err
		}
		globalUserSearchCache.UpsertUser(user)
		return c.NoContent(http.StatusNoContent)
	}
}

// 2026-08-26: 認定されたユーザーを戻すことは禁止する
func deleteUserCertificationHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		return NewAPIError(http.StatusConflict, "certification_irreversible")
	}
}

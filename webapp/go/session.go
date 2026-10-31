package isureal

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo/v5"
)

type Session struct {
	Region    string    `db:"region" json:"-"`
	Token     string    `db:"-" json:"-"`
	UserID    string    `db:"user_id"`
	TokenHash string    `db:"token_hash"`
	CreatedAt time.Time `db:"created_at"`
	User      User      `db:"user" json:"-"`
}

func GetSession(c *echo.Context) *Session {
	sess, ok := c.Get("session").(*Session)
	if !ok {
		return nil
	}
	return sess
}

func getSessionFromHeader(c *echo.Context, db *sqlx.DB) (*Session, error) {
	authHeader := c.Request().Header.Get(echo.HeaderAuthorization)
	if authHeader == "" {
		return nil, nil
	}
	if !strings.HasPrefix(authHeader, "Bearer ") {
		c.Logger().Warn("Invalid authorization header format(not started with Bearer)")
		return nil, NewAPIError(http.StatusUnauthorized, "invalid_session")
	}

	token := strings.TrimPrefix(authHeader, "Bearer ")

	tokenHashBytes := sha256.Sum256([]byte(token))
	tokenHash := hex.EncodeToString(tokenHashBytes[:])
	var session Session
	err := db.GetContext(c.Request().Context(), &session, `
		SELECT s.user_id, s.token_hash, s.created_at, u.region, `+userColumnsAs("u", "user")+`
		FROM login_sessions s JOIN users u ON u.id = s.user_id
		WHERE s.token_hash = $1
		  AND s.active = true AND u.status = 'active'
	`, tokenHash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get session: %w", err)
	}
	if err := session.User.setImageKey(); err != nil {
		return nil, err
	}
	return &session, nil
}

func SessionMiddleware(handlerContext *HandlerContext, authRequired bool) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c *echo.Context) error {
			session, err := getSessionFromHeader(c, handlerContext.DB)
			if err != nil {
				return err
			}
			if session == nil && authRequired {
				return NewAPIError(http.StatusUnauthorized, "invalid_session")
			}
			c.Set("session", session)
			return next(c)
		}
	}
}

func InvalidateLoginSession(db *sqlx.DB, userID string, tokenHash string) error {
	// users 行のロックは不要。対象は token_hash で特定した自分のセッション1行だけで、
	// 同時に走るログイン (全セッションを replaced にする) やアカウント削除とは
	// login_sessions の行ロックで直列化され、どの順でも結果は active=false になる。
	if _, err := db.Exec(`
		UPDATE login_sessions
		SET active = false, invalidated_at = clock_timestamp(), reason = 'logout'
		WHERE user_id = $1 AND active = true AND token_hash = $2
	`, userID, tokenHash); err != nil {
		return fmt.Errorf("failed to invalidate sessions: %w", err)
	}
	return nil
}

// 2026-09-03: リファクタリング後にこの関数の利用がないようです。消すのはいかがでしょうか
func CreateLoginSession(db *sqlx.DB, userID string) (*Session, error) {
	return createLoginSession(context.Background(), db, userID)
}

var errLoginUserNotActive = errors.New("user is not active")

func createLoginSession(ctx context.Context, db sqlx.QueryerContext, userID string) (*Session, error) {
	randomToken := uuid.NewString()
	tokenHashBytes := sha256.Sum256([]byte(randomToken))
	tokenHash := hex.EncodeToString(tokenHashBytes[:])
	sessionID := uuid.NewString()
	var session Session
	if err := sqlx.GetContext(ctx, db, &session, `
		WITH locked_user AS (
			SELECT id FROM users WHERE id = $1 AND status = 'active' FOR NO KEY UPDATE
		), invalidated AS (
			UPDATE login_sessions
			SET active = false, invalidated_at = clock_timestamp(), reason = 'replaced'
			WHERE user_id = (SELECT id FROM locked_user) AND active = true
		)
		INSERT INTO login_sessions (id, user_id, token_hash)
		SELECT $2, id, $3 FROM locked_user
		RETURNING user_id, token_hash, created_at
	`, userID, sessionID, tokenHash); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, errLoginUserNotActive
		}
		return nil, fmt.Errorf("failed to create login session: %w", err)
	}
	session.Token = randomToken
	return &session, nil
}

func createLoginSessionTx(ctx context.Context, tx *sqlx.Tx, userID string) (*Session, error) {
	return createLoginSession(ctx, tx, userID)
}

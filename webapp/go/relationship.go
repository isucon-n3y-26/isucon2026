package isureal

import (
	"context"
	"database/sql"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jmoiron/sqlx"
)

type FriendRequest struct {
	ID          string    `db:"id"`
	RequesterID string    `db:"requester_id"`
	RecipientID string    `db:"recipient_id"`
	Status      string    `db:"status"`
	CreatedAt   time.Time `db:"created_at"`
	UpdatedAt   time.Time `db:"updated_at"`
}

func getFriendRequest(ctx context.Context, db sqlx.QueryerContext, id string) (FriendRequest, error) {
	var request FriendRequest
	err := sqlx.GetContext(ctx, db, &request, `SELECT id, requester_id, recipient_id, status, created_at, updated_at FROM friend_requests WHERE id=$1`, id)
	return request, err
}

// lockRelationshipUsers は actor を排他、target を共有でロックし、見つかった行の id を返す。
// 同じ相手への別々の利用者の操作は並行できる。同じ2人の組の操作や、相手側のブロック、
// 退会、投稿の削除とは排他になる。デッドロックを避けるため、ロックは id の順に取る。
func lockRelationshipUsers(ctx context.Context, tx *sqlx.Tx, actor, target, condition string) ([]string, error) {
	var lockedIDs []string
	if actor == target {
		err := tx.SelectContext(ctx, &lockedIDs, `SELECT id FROM users WHERE id=$1`+condition+` FOR NO KEY UPDATE`, actor)
		return lockedIDs, err
	}
	firstMode, secondMode := "NO KEY UPDATE", "SHARE"
	if target < actor {
		firstMode, secondMode = secondMode, firstMode
	}
	err := tx.SelectContext(ctx, &lockedIDs, `
		WITH first AS MATERIALIZED (SELECT id FROM users WHERE id=$1`+condition+` FOR `+firstMode+`),
		     second AS MATERIALIZED (SELECT id FROM users WHERE id=$2`+condition+` FOR `+secondMode+`)
		SELECT id FROM first UNION ALL SELECT id FROM second
	`, min(actor, target), max(actor, target))
	return lockedIDs, err
}

func beginRelationshipTx(ctx context.Context, db *sqlx.DB, actor, target string) (*sqlx.Tx, error) {
	if actor == target || target == "" {
		return nil, NewAPIError(http.StatusBadRequest, "invalid_relationship")
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, err
	}
	lockedIDs, err := lockRelationshipUsers(ctx, tx, actor, target, ` AND status='active'`)
	if err != nil {
		tx.Rollback()
		return nil, err
	}
	if len(lockedIDs) != 2 {
		tx.Rollback()
		return nil, NewAPIError(http.StatusNotFound, "relationship_not_found")
	}
	return tx, nil
}

func isBlocked(ctx context.Context, db sqlx.QueryerContext, actor, target string) (bool, error) {
	var blocked bool
	err := sqlx.GetContext(ctx, db, &blocked, `SELECT EXISTS(SELECT 1 FROM block_relations WHERE (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1))`, actor, target)
	return blocked, err
}

func insertFriendship(ctx context.Context, tx *sqlx.Tx, request FriendRequest) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO friendships (id, user_low_id, user_high_id, source_request_id) VALUES ($1,$2,$3,$4)`, uuid.NewString(), min(request.RequesterID, request.RecipientID), max(request.RequesterID, request.RecipientID), request.ID)
	return err
}

func requireRelationshipChange(result sql.Result, err error, status int, code string) error {
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count == 0 {
		return NewAPIError(status, code)
	}
	return nil
}

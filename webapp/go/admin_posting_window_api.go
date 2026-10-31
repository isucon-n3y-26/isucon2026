package isureal

import (
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v5"
)

type openPostingWindowRequest struct {
	Region        string `json:"region"`
	LocalDate     string `json:"localDate"`
	OnTimeSeconds *int64 `json:"onTimeSeconds"`
}

type openPostingWindowResponse struct {
	ID             string    `json:"id"`
	Region         string    `json:"region"`
	LocalDate      string    `json:"localDate"`
	StartsAt       time.Time `json:"startsAt"`
	OnTimeDeadline time.Time `json:"onTimeDeadline"`
}

func openPostingWindowHandler(h *HandlerContext) echo.HandlerFunc {
	return func(c *echo.Context) error {
		var input openPostingWindowRequest
		if err := c.Bind(&input); err != nil {
			return err
		}
		region := input.Region
		localDate, err := time.Parse(time.DateOnly, input.LocalDate)
		if !validRegion(region) || err != nil {
			return NewAPIError(http.StatusBadRequest, "invalid_posting_window")
		}
		seconds := int64(24 * 60 * 60)
		if input.OnTimeSeconds != nil {
			seconds = *input.OnTimeSeconds
		}
		ctx := c.Request().Context()
		tx, err := h.DB.BeginTxx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		// 同じリージョンの開始を直列化する。users のテーブルロックは使わない。
		// (通知の対象は INSERT ... SELECT のスナップショットで決まり、並行する登録・退会・リージョン変更は
		// 開始の前か後かのどちらかに並べられるため、テーブルロックは不要。)
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "posting_window_open:"+region); err != nil {
			return err
		}
		var conflict bool
		if err := tx.GetContext(ctx, &conflict, `SELECT EXISTS(SELECT 1 FROM posting_windows WHERE region = $1 AND local_date >= $2)`, region, localDate); err != nil {
			return err
		}
		if conflict {
			return NewAPIError(http.StatusConflict, "posting_window_conflict")
		}
		// 現在の投稿期間の行ロックを取り、実行中の投稿 (createPostHandler が FOR UPDATE で同じ行を握る) の
		// コミットを待ってから開始時刻を決める。これにより、旧期間の投稿の postedAt は必ず startsAt より前になる。
		if _, err := tx.ExecContext(ctx, `SELECT id FROM posting_windows WHERE region = $1 AND ended_at IS NULL FOR UPDATE`, region); err != nil {
			return err
		}
		var startsAt time.Time
		if err := tx.GetContext(ctx, &startsAt, `SELECT clock_timestamp()`); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE posting_windows SET ended_at = $2 WHERE region = $1 AND ended_at IS NULL`, region, startsAt); err != nil {
			return err
		}
		windowID := uuid.NewString()
		if _, err := tx.ExecContext(ctx, `
   INSERT INTO posting_windows (id, region, local_date, starts_at, on_time_deadline)
   VALUES ($1, $2, $3, $4, $5)
  `, windowID, region, localDate, startsAt, startsAt.Add(time.Duration(seconds)*time.Second)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `
   INSERT INTO notifications (id, user_id, posting_window_id, created_at)
   SELECT gen_random_uuid()::text, id, $2, $3 FROM users WHERE region = $1 AND status = 'active'
  `, region, windowID, startsAt); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `SELECT pg_notify($1, $2)`, postingWindowStartedChannel, region); err != nil {
			return err
		}
		window, err := getPostingWindow(ctx, tx, windowID)
		if err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		return c.JSON(http.StatusCreated, openPostingWindowResponse{
			ID: window.ID, Region: window.Region, LocalDate: window.LocalDate.Format(time.DateOnly),
			StartsAt: window.StartsAt, OnTimeDeadline: window.OnTimeDeadline,
		})
	}
}

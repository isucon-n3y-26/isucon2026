package isureal

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/labstack/echo/v5"
)

const ipBanDuration = 2 * time.Minute

type failureDetector struct {
	limit   int
	window  time.Duration
	history map[string][]time.Time
}

func newFailureDetector(limit int, window time.Duration) *failureDetector {
	return &failureDetector{
		limit:   limit,
		window:  window,
		history: make(map[string][]time.Time),
	}
}

func (d *failureDetector) reset() {
	clear(d.history)
}

func (d *failureDetector) record(ip string, now time.Time) bool {
	if ip == "" {
		return false
	}
	cutoff := now.Add(-d.window)
	entries := d.history[ip]
	kept := entries[:0]
	for _, t := range entries {
		if !t.Before(cutoff) {
			kept = append(kept, t)
		}
	}
	kept = append(kept, now)
	if len(kept) >= d.limit {
		delete(d.history, ip)
		return true
	}
	d.history[ip] = kept
	return false
}

type IPBanList struct {
	mu                       sync.RWMutex
	bans                     map[string]time.Time
	detMu                    sync.Mutex
	loginFailures            *failureDetector
	invalidImageFailures     *failureDetector
	invalidSignatureFailures *failureDetector
}

func NewIPBanList() *IPBanList {
	return &IPBanList{
		bans:                     make(map[string]time.Time),
		loginFailures:            newFailureDetector(10, 10*time.Second),
		invalidImageFailures:     newFailureDetector(2, 5*time.Second),
		invalidSignatureFailures: newFailureDetector(3, 5*time.Second),
	}
}

type ipBan struct {
	IP          string    `db:"ip"`
	BannedUntil time.Time `db:"banned_until"`
}

func (l *IPBanList) Banned(ip string) bool {
	l.mu.RLock()
	until, ok := l.bans[ip]
	l.mu.RUnlock()
	return ok && time.Now().Before(until)
}

func (l *IPBanList) Reset() {
	l.mu.Lock()
	clear(l.bans)
	l.mu.Unlock()

	l.detMu.Lock()
	l.loginFailures.reset()
	l.invalidImageFailures.reset()
	l.invalidSignatureFailures.reset()
	l.detMu.Unlock()
}

func (l *IPBanList) Reload(ctx context.Context, db *sqlx.DB) error {
	var rows []ipBan
	if err := db.SelectContext(ctx, &rows, `SELECT ip, banned_until FROM ip_bans WHERE banned_until > clock_timestamp()`); err != nil {
		return err
	}
	bans := make(map[string]time.Time, len(rows))
	for _, row := range rows {
		bans[row.IP] = row.BannedUntil
	}
	l.mu.Lock()
	l.bans = bans
	l.mu.Unlock()
	return nil
}

func (l *IPBanList) ApplyNotify(ctx context.Context, db *sqlx.DB, payload string) {
	if payload == "" || payload == "*" {
		_ = l.Reload(ctx, db)
		return
	}
	var msg struct {
		IP          string `json:"ip"`
		BannedUntil int64  `json:"banned_until"`
	}
	if err := json.Unmarshal([]byte(payload), &msg); err != nil || msg.IP == "" {
		_ = l.Reload(ctx, db)
		return
	}
	until := time.Unix(msg.BannedUntil+1, 0)
	l.mu.Lock()
	if existing, ok := l.bans[msg.IP]; !ok || until.After(existing) {
		l.bans[msg.IP] = until
	}
	l.mu.Unlock()
}

func (l *IPBanList) RecordFailure(db *sqlx.DB, ip, action string, status int, abuse string) {
	var matched bool
	now := time.Now()

	l.detMu.Lock()
	switch {
	case action == "login" && status == http.StatusUnauthorized:
		matched = l.loginFailures.record(ip, now)
	case action == "put_profile_image" && status == http.StatusBadRequest && abuse == "invalid_image":
		matched = l.invalidImageFailures.record(ip, now)
	case action == "get_image" && status == http.StatusForbidden && abuse == "invalid_signature":
		matched = l.invalidSignatureFailures.record(ip, now)
	}
	l.detMu.Unlock()

	if !matched {
		return
	}

	until := now.Add(ipBanDuration)
	l.mu.Lock()
	l.bans[ip] = until
	l.mu.Unlock()

	if db != nil {
		go func(bannedIP string) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, _ = db.ExecContext(ctx, `
				INSERT INTO ip_bans (ip, banned_until)
				VALUES ($1, clock_timestamp() + make_interval(secs => 120))
				ON CONFLICT (ip) DO UPDATE SET banned_until = GREATEST(ip_bans.banned_until, EXCLUDED.banned_until)
			`, bannedIP)
		}(ip)
	}
}

func extractClientIP(req *http.Request) string {
	if ip := req.Header.Get("X-Client-IP"); ip != "" {
		return ip
	}
	return echo.ExtractIPDirect()(req)
}

func IPBanMiddleware(h *HandlerContext) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c *echo.Context) error {
			if h.IPBans.Banned(c.RealIP()) {
				return NewAPIError(http.StatusForbidden, "ip_banned")
			}
			return next(c)
		}
	}
}

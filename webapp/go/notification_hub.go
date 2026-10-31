package isureal

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

const postingWindowStartedChannel = "posting_window_started"

type notificationHub struct {
	region      string
	mu          sync.Mutex
	subscribers map[chan struct{}]struct{}
}

func newNotificationHub(region string) *notificationHub {
	return &notificationHub{
		region:      region,
		subscribers: make(map[chan struct{}]struct{}),
	}
}

func (h *notificationHub) subscribe() (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	h.subscribers[ch] = struct{}{}
	h.mu.Unlock()

	return ch, func() {
		h.mu.Lock()
		delete(h.subscribers, ch)
		h.mu.Unlock()
	}
}

func (h *notificationHub) notifyRegion(region string) {
	if region != h.region {
		return
	}
	h.notifyAll()
}

func (h *notificationHub) notifyAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subscribers {
		select {
		case ch <- struct{}{}:
		default:
			// A buffered wake-up is already pending. The handler reads the
			// notification table after waking, so duplicate signals can coalesce.
		}
	}
}

func startPostingWindowListener(databaseDSN string, hub *notificationHub) {
	go func() {
		ctx := context.Background()
		retryDelay := time.Second
		for {
			conn, err := pgx.Connect(ctx, databaseDSN)
			if err != nil {
				log.Printf("notification listener: failed to connect to PostgreSQL: %v", err)
				waitBeforeNotificationRetry(ctx, retryDelay)
				retryDelay = nextNotificationRetryDelay(retryDelay)
				continue
			}

			if _, err := conn.Exec(ctx, "LISTEN "+postingWindowStartedChannel); err != nil {
				log.Printf("notification listener: failed to LISTEN: %v", err)
				_ = conn.Close(ctx)
				waitBeforeNotificationRetry(ctx, retryDelay)
				retryDelay = nextNotificationRetryDelay(retryDelay)
				continue
			}

			retryDelay = time.Second
			// Recheck durable rows after startup or reconnect. This recovers signals
			// that may have been sent while this listener connection was down.
			hub.notifyAll()
			for {
				notification, err := conn.WaitForNotification(ctx)
				if err != nil {
					log.Printf("notification listener: connection lost: %v", err)
					break
				}
				if notification.Channel == postingWindowStartedChannel {
					hub.notifyRegion(notification.Payload)
				}
			}
			_ = conn.Close(ctx)
			waitBeforeNotificationRetry(ctx, retryDelay)
			retryDelay = nextNotificationRetryDelay(retryDelay)
		}
	}()
}

func waitBeforeNotificationRetry(ctx context.Context, delay time.Duration) {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}

func nextNotificationRetryDelay(delay time.Duration) time.Duration {
	const maxDelay = 30 * time.Second
	delay *= 2
	if delay > maxDelay {
		return maxDelay
	}
	return delay
}

package isureal

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

const postingWindowStartedChannel = "posting_window_started"
const notificationRecipientChangedChannel = "notification_recipient_changed"
const ipBansChangedChannel = "ip_bans_changed"
const usersChangedChannel = "users_changed"

type notificationSubscriber struct {
	userID string
}

type notificationHub struct {
	region      string
	mu          sync.Mutex
	subscribers map[chan struct{}]notificationSubscriber
}

func newNotificationHub(region string) *notificationHub {
	return &notificationHub{
		region:      region,
		subscribers: make(map[chan struct{}]notificationSubscriber),
	}
}

func (h *notificationHub) subscribe(userID string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	h.subscribers[ch] = notificationSubscriber{userID: userID}
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

func (h *notificationHub) notifyUser(userID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch, subscriber := range h.subscribers {
		if subscriber.userID != userID {
			continue
		}
		wakeNotificationSubscriber(ch)
	}
}

func (h *notificationHub) notifyAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subscribers {
		wakeNotificationSubscriber(ch)
	}
}

func wakeNotificationSubscriber(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
		// A buffered wake-up is already pending. The handler rechecks durable state.
	}
}

func startNotificationListener(databaseDSN string, h *HandlerContext) {
	hub := h.notificationHub
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

			listenFailed := false
			for _, channel := range []string{
				postingWindowStartedChannel,
				notificationRecipientChangedChannel,
				ipBansChangedChannel,
				usersChangedChannel,
			} {
				if _, err := conn.Exec(ctx, "LISTEN "+channel); err != nil {
					log.Printf("notification listener: failed to LISTEN: %v", err)
					listenFailed = true
					break
				}
			}
			if listenFailed {
				_ = conn.Close(ctx)
				waitBeforeNotificationRetry(ctx, retryDelay)
				retryDelay = nextNotificationRetryDelay(retryDelay)
				continue
			}

			retryDelay = time.Second
			// Recheck durable rows after startup or reconnect. This recovers signals
			// that may have been sent while this listener connection was down.
			if h.IPBans != nil {
				_ = h.IPBans.Reload(ctx, h.DB)
			}
			_ = globalUserSearchCache.ReloadAll(ctx, h.DB)
			hub.notifyAll()
			for {
				notification, err := conn.WaitForNotification(ctx)
				if err != nil {
					log.Printf("notification listener: connection lost: %v", err)
					break
				}
				switch notification.Channel {
				case postingWindowStartedChannel:
					hub.notifyRegion(notification.Payload)
				case notificationRecipientChangedChannel:
					hub.notifyUser(notification.Payload)
				case ipBansChangedChannel:
					if h.IPBans != nil {
						if notification.Payload == "*" {
							h.IPBans.Reset()
						}
						h.IPBans.ApplyNotify(ctx, h.DB, notification.Payload)
					}
				case usersChangedChannel:
					globalUserSearchCache.ApplyNotify(ctx, h.DB, notification.Payload)
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

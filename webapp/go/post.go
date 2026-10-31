package isureal

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jmoiron/sqlx"
)

type PostLocation struct {
	Kind      string   `json:"kind" db:"location_kind"`
	Latitude  *float64 `json:"latitude,omitempty" db:"latitude"`
	Longitude *float64 `json:"longitude,omitempty" db:"longitude"`
	Locality  *string  `json:"locality,omitempty" db:"locality"`
}

func (location PostLocation) valid() bool {
	switch location.Kind {
	case "none":
		return location.Latitude == nil && location.Longitude == nil && location.Locality == nil
	case "exact":
		return location.Latitude != nil && location.Longitude != nil && location.Locality == nil &&
			*location.Latitude >= -90 && *location.Latitude <= 90 && *location.Longitude >= -180 && *location.Longitude <= 180
	case "approximate":
		return location.Latitude == nil && location.Longitude == nil && location.Locality != nil && validUserText(*location.Locality, 1, 100)
	default:
		return false
	}
}

type Post struct {
	ID              string `db:"id"`
	AuthorID        string `db:"author_id"`
	PostingWindowID string `db:"posting_window_id"`
	ImageID         string `db:"image_id"`
	Caption         string `db:"caption"`
	Visibility      string `db:"visibility"`
	PostLocation
	PostedAt       time.Time  `db:"posted_at"`
	OnTimeDeadline time.Time  `db:"on_time_deadline"`
	WindowEndedAt  *time.Time `db:"window_ended_at"`
}

const postColumns = `p.id, p.author_id, p.posting_window_id, p.image_id, p.caption, p.visibility,
  p.location_kind, p.latitude, p.longitude, p.locality, p.posted_at,
  w.on_time_deadline, w.ended_at AS window_ended_at`

func getPost(ctx context.Context, db sqlx.QueryerContext, postID string) (Post, error) {
	var post Post
	err := sqlx.GetContext(ctx, db, &post, `
  SELECT `+postColumns+`
  FROM posts p JOIN posting_windows w ON w.id = p.posting_window_id
  WHERE p.id = $1 AND p.deleted_at IS NULL
 `, postID)
	return post, err
}

type PostWithAuthor struct {
	Post
	Author User `db:"author"`
}

func selectPostsWithAuthor(ctx context.Context, db sqlx.QueryerContext, conditions string, args ...any) ([]PostWithAuthor, error) {
	var posts []PostWithAuthor
	if err := sqlx.SelectContext(ctx, db, &posts, `
  SELECT `+postColumns+`, `+userColumnsAs("u", "author")+`
  FROM posts p
  JOIN posting_windows w ON w.id = p.posting_window_id
  JOIN users u ON u.id = p.author_id AND u.status = 'active'
  WHERE p.deleted_at IS NULL `+conditions, args...); err != nil {
		return nil, err
	}
	for i := range posts {
		if err := posts[i].Author.setImageKey(); err != nil {
			return nil, err
		}
	}
	return posts, nil
}

func getPostWithAuthor(ctx context.Context, db sqlx.QueryerContext, postID string) (PostWithAuthor, error) {
	posts, err := selectPostsWithAuthor(ctx, db, `AND p.id = $1`, postID)
	if err != nil {
		return PostWithAuthor{}, err
	}
	if len(posts) == 0 {
		return PostWithAuthor{}, sql.ErrNoRows
	}
	return posts[0], nil
}

type viewerContext struct {
	User
	HasPostedToday   bool
	Friends          map[string]bool
	FriendsOfFriends map[string]bool
	MutualFriends    map[string]int
	Blocked          map[string]bool
}

func loadViewerContext(ctx context.Context, db sqlx.QueryerContext, viewerID string) (viewerContext, error) {
	viewer := viewerContext{Friends: map[string]bool{}, FriendsOfFriends: map[string]bool{}, MutualFriends: map[string]int{}}
	var row struct {
		User
		HasPostedToday bool   `db:"has_posted_today"`
		FriendsJSON    string `db:"friends_json"`
		BlockedJSON    string `db:"blocked_json"`
		EdgesJSON      string `db:"edges_json"`
	}
	query := `
WITH viewer AS (
  SELECT ` + strings.Join(userColumns, ", ") + `,
         EXISTS (
           SELECT 1
           FROM posts p
           JOIN posting_windows posted ON posted.id = p.posting_window_id
           JOIN posting_windows current ON current.region = u.region AND current.ended_at IS NULL
                                        AND current.local_date = posted.local_date
           WHERE p.author_id = u.id AND p.deleted_at IS NULL
         ) AS has_posted_today
  FROM users u
  WHERE u.id = $1 AND u.status = 'active'
), direct_friends AS (
  SELECT direct.friend_id
  FROM viewer v
  CROSS JOIN LATERAL (
    SELECT CASE WHEN f.user_low_id = v.id THEN f.user_high_id ELSE f.user_low_id END AS friend_id
    FROM friendships f
    WHERE f.user_low_id = v.id OR f.user_high_id = v.id
  ) direct
  WHERE v.has_posted_today
), blocked_users AS (
  SELECT blocked.blocked_id
  FROM viewer v
  CROSS JOIN LATERAL (
    SELECT CASE WHEN b.blocker_id = v.id THEN b.blocked_id ELSE b.blocker_id END AS blocked_id
    FROM block_relations b
    WHERE b.blocker_id = v.id OR b.blocked_id = v.id
  ) blocked
  WHERE v.has_posted_today
), friendship_edges AS (
  SELECT f.user_low_id, f.user_high_id
  FROM direct_friends d
  JOIN friendships f ON f.user_low_id = d.friend_id
  UNION
  SELECT f.user_low_id, f.user_high_id
  FROM direct_friends d
  JOIN friendships f ON f.user_high_id = d.friend_id
)
SELECT ` + strings.Join(userColumns, ", ") + `,
       has_posted_today,
       COALESCE((SELECT json_agg(friend_id)::text FROM direct_friends), '[]') AS friends_json,
       COALESCE((SELECT json_agg(blocked_id)::text FROM blocked_users), '[]') AS blocked_json,
       COALESCE((SELECT json_agg(json_build_array(user_low_id, user_high_id))::text FROM friendship_edges), '[]') AS edges_json
FROM viewer
`
	if err := sqlx.GetContext(ctx, db, &row, query, viewerID); err != nil {
		return viewer, err
	}
	viewer.User = row.User
	viewer.HasPostedToday = row.HasPostedToday
	if err := viewer.User.setImageKey(); err != nil {
		return viewer, err
	}
	if !viewer.HasPostedToday {
		return viewer, nil
	}
	var friendIDs []string
	if err := json.Unmarshal([]byte(row.FriendsJSON), &friendIDs); err != nil {
		return viewer, err
	}
	for _, id := range friendIDs {
		viewer.Friends[id] = true
	}
	var blockedIDs []string
	if err := json.Unmarshal([]byte(row.BlockedJSON), &blockedIDs); err != nil {
		return viewer, err
	}
	viewer.Blocked = make(map[string]bool, len(blockedIDs))
	for _, id := range blockedIDs {
		viewer.Blocked[id] = true
	}
	var friendships [][2]string
	if err := json.Unmarshal([]byte(row.EdgesJSON), &friendships); err != nil {
		return viewer, err
	}
	for _, friendship := range friendships {
		userLowID, userHighID := friendship[0], friendship[1]
		if viewer.Friends[userLowID] {
			viewer.FriendsOfFriends[userHighID] = true
			if userHighID != viewer.ID {
				viewer.MutualFriends[userHighID]++
			}
		}
		if viewer.Friends[userHighID] {
			viewer.FriendsOfFriends[userLowID] = true
			if userLowID != viewer.ID {
				viewer.MutualFriends[userLowID]++
			}
		}
	}
	return viewer, nil
}

func (viewer viewerContext) canView(post Post) bool {
	if post.AuthorID == viewer.ID {
		return true
	}
	if post.WindowEndedAt != nil || !viewer.HasPostedToday || viewer.Blocked[post.AuthorID] {
		return false
	}
	switch post.Visibility {
	case "public":
		return true
	case "friends":
		return viewer.Friends[post.AuthorID]
	case "friends_of_friends":
		return viewer.Friends[post.AuthorID] || viewer.FriendsOfFriends[post.AuthorID]
	default:
		return false
	}
}

func canViewPost(ctx context.Context, db sqlx.QueryerContext, viewerID, postID string) (bool, error) {
	post, err := getPostWithAuthor(ctx, db, postID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	viewer, err := loadViewerContext(ctx, db, viewerID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return viewer.canView(post.Post), nil
}

func getFriendIDs(ctx context.Context, db sqlx.QueryerContext, userID string) ([]string, error) {
	var friendships []struct {
		UserLowID  string `db:"user_low_id"`
		UserHighID string `db:"user_high_id"`
	}
	if err := sqlx.SelectContext(ctx, db, &friendships, `SELECT user_low_id, user_high_id FROM friendships WHERE user_low_id = $1 OR user_high_id = $1`, userID); err != nil {
		return nil, err
	}
	var ids []string
	for _, friendship := range friendships {
		if friendship.UserLowID == userID {
			ids = append(ids, friendship.UserHighID)
		} else {
			ids = append(ids, friendship.UserLowID)
		}
	}
	return ids, nil
}

func getBlockedUserIDs(ctx context.Context, db sqlx.QueryerContext, userID string) (map[string]bool, error) {
	var ids []string
	if err := sqlx.SelectContext(ctx, db, &ids, `
  SELECT CASE WHEN blocker_id = $1 THEN blocked_id ELSE blocker_id END
  FROM block_relations WHERE blocker_id = $1 OR blocked_id = $1
 `, userID); err != nil {
		return nil, err
	}
	blocked := make(map[string]bool, len(ids))
	for _, id := range ids {
		blocked[id] = true
	}
	return blocked, nil
}

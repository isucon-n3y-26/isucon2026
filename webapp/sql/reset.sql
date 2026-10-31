SET session_replication_role = replica;

BEGIN;

TRUNCATE ip_bans, login_sessions, administrator_sessions, friendships, friend_requests, follows, block_relations;
-- 001-schema.sql は構築済みの DB には流れないので、初期化のときに作る。
CREATE INDEX IF NOT EXISTS login_sessions_active_token_hash ON login_sessions(token_hash) WHERE active;
CREATE INDEX IF NOT EXISTS login_sessions_active_user_id ON login_sessions(user_id) WHERE active;

DELETE FROM notifications WHERE created_at > (SELECT created_at FROM initial_data_boundary);
DELETE FROM comments WHERE created_at > (SELECT created_at FROM initial_data_boundary);
DELETE FROM realmojis WHERE created_at > (SELECT created_at FROM initial_data_boundary);
DELETE FROM posts WHERE created_at > (SELECT created_at FROM initial_data_boundary);
DELETE FROM posting_windows WHERE created_at > (SELECT created_at FROM initial_data_boundary);
DO $$
DECLARE partition_name text;
BEGIN
  FOR partition_name IN
    SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = 'image_objects'::regclass
      AND c.relname > 'image_objects_' || to_char((SELECT created_at FROM initial_data_boundary) AT TIME ZONE 'UTC', 'YYYYMM')
  LOOP
    EXECUTE format('TRUNCATE %I', partition_name);
  END LOOP;
END $$;
DELETE FROM image_objects WHERE created_at > (SELECT created_at FROM initial_data_boundary);
DELETE FROM users WHERE created_at > (SELECT created_at FROM initial_data_boundary);

UPDATE users u
SET display_name = i.display_name, bio = i.bio, profile_image_id = i.profile_image_id, region = i.region,
    account_type = i.account_type, status = i.status, deleted_at = i.deleted_at, updated_at = i.updated_at
FROM initial_users i
WHERE u.id = i.id
  AND (u.display_name, u.bio, u.profile_image_id, u.region, u.account_type, u.status, u.deleted_at, u.updated_at)
      IS DISTINCT FROM (i.display_name, i.bio, i.profile_image_id, i.region, i.account_type, i.status, i.deleted_at, i.updated_at);

INSERT INTO friend_requests (id, requester_id, recipient_id, status, created_at, updated_at)
SELECT id, requester_id, recipient_id, status, created_at, updated_at FROM initial_friend_requests;
-- 001-schema.sql は構築済みの DB には流れないので、初期化のときに作る。
CREATE INDEX IF NOT EXISTS friend_requests_pending_requester_recipient ON friend_requests(requester_id, recipient_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS friend_requests_pending_recipient ON friend_requests(recipient_id) WHERE status = 'pending';
INSERT INTO friendships (id, user_low_id, user_high_id, source_request_id, created_at, updated_at)
SELECT id, user_low_id, user_high_id, source_request_id, created_at, updated_at FROM initial_friendships;
-- 001-schema.sql は構築済みの DB には流れないので、初期化のときに作る。
CREATE INDEX IF NOT EXISTS friendships_user_high_id ON friendships(user_high_id);
INSERT INTO follows (id, follower_id, followee_id, created_at, updated_at)
SELECT id, follower_id, followee_id, created_at, updated_at FROM initial_follows;
-- 001-schema.sql は構築済みの DB には流れないので、初期化のときに作る。
CREATE INDEX IF NOT EXISTS follows_followee_id ON follows(followee_id);
INSERT INTO block_relations (id, blocker_id, blocked_id, created_at)
SELECT id, blocker_id, blocked_id, created_at FROM initial_block_relations;
-- 001-schema.sql は構築済みの DB には流れないので、初期化のときに作る。
CREATE INDEX IF NOT EXISTS posts_image_id ON posts(image_id);
CREATE INDEX IF NOT EXISTS posts_author_id_posting_window_id ON posts(author_id, posting_window_id);
CREATE INDEX IF NOT EXISTS realmojis_image_id ON realmojis(image_id);

COMMIT;

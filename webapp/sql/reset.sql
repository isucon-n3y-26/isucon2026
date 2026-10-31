SET session_replication_role = replica;

BEGIN;

-- 既存DBにも lookup 表と同期トリガーを追加する。
CREATE TABLE IF NOT EXISTS image_object_lookup (
  id varchar(36) PRIMARY KEY,
  created_at timestamptz NOT NULL,
  owner_user_id varchar(36) NOT NULL,
  media_type text NOT NULL
);

CREATE OR REPLACE FUNCTION sync_image_object_lookup() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM image_object_lookup WHERE id = OLD.id;
    RETURN OLD;
  END IF;

  INSERT INTO image_object_lookup (id, created_at, owner_user_id, media_type)
  VALUES (NEW.id, NEW.created_at, NEW.owner_user_id, NEW.media_type);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS image_objects_lookup_sync ON image_objects;
CREATE TRIGGER image_objects_lookup_sync
AFTER INSERT OR DELETE ON image_objects
FOR EACH ROW EXECUTE FUNCTION sync_image_object_lookup();

-- 以下で image_objects のパーティションを TRUNCATE するため、行トリガーではなく
-- 初期データから再構築する。
TRUNCATE image_object_lookup;

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
INSERT INTO image_object_lookup (id, created_at, owner_user_id, media_type)
SELECT id, created_at, owner_user_id, media_type FROM image_objects;
-- 001-schema.sql は構築済みの DB には流れないので、初期化のときに作る。
CREATE UNIQUE INDEX IF NOT EXISTS users_username_key ON users(username);

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

CREATE OR REPLACE FUNCTION notify_ip_bans_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    PERFORM pg_notify('ip_bans_changed', json_build_object(
      'ip', NEW.ip,
      'banned_until', extract(epoch from NEW.banned_until)::bigint
    )::text);
  ELSE
    PERFORM pg_notify('ip_bans_changed', '*');
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS ip_bans_changed_notify ON ip_bans;
CREATE TRIGGER ip_bans_changed_notify
AFTER INSERT OR UPDATE OR DELETE ON ip_bans
FOR EACH ROW EXECUTE FUNCTION notify_ip_bans_changed();

CREATE OR REPLACE FUNCTION notify_users_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' OR NEW.status <> 'active' THEN
    PERFORM pg_notify('users_changed', json_build_object(
      'op', 'delete',
      'id', COALESCE(NEW.id, OLD.id)
    )::text);
  ELSE
    PERFORM pg_notify('users_changed', json_build_object(
      'op', 'upsert',
      'id', NEW.id,
      'username', NEW.username,
      'secret_key_hash', NEW.secret_key_hash,
      'display_name', NEW.display_name,
      'bio', NEW.bio,
      'profile_image_id', NEW.profile_image_id,
      'region', NEW.region,
      'account_type', NEW.account_type,
      'status', NEW.status
    )::text);
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS users_changed_notify ON users;
CREATE TRIGGER users_changed_notify
AFTER INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION notify_users_changed();

SELECT pg_notify('ip_bans_changed', '*');
SELECT pg_notify('users_changed', '*');

COMMIT;

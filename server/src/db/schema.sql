-- Motion-gated video messenger — Postgres schema.
-- Designed for Supabase (row-level security policies to be added per chat/member).
-- See reports/create-an-app-you-misty-lemur.md for the overall design.

create extension if not exists "pgcrypto";

create type chat_kind as enum ('dm', 'group');
create type recipient_state as enum ('locked', 'unlocked', 'responded', 'exhausted');
-- 'exhausted' = receiver burned all 5 attempts (Snapchat-style replay cap).
-- 'compiling_partial' = group expired with at least minimum_responders matched.
create type group_state as enum (
  'pending', 'compiling', 'compiling_partial', 'ready', 'abandoned', 'failed'
);

-- Curated soundtrack catalog (TikTok-style first-class entities). Sender picks
-- one at compose time; the worker overlays it on the compilation. play_count
-- and is_trending support a future "trending sounds" sort without schema changes.
create table soundtracks (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  artist        text not null,
  storage_url   text not null,
  duration_ms   integer not null check (duration_ms > 0),
  license       text not null,                       -- e.g., 'CC0', 'cleared-2024'
  play_count    bigint not null default 0,
  is_trending   boolean not null default false,
  created_at    timestamptz not null default now()
);
create index on soundtracks(is_trending, play_count desc);

create table users (
  id          uuid primary key default gen_random_uuid(),
  handle      text unique not null,
  apns_token  text,
  created_at  timestamptz not null default now()
);

create table chats (
  id          uuid primary key default gen_random_uuid(),
  kind        chat_kind not null,
  created_by  uuid not null references users(id) on delete restrict,
  created_at  timestamptz not null default now()
);

create table chat_members (
  chat_id  uuid not null references chats(id) on delete cascade,
  user_id  uuid not null references users(id) on delete cascade,
  role     text not null default 'member',
  primary key (chat_id, user_id)
);

-- required_duration_ms is set by the originator of a message. Every response
-- clip in the thread must record for this exact duration (±150 ms tolerance
-- enforced at the client and re-checked by the server).
-- trace_preview is a small JSONB array of normalized 2D points (~64 (x,y)
-- pairs in [0,1]²) computed client-side from cumulative gyro integration.
-- Stored on the message so the inbox row can render the animated thumbnail
-- without fetching signature.json.
create table messages (
  id                    uuid primary key default gen_random_uuid(),
  chat_id               uuid not null references chats(id) on delete cascade,
  sender_id             uuid not null references users(id) on delete restrict,
  video_url             text not null,
  signature_url         text not null,
  required_duration_ms  integer not null check (required_duration_ms between 500 and 15000),
  soundtrack_id         uuid references soundtracks(id) on delete set null,
  trace_preview         jsonb,
  created_at            timestamptz not null default now(),
  expires_at            timestamptz
);
create index on messages(chat_id, created_at desc);

-- Snapchat-style replay cap: attempt_count is hard-capped at MAX_ATTEMPTS=5
-- by the attempts route. When it hits the cap the row is marked 'exhausted'
-- and the sender gets a "ran out of attempts" push.
-- viewed_at records the first time the receiver actually played the unlocked
-- video, so the inbox can render the chevron in its "viewed" state.
-- is_late_response = true when the response landed within the last 10% of
-- the group expiration window (BeReal-style "late" badge).
create table message_recipients (
  message_id          uuid not null references messages(id) on delete cascade,
  recipient_id        uuid not null references users(id) on delete cascade,
  state               recipient_state not null default 'locked',
  attempt_count       integer not null default 0 check (attempt_count <= 5),
  unlocked_at         timestamptz,
  viewed_at           timestamptz,
  response_video_url  text,
  is_late_response    boolean not null default false,
  primary key (message_id, recipient_id)
);
create index on message_recipients(recipient_id, state);

-- Group compilations only exist for chats with >5 members.
-- expires_at: Snapchat-style 24h default. After this point the deadline worker
-- decides whether to compile partial (>= minimum_responders matched) or abandon.
-- minimum_responders: typically ceil(required_count / 2) + 1 — a strict majority.
create table group_completions (
  message_id          uuid primary key references messages(id) on delete cascade,
  required_count      integer not null check (required_count > 5),
  minimum_responders  integer not null check (minimum_responders > 0),
  completed_count     integer not null default 0 check (completed_count >= 0),
  compilation_url     text,
  state               group_state not null default 'pending',
  expires_at          timestamptz not null,
  updated_at          timestamptz not null default now()
);
create index on group_completions(state, expires_at);

-- Per-attempt telemetry. This table is the primary tool for tuning the
-- DTW threshold: plot dtw_score where passed=true vs passed=false and
-- pick the threshold where distributions cleanly separate.
-- zoom_deviation is the RMS error between the sender's zoom curve and
-- the receiver's actually-reached videoZoomFactor during the attempt.
-- A high value indicates the camera was covered or the app was backgrounded.
create table motion_attempts (
  id                    uuid primary key default gen_random_uuid(),
  message_id            uuid not null references messages(id) on delete cascade,
  user_id               uuid not null references users(id) on delete cascade,
  dtw_score             double precision not null,
  zoom_deviation        double precision not null default 0,
  recorded_duration_ms  integer not null,
  passed                boolean not null,
  created_at            timestamptz not null default now()
);
create index on motion_attempts(message_id, user_id, created_at desc);

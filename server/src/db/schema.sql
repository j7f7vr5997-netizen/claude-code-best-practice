-- Motion-gated video messenger — Postgres schema.
-- Designed for Supabase (row-level security policies to be added per chat/member).
-- See reports/create-an-app-you-misty-lemur.md for the overall design.

create extension if not exists "pgcrypto";

create type chat_kind as enum ('dm', 'group');
create type recipient_state as enum ('locked', 'unlocked', 'responded');
create type group_state as enum ('pending', 'compiling', 'ready', 'failed');

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
create table messages (
  id                    uuid primary key default gen_random_uuid(),
  chat_id               uuid not null references chats(id) on delete cascade,
  sender_id             uuid not null references users(id) on delete restrict,
  video_url             text not null,
  signature_url         text not null,
  required_duration_ms  integer not null check (required_duration_ms between 500 and 15000),
  created_at            timestamptz not null default now(),
  expires_at            timestamptz
);
create index on messages(chat_id, created_at desc);

create table message_recipients (
  message_id          uuid not null references messages(id) on delete cascade,
  recipient_id        uuid not null references users(id) on delete cascade,
  state               recipient_state not null default 'locked',
  attempt_count       integer not null default 0,
  unlocked_at         timestamptz,
  response_video_url  text,
  primary key (message_id, recipient_id)
);
create index on message_recipients(recipient_id, state);

-- Group compilations only exist for chats with >5 members.
create table group_completions (
  message_id       uuid primary key references messages(id) on delete cascade,
  required_count   integer not null check (required_count > 5),
  completed_count  integer not null default 0 check (completed_count >= 0),
  compilation_url  text,
  state            group_state not null default 'pending',
  updated_at       timestamptz not null default now()
);

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

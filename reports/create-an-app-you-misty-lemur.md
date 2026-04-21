[← back to reports](../reports)

# Motion-Gated Video Messenger — Implementation Plan

## Context

The user wants a novel mobile app: a Snapchat-style ephemeral video messenger where **the receiver must reproduce the sender's camera motion** before they can view the video. Two people's phones become matched gesture instruments — pan must answer pan, shake must answer shake. In group chats of more than five people, once every member has mirrored the motion and submitted their own clip, the backend stitches all of them into a single compilation and distributes it to the whole group.

This is a **greenfield build** inside the `claude-code-best-practice` repository, which today has no application code — only docs and Claude Code configuration. The plan therefore defines the full mobile client, backend API, storage, worker, and data model from scratch. The design goal is a working, demo-worthy prototype, not a production-hardened social network.

The novel part of the system is not "video messaging" (well-solved) but **motion matching**: comparing two 6-axis IMU time-series captured during two separate recordings and deciding whether the receiver's gesture is "close enough" to the sender's. The rest of the stack exists to serve that comparison.

## Locked Decisions

- **Platform:** iOS only for MVP (SwiftUI + AVFoundation + CoreMotion).
- **Hosting:** Supabase (Postgres + Auth + Storage + Realtime) for the data plane, Fastify (TypeScript) service on Fly.io for domain routes, second Fly.io container as the BullMQ + FFmpeg compilation worker. Redis via Upstash.
- **Match strictness:** game-feel strict — threshold set so ~70% of honest attempts succeed within 3 tries. Live score surfaced to the receiver so every retry feels like "getting warmer."
- **Clip length:** **dictated by the originator**. The first clip in a thread (for 1:1) or in a group round sets `required_duration_ms`; every matching response must record for exactly that duration. The UI enforces this with a countdown bar on the receiver side.

## Recommended Architecture

**Mobile client:** native iOS. `AVCaptureSession` and `CMDeviceMotion` share the `mach_absolute_time` clock, so video frames and IMU samples are trivially synchronized — no bridge jitter. Android is post-MVP.

**Motion-matching algorithm:**
- Sample `CMDeviceMotion` at **100 Hz** during recording. Store 6-D per sample: `userAcceleration` (gravity-subtracted x,y,z) + `rotationRate` (x,y,z), in the gravity-aligned world frame so grip orientation doesn't matter.
- Because sender and receiver record for the **same duration**, both signatures have the same sample count (±2 samples). Resample both to exactly `duration_ms / 10` samples, per-axis z-score, 4th-order Butterworth low-pass at 10 Hz.
- Compare with **FastDTW** (radius 10) on the 6-D series, Euclidean local cost, gyro axes weighted 1.5× (rotation is more distinctive than translation).
- Threshold: calibrate empirically — collect ~50 self-match and ~50 cross-motion pairs, set threshold at the 90th percentile of self-match distances. Tuned for ~70% pass-in-3-attempts (game-feel strict).
- Run **on-device** on the receiver's phone for instant "getting warmer" feedback. The server re-runs the same comparison (TS port) as anti-cheat before unlocking the mutual exchange.

## Data Model (Postgres)

```
users(id, handle, apns_token, created_at)
chats(id, kind ENUM('dm','group'), created_by, created_at)
chat_members(chat_id, user_id, role)
messages(id, chat_id, sender_id, video_url, signature_url,
         required_duration_ms,                 -- set by originator; all responses must match
         created_at, expires_at)
message_recipients(message_id, recipient_id, state ENUM('locked','unlocked','responded'),
                   attempt_count, unlocked_at, response_video_url)
group_completions(message_id, required_count, completed_count, compilation_url, state)
motion_attempts(id, message_id, user_id, dtw_score, recorded_duration_ms, passed, created_at)
```

`required_duration_ms` is the single source of truth for clip length in a thread. The client rejects any recording attempt whose duration deviates by more than ±150 ms; the server rejects the same at upload time (defense in depth).

## Core Flows

- **Record & send (originator):** open camera → start `AVCaptureSession` + `CMMotionManager` together → record for whatever duration feels right, tap to stop → the recorded duration becomes `required_duration_ms` for the thread → upload `video.mp4` + `signature.json` → create `messages` row and fan out `message_recipients`.
- **Receive & unlock:** tap push → fetch locked video (blurred preview) + sender's signature + `required_duration_ms` → UI shows a countdown bar for exactly that duration → press-and-hold to record; recording auto-stops when the bar fills → on stop, run on-device FastDTW → if `score < threshold`: upload response video, server re-verifies, mark `unlocked+responded`, stream sender's clip to receiver and deliver receiver's response to sender. Else: show score, "try again."
- **Group compilation (>5 members):** every matched recipient increments `group_completions.completed_count`. When it equals `required_count`, enqueue a BullMQ `compile` job. The worker downloads all N clips — all guaranteed identical duration because of `required_duration_ms` — concatenates with FFmpeg (stream-copy concat, no re-encode needed since codecs/timing are uniform), uploads `compilation.mp4`, updates the row, and pushes to every member.

## Critical Files to Create

```
/ios/MistyLemur/
  App.swift                                 # SwiftUI entry, auth gate
  Capture/CaptureSession.swift              # synchronized AVCaptureSession + CMMotionManager
  Capture/MotionRecorder.swift              # 100 Hz deviceMotion sampler → [Sample]
  Motion/Signature.swift                    # resample + z-score + low-pass; JSON codec
  Motion/FastDTW.swift                      # 6-D FastDTW with gyro weighting
  Motion/Matcher.swift                      # orchestrates preprocess + DTW + threshold
  Features/Compose/ComposeView.swift        # record-and-send screen
  Features/Inbox/InboxView.swift            # list of locked messages
  Features/Unlock/UnlockAttemptView.swift   # re-record with live score feedback
  Net/API.swift                             # Fastify client
  Net/Storage.swift                         # Supabase Storage upload/download

/server/
  src/index.ts                              # Fastify bootstrap
  src/routes/messages.ts                    # POST /messages, GET /messages/:id
  src/routes/attempts.ts                    # POST /messages/:id/attempt (server re-verify)
  src/routes/groups.ts                      # group completion trigger
  src/motion/fastdtw.ts                     # TS port of matcher for anti-cheat
  src/db/schema.sql                         # tables above
  src/queue.ts                              # BullMQ producer

/worker/
  src/compile.ts                            # BullMQ consumer: download → ffmpeg concat → upload
  Dockerfile                                # node:20-slim + ffmpeg
```

Nothing in the existing repo is reused — it's docs-only. The plan file itself (this document) is the only artifact that belongs under `reports/`.

## MVP Cut

**Ship first (≈2 weeks):** iOS only, 1:1 DM only, on-device match with hardcoded threshold, mutual-exchange unlock, Supabase phone-OTP auth, sender-dictated duration with hard cap of 15 s to keep signatures bounded.

**Phase 2:** group chats + FFmpeg compilation worker, server-side anti-cheat re-verification, ephemerality enforcement (`expires_at`), in-app threshold calibration slider.

**Phase 3:** Android port, E2E encryption (libsignal), anti-replay nonces, screenshot detection, abuse reporting.

## Verification

A build is working when:

1. **Sync sanity check** — record a 6 s clip while deliberately tapping the phone on a hard surface at t=1 s, 3 s, 5 s. The taps must appear as accelerometer spikes at those same timestamps in `signature.json` within ±20 ms. Fail here means the capture/IMU clocks aren't aligned and every later test is meaningless.
2. **Duration enforcement** — a response recorded for `required_duration_ms ± 150 ms` is accepted; one outside that window is rejected by both the client and the server (`POST /messages/:id/attempt` returns 422).
3. **Self-match** — record the same gesture twice on one device. DTW score must land well below the threshold. Repeat ~20× across different gestures (pan, tilt, walk, arc, shake). Self-match pass rate should be ≥ 70% within 3 attempts.
4. **Cross-motion reject** — record a pan then attempt a shake. Score must land well above the threshold; message stays locked.
5. **End-to-end 1:1** — sender A records a 4 s clip, receiver B opens the message (blurred), B's UI shows a 4 s countdown bar, B matches, B sees A's clip, A receives B's response clip.
6. **Group compilation (Phase 2)** — create a 6-person group, originator records a 3 s clip, the other 5 each match in under 3 tries. A `compilation.mp4` of length ≈ 18 s (6 × 3 s) appears in every inbox and plays end-to-end without gaps.
7. **Anti-cheat (Phase 2)** — POST a forged "passed" attempt with a mismatched signature; server re-runs FastDTW and rejects with 422; message stays locked.

Calibration telemetry in `motion_attempts` is the primary tool for tuning the threshold — watch self-match vs cross-motion score distributions and pick the value where they cleanly separate.

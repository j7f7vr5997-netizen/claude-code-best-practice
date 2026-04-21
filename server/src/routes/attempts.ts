import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { fastDTWDistance, type MotionSample } from "../motion/fastdtw.js";

/// POST /messages/:id/attempt — receiver submits their attempt for verification.
///
/// Server re-runs FastDTW against the sender's signature and checks zoom
/// deviation independently of what the client reported. On pass, marks the
/// recipient unlocked+responded, stores the response video URL, and pushes
/// the unlocked video + response back to both parties. On fail, records the
/// attempt in motion_attempts (telemetry) and returns the score so the
/// client can surface "try again" feedback.

const Signature = z.object({
  durationMs: z.number().int(),
  sampleRateHz: z.number().int(),
  samples: z.array(z.object({
    ax: z.number(), ay: z.number(), az: z.number(),
    gx: z.number(), gy: z.number(), gz: z.number(),
  })),
  zoom: z.object({
    points: z.array(z.object({ t: z.number().int(), f: z.number() })),
  }),
});

const AttemptBody = z.object({
  receiverSignature: Signature,
  zoomActual: z.array(z.object({ t: z.number().int(), f: z.number() })),
  responseVideoKey: z.string().min(1),
  recordedDurationMs: z.number().int(),
});

const DTW_THRESHOLD = 6.0;
const ZOOM_DEVIATION_TOLERANCE = 0.3;
const DURATION_TOLERANCE_MS = 150;
/// Snapchat-style replay cap. After 5 failed attempts the message is locked
/// permanently and the sender is notified ("X ran out of attempts").
const MAX_ATTEMPTS = 5;
/// BeReal-style "late" badge: response landed within the last 10% of the
/// group expiration window.
const LATE_RESPONSE_FRACTION = 0.1;

export async function registerAttemptRoutes(app: FastifyInstance) {
  app.post<{ Params: { id: string } }>("/messages/:id/attempt", async (req, reply) => {
    const body = AttemptBody.parse(req.body);
    const messageId = req.params.id;

    // 0. Load recipient row to enforce the replay cap up front — no point
    //    burning CPU on FastDTW if the user is already exhausted.
    const recipient = {                     // stub: SELECT FROM message_recipients ...
      state: "locked" as "locked" | "unlocked" | "responded" | "exhausted",
      attempt_count: 0,
    };
    if (recipient.state === "exhausted" || recipient.attempt_count >= MAX_ATTEMPTS) {
      return reply.code(410).send({ error: "out_of_attempts" });
    }
    if (recipient.state !== "locked") {
      return reply.code(409).send({ error: "already_unlocked" });
    }

    // 1. Load message.required_duration_ms + sender signature from storage.
    const requiredMs = 4000;
    const senderSamples: MotionSample[] = [];
    const senderZoom: { t: number; f: number }[] = [];
    const groupExpiresAt: Date | null = null;          // stub: SELECT FROM group_completions

    // 2. Duration gate.
    if (Math.abs(body.recordedDurationMs - requiredMs) > DURATION_TOLERANCE_MS) {
      return reply.code(422).send({ error: "duration_out_of_tolerance" });
    }

    // 3. DTW (re-run, don't trust client score).
    const dtwScore = fastDTWDistance(senderSamples, body.receiverSignature.samples);

    // 4. Zoom deviation.
    const zoomDeviation = rmsZoomDeviation(senderZoom, body.zoomActual);

    const passed = dtwScore < DTW_THRESHOLD && zoomDeviation < ZOOM_DEVIATION_TOLERANCE;

    // 5. Insert motion_attempts telemetry regardless of pass/fail.
    // 6. UPDATE message_recipients SET attempt_count = attempt_count + 1.
    const newAttemptCount = recipient.attempt_count + 1;
    const reachedCap = !passed && newAttemptCount >= MAX_ATTEMPTS;

    if (passed) {
      // 7a. Mark unlocked + responded. Compute is_late_response if this is a group.
      const isLate = isLateResponse(groupExpiresAt);
      // UPDATE message_recipients SET state='unlocked', unlocked_at=now(),
      //   response_video_url=body.responseVideoKey, is_late_response=isLate;
      // INCREMENT group_completions.completed_count atomically;
      //   if completed_count == required_count: enqueue compile job + state='compiling';
      //   (the deadline job will noop when it sees state != 'pending').
      // Push APNs to sender: "Matched! by @recipient_handle".
      return reply.send({ passed, dtwScore, zoomDeviation, isLate, attemptsRemaining: MAX_ATTEMPTS });
    }

    if (reachedCap) {
      // 7b. UPDATE message_recipients SET state='exhausted'.
      // Push APNs to sender: "@recipient_handle ran out of attempts".
      return reply.send({
        passed: false, dtwScore, zoomDeviation, attemptsRemaining: 0, exhausted: true,
      });
    }

    return reply.send({
      passed: false, dtwScore, zoomDeviation,
      attemptsRemaining: MAX_ATTEMPTS - newAttemptCount,
    });
  });
}

function isLateResponse(groupExpiresAt: Date | null): boolean {
  if (!groupExpiresAt) return false;
  // True if we're within the last 10% of the round window. We don't have the
  // round duration here, so approximate: late iff time-to-expiration < expirationWindow * 0.1.
  // In production: compare against (expires_at - created_at) * LATE_RESPONSE_FRACTION.
  const msToExpiry = groupExpiresAt.getTime() - Date.now();
  const assumedWindowMs = 24 * 3600 * 1000;
  return msToExpiry < assumedWindowMs * LATE_RESPONSE_FRACTION;
}

function rmsZoomDeviation(
  target: { t: number; f: number }[], actual: { t: number; f: number }[],
): number {
  if (target.length === 0 || actual.length === 0) return Infinity;
  let sumSq = 0;
  for (const a of actual) {
    const t = interpolate(target, a.t);
    const d = a.f - t;
    sumSq += d * d;
  }
  return Math.sqrt(sumSq / actual.length);
}

function interpolate(curve: { t: number; f: number }[], tMs: number): number {
  if (tMs <= curve[0]!.t) return curve[0]!.f;
  if (tMs >= curve[curve.length - 1]!.t) return curve[curve.length - 1]!.f;
  let lo = 0, hi = curve.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (curve[mid]!.t <= tMs) lo = mid; else hi = mid;
  }
  const a = curve[lo]!; const b = curve[hi]!;
  const span = b.t - a.t;
  if (span === 0) return a.f;
  const u = (tMs - a.t) / span;
  return a.f + (b.f - a.f) * u;
}

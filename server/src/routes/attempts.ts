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

export async function registerAttemptRoutes(app: FastifyInstance) {
  app.post<{ Params: { id: string } }>("/messages/:id/attempt", async (req, reply) => {
    const body = AttemptBody.parse(req.body);
    const messageId = req.params.id;

    // 1. Load message.required_duration_ms + sender signature from storage.
    const requiredMs = 4000;                // stub: SELECT from messages
    const senderSamples: MotionSample[] = []; // stub: GET signature.json from Storage
    const senderZoom: { t: number; f: number }[] = [];  // stub

    // 2. Duration gate.
    if (Math.abs(body.recordedDurationMs - requiredMs) > DURATION_TOLERANCE_MS) {
      return reply.code(422).send({ error: "duration_out_of_tolerance" });
    }

    // 3. DTW (re-run, don't trust client score).
    const dtwScore = fastDTWDistance(senderSamples, body.receiverSignature.samples);

    // 4. Zoom deviation — RMS between sender's curve and receiver's actual.
    const zoomDeviation = rmsZoomDeviation(senderZoom, body.zoomActual);

    const passed = dtwScore < DTW_THRESHOLD && zoomDeviation < ZOOM_DEVIATION_TOLERANCE;

    // 5. Insert motion_attempts telemetry regardless of pass/fail.
    // 6. On pass: update message_recipients.state='unlocked', set response_video_url,
    //    increment group_completions.completed_count if applicable, push to sender,
    //    enqueue compile job if completed_count == required_count.

    return reply.send({ passed, dtwScore, zoomDeviation });
  });
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

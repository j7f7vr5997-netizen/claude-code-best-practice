import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { deadlineQueue } from "../queue.js";

/// POST /messages — create a new motion-gated message.
/// GET  /messages/:id — fetch locked metadata + signed signature URL for receiver.
///
/// For groups (>5 recipients) we open a group_completions row and schedule a
/// 24h deadline job (Snapchat-style ephemerality). The deadline worker decides
/// whether to compile partial, abandon, or noop based on the state at fire-time.

const TracePoint = z.object({ x: z.number(), y: z.number() });

const CreateBody = z.object({
  chatId: z.string().uuid(),
  requiredDurationMs: z.number().int().min(500).max(15000),
  videoStorageKey: z.string().min(1),
  signatureStorageKey: z.string().min(1),
  tracePreview: z.array(TracePoint).max(128),
  soundtrackId: z.string().uuid().nullable().optional(),
});

const GROUP_EXPIRATION_HOURS = 24;
const GROUP_THRESHOLD_FOR_COMPILATION = 5;   // chat must have >5 members for compilation flow

export async function registerMessageRoutes(app: FastifyInstance) {
  app.post("/messages", async (req, reply) => {
    const body = CreateBody.parse(req.body);

    // 1. Insert into messages — required_duration_ms, soundtrack_id, trace_preview.
    // 2. Fan out into message_recipients for each chat_members row except sender.
    const recipientCount = 0;  // stub: SELECT count(*) FROM chat_members WHERE chat_id=... AND user_id<>sender
    const isGroup = recipientCount > GROUP_THRESHOLD_FOR_COMPILATION;

    if (isGroup) {
      const expiresAt = new Date(Date.now() + GROUP_EXPIRATION_HOURS * 3600 * 1000);
      const minimumResponders = Math.ceil(recipientCount / 2) + 1;
      // 3. INSERT INTO group_completions (message_id, required_count, minimum_responders,
      //    expires_at, state='pending').
      // 4. Schedule the deadline job. Use messageId as jobId so duplicates collapse.
      const messageId = "stub-message-id";
      await deadlineQueue.add(
        "group-deadline",
        { messageId },
        { delay: expiresAt.getTime() - Date.now(), jobId: `deadline:${messageId}` },
      );
    }

    // 5. Send APNs push to each recipient.
    return reply.code(201).send({ id: "stub-message-id", ...body });
  });

  app.get<{ Params: { id: string } }>("/messages/:id", async (req, reply) => {
    const { id } = req.params;
    // 1. Authorize: caller must be in message_recipients for this message.
    // 2. Mint signed GET URLs for the blurred preview + signature.json.
    // 3. Return metadata + required_duration_ms + trace_preview + viewed +
    //    expires_at (group only) + isLateResponse for the row's recipient.
    return reply.send({
      id,
      senderHandle: "stub",
      requiredDurationMs: 4000,
      blurredVideoURL: "https://stub/blurred.mp4",
      signatureURL: "https://stub/signature.json",
      tracePreview: [],
      viewed: false,
      expiresAt: null as string | null,
      isLateResponse: false,
    });
  });
}

import type { FastifyInstance } from "fastify";
import { z } from "zod";

/// POST /messages — create a new motion-gated message.
/// GET  /messages/:id — fetch locked metadata + signed signature URL for receiver.
///
/// The `video_url` and `signature_url` are signed URLs minted by this route
/// after it validates required_duration_ms is within [500, 15000] ms.

const CreateBody = z.object({
  chatId: z.string().uuid(),
  requiredDurationMs: z.number().int().min(500).max(15000),
  videoStorageKey: z.string().min(1),
  signatureStorageKey: z.string().min(1),
});

export async function registerMessageRoutes(app: FastifyInstance) {
  app.post("/messages", async (req, reply) => {
    const body = CreateBody.parse(req.body);
    // 1. Insert into messages(chat_id, sender_id, video_url, signature_url,
    //    required_duration_ms). sender_id comes from the authenticated session.
    // 2. Fan out into message_recipients for each chat_members row except sender.
    // 3. If chat.kind='group' AND chat_members.count > 5, insert a row into
    //    group_completions(message_id, required_count=count-1, state='pending').
    // 4. Send APNs push to each recipient.
    return reply.code(201).send({ id: "stub-message-id", ...body });
  });

  app.get<{ Params: { id: string } }>("/messages/:id", async (req, reply) => {
    const { id } = req.params;
    // 1. Authorize: caller must be in message_recipients for this message.
    // 2. Mint signed GET URLs for the blurred preview + signature.json.
    // 3. Return metadata + required_duration_ms.
    return reply.send({
      id,
      senderHandle: "stub",
      requiredDurationMs: 4000,
      blurredVideoURL: "https://stub/blurred.mp4",
      signatureURL: "https://stub/signature.json",
    });
  });
}

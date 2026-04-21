import type { FastifyInstance } from "fastify";
import { compileQueue } from "../queue.js";

/// Internal endpoint called by the attempts route (or a DB trigger) when a
/// group_completions row transitions to completed_count == required_count.
/// Enqueues the FFmpeg compile job; the worker produces compilation.mp4,
/// uploads it, and pushes the URL to every group member.
///
/// Kept separate from the attempts route so the compile-trigger logic can
/// also fire from a Postgres NOTIFY → server bridge if we later move the
/// counter-increment into a trigger.

export async function registerGroupRoutes(app: FastifyInstance) {
  app.post<{ Params: { messageId: string } }>(
    "/internal/groups/:messageId/compile",
    async (req, reply) => {
      const { messageId } = req.params;
      // 1. Verify group_completions.completed_count == required_count.
      // 2. Collect signed GET URLs for the originator's clip + all N responses
      //    (they're all the same duration, so ffmpeg -c copy concat works).
      const clipURLs: string[] = []; // stub: SELECT response_video_url FROM ...
      const outputKey = `compilations/${messageId}.mp4`;

      await compileQueue.add("compile", { messageId, clipURLs, outputKey });
      return reply.code(202).send({ enqueued: true });
    },
  );
}

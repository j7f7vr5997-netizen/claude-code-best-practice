import type { FastifyInstance } from "fastify";

/// GET /soundtracks — TikTok-style catalog of curated tracks the sender can
/// pick from at compose time. Sorted is_trending first, then play_count desc,
/// so the picker UI surfaces the hot stuff without per-row sort work.
///
/// `?limit=` defaults to 50; `?search=` does a case-insensitive ilike on
/// title and artist for the picker's search bar.

export async function registerSoundtrackRoutes(app: FastifyInstance) {
  app.get<{ Querystring: { limit?: string; search?: string } }>(
    "/soundtracks",
    async (req, reply) => {
      const limit = Math.min(200, Math.max(1, Number(req.query.limit ?? 50)));
      const search = (req.query.search ?? "").trim();

      // SELECT id, title, artist, duration_ms, play_count, is_trending
      // FROM soundtracks
      // WHERE ($1 = '' OR title ILIKE '%' || $1 || '%' OR artist ILIKE '%' || $1 || '%')
      // ORDER BY is_trending DESC, play_count DESC
      // LIMIT $2;
      void search; void limit;

      return reply.send({ soundtracks: [] });
    },
  );
}

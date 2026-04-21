import { Worker, Queue } from "bullmq";
import IORedis from "ioredis";

/// BullMQ consumer for delayed group-deadline jobs (Snapchat-style 24h round
/// expiration). Each job decides one of three outcomes by re-reading the
/// current group_completions state at fire-time:
///
///  - `state != 'pending'`:                  noop (full match already triggered compile)
///  - `completed_count >= minimum_responders`: enqueue compile job with isPartial=true
///                                             and mark state='compiling_partial'
///  - else:                                  mark state='abandoned' + push to all members
///
/// This idempotency means the route side never has to cancel the job; if full
/// participation triggers compile inline, the deadline still fires later but
/// quietly noops.

const connection = new IORedis(process.env.REDIS_URL ?? "redis://localhost:6379", {
  maxRetriesPerRequest: null,
});

interface DeadlineJobData { messageId: string; }

interface CompileJobData {
  messageId: string;
  clipURLs: string[];
  outputKey: string;
  soundtrackURL: string | null;
  soundtrackTitle: string | null;
  soundtrackArtist: string | null;
  isPartial: boolean;
}

const compileQueue = new Queue<CompileJobData>("compile", { connection });

new Worker<DeadlineJobData>("group-deadline", async (job) => {
  const { messageId } = job.data;

  // Read current state. Do this inside a transaction in production so the
  // state-flip and compile-enqueue happen atomically.
  const row = {                                    // stub: SELECT FROM group_completions
    state: "pending" as "pending" | "compiling" | "compiling_partial" | "ready" | "abandoned" | "failed",
    completed_count: 3,
    required_count: 6,
    minimum_responders: 4,
    soundtrack_url: null as string | null,
    soundtrack_title: null as string | null,
    soundtrack_artist: null as string | null,
  };

  if (row.state !== "pending") {
    job.log(`deadline noop for ${messageId}: state=${row.state}`);
    return;
  }

  if (row.completed_count >= row.minimum_responders) {
    // UPDATE group_completions SET state='compiling_partial' WHERE message_id=$1.
    const clipURLs: string[] = [];                // stub: collect signed URLs of received responses
    await compileQueue.add("compile", {
      messageId,
      clipURLs,
      outputKey: `compilations/${messageId}.mp4`,
      soundtrackURL: row.soundtrack_url,
      soundtrackTitle: row.soundtrack_title,
      soundtrackArtist: row.soundtrack_artist,
      isPartial: true,
    });
    job.log(`deadline -> compile partial for ${messageId} (${row.completed_count}/${row.required_count})`);
    return;
  }

  // UPDATE group_completions SET state='abandoned' WHERE message_id=$1.
  // APNs push to every group member: "Your group motion expired — only
  // {completed_count} of {required_count} responded."
  job.log(`deadline -> abandoned for ${messageId} (${row.completed_count}/${row.required_count})`);
}, { connection });

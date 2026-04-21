import { Queue } from "bullmq";
import IORedis from "ioredis";

const connection = new IORedis(process.env.REDIS_URL ?? "redis://localhost:6379", {
  maxRetriesPerRequest: null,
});

/// Job payload for the FFmpeg compilation worker.
/// soundtrackURL is set when the originator picked a TikTok-style track at
/// compose time. With it the worker re-encodes (audio overlay required);
/// without it the worker uses fast `-c copy` stream-copy concat.
/// isPartial=true means the deadline fired with at least minimum_responders
/// matched but short of required_count — used to title the compilation.
export interface CompileJobData {
  messageId: string;
  clipURLs: string[];
  outputKey: string;
  soundtrackURL: string | null;
  soundtrackTitle: string | null;
  soundtrackArtist: string | null;
  isPartial: boolean;
}

export const compileQueue = new Queue<CompileJobData>("compile", { connection });

/// Job payload for the group-round deadline. Scheduled at message create time
/// with delay = expires_at - now (typically 24h). The worker checks current
/// state and either compiles partial, marks abandoned, or noops.
export interface DeadlineJobData {
  messageId: string;
}

export const deadlineQueue = new Queue<DeadlineJobData>("group-deadline", { connection });

import { Queue } from "bullmq";
import IORedis from "ioredis";

const connection = new IORedis(process.env.REDIS_URL ?? "redis://localhost:6379", {
  maxRetriesPerRequest: null,
});

/// Job payload for the FFmpeg compilation worker.
/// The worker downloads each clip via its signed URL, concatenates via
/// ffmpeg (-c copy, since all clips are guaranteed the same duration and
/// encoded with the same settings), and uploads `compilation.mp4`.
export interface CompileJobData {
  messageId: string;
  clipURLs: string[];
  outputKey: string;
}

export const compileQueue = new Queue<CompileJobData>("compile", { connection });

import { Worker } from "bullmq";
import IORedis from "ioredis";
import { spawn } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// BullMQ consumer that assembles a group compilation.
///
/// Because all clips in a group are guaranteed identical duration and encoded
/// with identical settings (via required_duration_ms and fixed capture config),
/// we can use `ffmpeg -f concat -c copy` — no re-encode, sub-second per clip.

const connection = new IORedis(process.env.REDIS_URL ?? "redis://localhost:6379", {
  maxRetriesPerRequest: null,
});

interface CompileJobData {
  messageId: string;
  clipURLs: string[];
  outputKey: string;
}

new Worker<CompileJobData>("compile", async (job) => {
  const { messageId, clipURLs, outputKey } = job.data;
  const workDir = await mkdtemp(join(tmpdir(), `mistylemur-${messageId}-`));
  try {
    // 1. Download every clip.
    const localPaths: string[] = [];
    for (let i = 0; i < clipURLs.length; i++) {
      const p = join(workDir, `clip-${i}.mov`);
      const res = await fetch(clipURLs[i]!);
      const buf = Buffer.from(await res.arrayBuffer());
      await writeFile(p, buf);
      localPaths.push(p);
    }

    // 2. Write the ffmpeg concat manifest.
    const listPath = join(workDir, "list.txt");
    await writeFile(
      listPath,
      localPaths.map((p) => `file '${p.replace(/'/g, "'\\''")}'`).join("\n"),
    );

    // 3. Concat via ffmpeg.
    const outPath = join(workDir, "compilation.mp4");
    await runFFmpeg(["-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", outPath]);

    // 4. Upload to Supabase Storage under outputKey (impl in real env).
    // 5. UPDATE group_completions SET compilation_url=..., state='ready' WHERE message_id=messageId;
    // 6. Push APNs to every group member.

    job.log(`compiled ${clipURLs.length} clips for ${messageId} -> ${outputKey}`);
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}, { connection });

function runFFmpeg(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("ffmpeg", ["-y", ...args], { stdio: "inherit" });
    proc.on("close", (code) => {
      code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`));
    });
    proc.on("error", reject);
  });
}

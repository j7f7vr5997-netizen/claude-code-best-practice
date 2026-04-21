import { Worker } from "bullmq";
import IORedis from "ioredis";
import { spawn } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// BullMQ consumer that assembles a group compilation.
///
/// Two code paths:
///  - No soundtrack: stream-copy concat (`-c copy`). Sub-second per clip
///    because every input has identical duration + codec settings.
///  - With soundtrack: re-encode required to overlay the audio. ~5-10x
///    slower but unavoidable when mixing in a new audio stream. The
///    original clip audio is replaced (not ducked) for MVP simplicity.

const connection = new IORedis(process.env.REDIS_URL ?? "redis://localhost:6379", {
  maxRetriesPerRequest: null,
});

interface CompileJobData {
  messageId: string;
  clipURLs: string[];
  outputKey: string;
  soundtrackURL: string | null;
  soundtrackTitle: string | null;
  soundtrackArtist: string | null;
  isPartial: boolean;
}

new Worker<CompileJobData>("compile", async (job) => {
  const { messageId, clipURLs, outputKey, soundtrackURL, isPartial } = job.data;
  const workDir = await mkdtemp(join(tmpdir(), `mistylemur-${messageId}-`));
  try {
    const localPaths = await downloadAll(clipURLs, workDir);
    const listPath = join(workDir, "list.txt");
    await writeFile(
      listPath,
      localPaths.map((p) => `file '${p.replace(/'/g, "'\\''")}'`).join("\n"),
    );

    const outPath = join(workDir, "compilation.mp4");

    if (soundtrackURL) {
      const soundtrackPath = join(workDir, "soundtrack.audio");
      const res = await fetch(soundtrackURL);
      await writeFile(soundtrackPath, Buffer.from(await res.arrayBuffer()));
      // Re-encode video with libx264 (preset fast for throughput), replace
      // audio entirely with the soundtrack, -shortest so the audio gets
      // trimmed if it's longer than the concatenated video.
      await runFFmpeg([
        "-f", "concat", "-safe", "0", "-i", listPath,
        "-i", soundtrackPath,
        "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-preset", "fast", "-crf", "23",
        "-c:a", "aac", "-b:a", "128k",
        "-shortest",
        outPath,
      ]);
    } else {
      await runFFmpeg(["-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", outPath]);
    }

    // 1. Upload to Supabase Storage under outputKey.
    // 2. UPDATE group_completions SET compilation_url=..., state=isPartial?'compiling_partial':'ready'
    //    WHERE message_id=messageId; -> 'ready' once upload completes.
    // 3. INCREMENT soundtracks.play_count WHERE id=soundtrack_id (TikTok-style attribution).
    // 4. APNs push to every group member.

    job.log(
      `compiled ${clipURLs.length} clips (partial=${isPartial}, soundtrack=${!!soundtrackURL}) ` +
      `for ${messageId} -> ${outputKey}`,
    );
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}, { connection });

async function downloadAll(urls: string[], dir: string): Promise<string[]> {
  const paths: string[] = [];
  for (let i = 0; i < urls.length; i++) {
    const p = join(dir, `clip-${i}.mov`);
    const res = await fetch(urls[i]!);
    await writeFile(p, Buffer.from(await res.arrayBuffer()));
    paths.push(p);
  }
  return paths;
}

function runFFmpeg(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("ffmpeg", ["-y", ...args], { stdio: "inherit" });
    proc.on("close", (code) => {
      code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`));
    });
    proc.on("error", reject);
  });
}

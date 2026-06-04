import { closeMainWindow, open, showHUD } from "@raycast/api";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { getPreferenceValues } from "@raycast/api";

/** Sends a verb to the running app via the kleoth:// URL scheme. */
export async function sendCommand(verb: "record" | "stop" | "toggle", hud: string): Promise<void> {
  await closeMainWindow();
  try {
    await open(`kleoth://${verb}`);
    await showHUD(hud);
  } catch {
    await showHUD("Kleoth is not installed — install /Applications/Kleoth.app first");
  }
}

export interface Meeting {
  dir: string;
  title: string;
  date: string;
  startedAt?: Date;
  /** "Cloud" (ElevenLabs Scribe) or "On-device" (local Whisper). */
  tier: string;
  transcriptPath: string;
  summaryPath: string;
  hasTranscript: boolean;
  hasSummary: boolean;
}

/** The meetings folder (preference, default ~/Kleoth). */
export function meetingsDir(): string {
  const prefs = getPreferenceValues<{ kleothDir?: string }>();
  const raw = (prefs.kleothDir ?? "").trim() || "~/Kleoth";
  return raw.startsWith("~") ? path.join(os.homedir(), raw.slice(1).replace(/^\//, "")) : raw;
}

/** All meetings, newest first. One meeting = one folder with a meta.json. */
export function listMeetings(): Meeting[] {
  const base = meetingsDir();
  let entries: string[];
  try {
    entries = fs.readdirSync(base);
  } catch {
    return [];
  }

  const meetings: { meeting: Meeting; sortKey: number }[] = [];
  for (const name of entries) {
    const dir = path.join(base, name);
    let stat: fs.Stats;
    try {
      stat = fs.statSync(dir);
    } catch {
      continue;
    }
    if (!stat.isDirectory()) continue;

    const metaPath = path.join(dir, "meta.json");
    if (!fs.existsSync(metaPath)) continue; // audio-only folders stay app-side

    let meta: { title?: string; date?: string; started_at?: string; transcript_tier?: string };
    try {
      meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
    } catch {
      continue;
    }

    const startedAt = meta.started_at ? new Date(meta.started_at) : undefined;
    const transcriptPath = path.join(dir, "transcript.md");
    const summaryPath = path.join(dir, "summary.md");
    meetings.push({
      meeting: {
        dir,
        title: meta.title || name,
        date: meta.date || "",
        startedAt,
        tier: meta.transcript_tier?.startsWith("sota") ? "Cloud" : "On-device",
        transcriptPath,
        summaryPath,
        hasTranscript: fs.existsSync(transcriptPath),
        hasSummary: fs.existsSync(summaryPath),
      },
      sortKey: startedAt?.getTime() ?? stat.mtimeMs,
    });
  }

  return meetings.sort((a, b) => b.sortKey - a.sortKey).map((m) => m.meeting);
}

/** Reads a meeting file's text, or undefined when missing/unreadable. */
export function readText(filePath: string): string | undefined {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return undefined;
  }
}

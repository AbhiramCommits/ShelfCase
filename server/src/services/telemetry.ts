import { mkdirSync } from "node:fs";
import { appendFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { z } from "zod";
import { logger } from "../logger.js";

export const telemetrySchema = z.object({
  events: z
    .array(
      z.object({
        name: z.string().min(1).max(120),
        timestamp: z.string().datetime({ offset: true }).optional(),
        durationMs: z.number().optional(),
        syncDurationMs: z.number().optional(),
        retries: z.number().int().min(0).optional(),
        conflicts: z.number().int().min(0).optional(),
        errorMessage: z.string().max(2000).optional(),
        sessionId: z.string().max(120).optional(),
        deviceModel: z.string().max(120).optional(),
        osVersion: z.string().max(60).optional(),
        appVersion: z.string().max(60).optional(),
        attributes: z.record(z.unknown()).optional(),
      }),
    )
    .max(500),
});

/**
 * Optional telemetry sink. The iOS client batches `Telemetry` events here; the
 * endpoint only needs to accept and durably record them, so it appends NDJSON
 * to `TELEMETRY_FILE` (default `./var/telemetry.jsonl`) and acknowledges.
 */
export function recordTelemetry(events: unknown[]): { accepted: number } {
  const file = resolve(process.env.TELEMETRY_FILE ?? "./var/telemetry.jsonl");
  try {
    mkdirSync(dirname(file), { recursive: true });
    const lines = events.map((event) => JSON.stringify(event)).join("\n");
    appendFileSync(file, `${lines}\n`, "utf8");
  } catch (error) {
    logger.warn("telemetry.write_failed", {
      error: error instanceof Error ? error.message : String(error),
    });
  }
  return { accepted: events.length };
}

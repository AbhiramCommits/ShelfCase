import type { NextFunction, Request, Response } from "express";
import { pool } from "../db.js";
import { logger } from "../logger.js";

const HEADER = "idempotency-key";

interface StoredResponse {
  statusCode: number;
  body: unknown;
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * `Idempotency-Key` support for unsafe methods.
 *
 * Contract:
 *  - The first request with a given key claims the key with an `INSERT ...
 *    ON CONFLICT DO NOTHING`. Only the claimant executes the handler.
 *  - A concurrent duplicate polls briefly for the claimant's response and
 *    replays it; if the claimant is still running after the grace period the
 *    duplicate gets `409 IDEMPOTENCY_IN_PROGRESS` rather than double-executing.
 *  - A sequential retry whose original response was lost replays the stored
 *    bytes verbatim, which is exactly what makes a retried `POST` after a
 *    dropped response safe.
 *
 * This is the server half of the lost-response duplicate-creation defect fixed
 * in Step 5.
 */
export function idempotency(req: Request, res: Response, next: NextFunction): void {
  if (req.method !== "POST") {
    next();
    return;
  }

  const key = req.header(HEADER)?.trim();
  if (!key) {
    next();
    return;
  }

  void (async () => {
    try {
      const claim = await pool.query(
        `INSERT INTO request_log (idempotency_key, user_id, completed)
         VALUES ($1, $2, false)
         ON CONFLICT (idempotency_key) DO NOTHING
         RETURNING idempotency_key`,
        [key, req.userId ?? null],
      );
      const claimed = (claim.rowCount ?? 0) > 0;

      if (!claimed) {
        const replayed = await waitForStoredResponse(key);
        if (replayed) {
          logger.info("idempotency.replayed", {
            requestId: req.requestId,
            idempotencyKey: key,
            status: replayed.statusCode,
          });
          res.setHeader("Idempotency-Replayed", "true");
          res.status(replayed.statusCode).json(replayed.body);
          return;
        }
        res.status(409).json({
          error: {
            code: "IDEMPOTENCY_IN_PROGRESS",
            message: "A request with this Idempotency-Key is still being processed",
          },
          requestId: req.requestId,
        });
        return;
      }

      // We own the key: capture the handler's own response so a later retry
      // gets byte-identical output.
      const originalJson = res.json.bind(res);
      res.json = (body: unknown) => {
        const statusCode = res.statusCode;
        if (statusCode < 400) {
          void pool
            .query(
              `UPDATE request_log
                  SET response_body = $2::jsonb, status_code = $3, completed = true
                WHERE idempotency_key = $1`,
              [key, JSON.stringify({ statusCode, body }), statusCode],
            )
            .catch((error: unknown) => {
              logger.error("idempotency.store_failed", {
                requestId: req.requestId,
                idempotencyKey: key,
                error: error instanceof Error ? error.message : String(error),
              });
            });
        } else {
          // Never cache a failure: the client must be able to fix its request
          // and retry with the same key.
          void pool
            .query(`DELETE FROM request_log WHERE idempotency_key = $1`, [key])
            .catch(() => undefined);
        }
        return originalJson(body);
      };

      res.on("close", () => {
        // If the handler errored before writing a response, release the claim so
        // the client's retry is not permanently poisoned.
        if (!res.writableEnded) {
          void pool
            .query(`DELETE FROM request_log WHERE idempotency_key = $1 AND completed = false`, [key])
            .catch(() => undefined);
        }
      });

      next();
    } catch (error) {
      next(error);
    }
  })();
}

async function waitForStoredResponse(key: string, attempts = 25, delayMs = 40): Promise<StoredResponse | null> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const { rows } = await pool.query<{ response_body: StoredResponse | null; completed: boolean; status_code: number | null }>(
      `SELECT response_body, completed, status_code FROM request_log WHERE idempotency_key = $1`,
      [key],
    );
    const row = rows[0];
    if (row?.completed && row.response_body) {
      return row.response_body;
    }
    if (row?.completed && row.status_code !== null && row.response_body === null) {
      return { statusCode: row.status_code, body: null };
    }
    await sleep(delayMs);
  }
  return null;
}

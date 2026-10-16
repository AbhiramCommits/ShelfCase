import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";
import { logger } from "../logger.js";

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      requestId: string;
      /** Resolved by the auth middleware. */
      userId: string;
    }
  }
}

/**
 * Assigns a request id (honouring an inbound `X-Request-Id` so a client can
 * correlate its own retry with the server's log lines), logs one line per
 * completed request, and echoes the id back on the response.
 */
export function requestContext(req: Request, res: Response, next: NextFunction): void {
  const inbound = req.header("x-request-id");
  req.requestId = inbound && inbound.length <= 128 ? inbound : randomUUID();
  res.setHeader("X-Request-Id", req.requestId);

  const startedAt = process.hrtime.bigint();
  res.on("finish", () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    logger.info("http.request", {
      requestId: req.requestId,
      method: req.method,
      path: req.path,
      status: res.statusCode,
      durationMs: Number(durationMs.toFixed(2)),
      userId: req.userId ?? null,
    });
  });

  next();
}

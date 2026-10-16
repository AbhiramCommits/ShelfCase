import type { NextFunction, Request, Response } from "express";
import { ZodError } from "zod";
import { ApiError } from "../errors.js";
import { logger } from "../logger.js";

export function notFoundHandler(req: Request, res: Response): void {
  res.status(404).json({
    error: { code: "NOT_FOUND", message: `No route for ${req.method} ${req.path}` },
    requestId: req.requestId,
  });
}

export function errorHandler(error: unknown, req: Request, res: Response, _next: NextFunction): void {
  if (error instanceof ZodError) {
    res.status(422).json({
      error: {
        code: "VALIDATION_ERROR",
        message: "Request body failed validation",
        details: error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })),
      },
      requestId: req.requestId,
    });
    return;
  }

  if (error instanceof ApiError) {
    res.status(error.status).json({
      error: {
        code: error.code,
        message: error.message,
        ...(error.details === undefined ? {} : { details: error.details }),
      },
      requestId: req.requestId,
    });
    return;
  }

  const message = error instanceof Error ? error.message : String(error);
  logger.error("http.unhandled_error", { requestId: req.requestId, error: message });
  res.status(500).json({
    error: { code: "INTERNAL_ERROR", message: "Unexpected server error" },
    requestId: req.requestId,
  });
}

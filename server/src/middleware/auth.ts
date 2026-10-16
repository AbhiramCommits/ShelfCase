import type { NextFunction, Request, Response } from "express";
import { config } from "../config.js";
import { ApiError } from "../errors.js";

/**
 * Dev bearer-token auth. `Authorization: Bearer dev-alice` resolves to the
 * seeded Alice user. A production deployment replaces the lookup with JWT
 * verification; nothing else in the app changes because handlers only ever read
 * `req.userId`.
 */
export function authenticate(req: Request, _res: Response, next: NextFunction): void {
  const header = req.header("authorization");
  if (!header) {
    next(ApiError.unauthorized());
    return;
  }

  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  const token = match?.[1]?.trim();
  if (!token) {
    next(ApiError.unauthorized("Authorization header must be `Bearer <token>`"));
    return;
  }

  const userId = config.devTokens[token];
  if (!userId) {
    next(ApiError.unauthorized(`Unknown token: ${token}`));
    return;
  }

  req.userId = userId;
  next();
}

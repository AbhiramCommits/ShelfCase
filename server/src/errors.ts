/**
 * Structured API errors. Every failure path returns
 * `{ error: { code, message, details? }, requestId }`.
 */
export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: unknown;

  constructor(status: number, code: string, message: string, details?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }

  static badRequest(message: string, details?: unknown) {
    return new ApiError(400, "BAD_REQUEST", message, details);
  }

  static validation(message: string, details?: unknown) {
    return new ApiError(422, "VALIDATION_ERROR", message, details);
  }

  static unauthorized(message = "Missing or invalid bearer token") {
    return new ApiError(401, "UNAUTHORIZED", message);
  }

  static forbidden(message = "You may not perform this action") {
    return new ApiError(403, "FORBIDDEN", message);
  }

  static notFound(message = "Resource not found") {
    return new ApiError(404, "NOT_FOUND", message);
  }

  /** Optimistic-concurrency rejection. Carries the server's current copy. */
  static conflict(message: string, details?: unknown) {
    return new ApiError(409, "VERSION_CONFLICT", message, details);
  }
}

import express, { type Express } from "express";
import { authenticate } from "./middleware/auth.js";
import { errorHandler, notFoundHandler } from "./middleware/error.js";
import { idempotency } from "./middleware/idempotency.js";
import { requestContext } from "./middleware/requestContext.js";
import { itemsRouter } from "./routes/items.js";
import { syncRouter } from "./routes/sync.js";
import { tradesRouter } from "./routes/trades.js";
import { wishlistRouter } from "./routes/wishlist.js";
import { telemetrySchema, recordTelemetry } from "./services/telemetry.js";

export interface BuildAppOptions {
  /** Skip bearer auth — used by the health probe and by tests of the middleware stack. */
  disableAuth?: boolean;
}

/**
 * Build the Express application. Exposed as a factory so tests can mount it on
 * an ephemeral port with Supertest without starting the real listener.
 */
export function buildApp(options: BuildAppOptions = {}): Express {
  const app = express();

  app.disable("x-powered-by");
  app.use(express.json({ limit: "2mb" }));
  app.use(requestContext);

  app.get("/health", (_req, res) => {
    res.json({ status: "ok", service: "shelfcase-api", time: new Date().toISOString() });
  });

  if (!options.disableAuth) {
    app.use(authenticate);
  } else {
    app.use((req, _res, next) => {
      req.userId = "11111111-1111-4111-8111-111111111111";
      next();
    });
  }

  // Idempotency wraps every unsafe route below it.
  app.use(idempotency);

  app.use("/items", itemsRouter());
  app.use("/trades", tradesRouter());
  app.use("/wishlist", wishlistRouter());
  app.use("/sync", syncRouter());

  app.post("/telemetry", (req, res, next) => {
    try {
      const body = telemetrySchema.parse(req.body);
      const result = recordTelemetry(body.events);
      res.status(202).json(result);
    } catch (error) {
      next(error);
    }
  });

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

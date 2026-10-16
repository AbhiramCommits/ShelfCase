import { buildApp } from "./app.js";
import { config } from "./config.js";
import { closePool, migrate } from "./db.js";
import { logger } from "./logger.js";

async function main(): Promise<void> {
  await migrate();

  const app = buildApp();
  const server = app.listen(config.port, () => {
    logger.info("server.listening", { port: config.port, env: config.env });
  });

  const shutdown = (signal: string) => {
    logger.info("server.shutdown", { signal });
    server.close(() => {
      void closePool().finally(() => process.exit(0));
    });
    // Don't hang forever on a stuck connection.
    setTimeout(() => process.exit(0), 5_000).unref();
  };

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

main().catch((error: unknown) => {
  logger.error("server.fatal", { error: error instanceof Error ? error.message : String(error) });
  process.exit(1);
});

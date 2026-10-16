import { closePool, migrate } from "./db.js";
import { logger } from "./logger.js";

migrate()
  .then(() => {
    logger.info("migrate.done", {});
    return closePool();
  })
  .catch((error: unknown) => {
    logger.error("migrate.failed", { error: error instanceof Error ? error.message : String(error) });
    process.exitCode = 1;
    return closePool();
  });

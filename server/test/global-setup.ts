import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");

/**
 * Vitest global setup: recreate the throwaway test database and run migrations
 * before any worker starts.
 */
export default async function globalSetup(): Promise<void> {
  execFileSync(resolve(repoRoot, "scripts", "test-db.sh"), ["reset"], {
    stdio: "inherit",
    env: process.env,
  });

  const url =
    process.env.TEST_DATABASE_URL ?? "postgres://shelfcase:shelfcase@localhost:55432/shelfcase_test";

  // Import after the database exists so the pool connects to a real database.
  process.env.DATABASE_URL = url;
  const { migrate } = await import("../src/db.js");
  const pool = new pg.Pool({ connectionString: url });
  await migrate(pool);
  await pool.end();
}

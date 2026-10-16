import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { config } from "./config.js";
import { logger } from "./logger.js";

const { Pool } = pg;

/**
 * The narrow slice of `pg.Pool` / `pg.PoolClient` the query helpers need, so a
 * service can run against either a pool or a transaction client.
 */
export interface Queryable {
  query: <R = Record<string, unknown>>(
    text: string,
    values?: unknown[],
  ) => Promise<{ rows: R[]; rowCount: number | null }>;
}

export type PoolClient = pg.PoolClient;

export const pool = new Pool({
  connectionString: config.databaseUrl,
  max: config.pgPoolMax,
  idleTimeoutMillis: 10_000,
  connectionTimeoutMillis: 10_000,
  application_name: "shelfcase-api",
});

pool.on("error", (error) => {
  logger.error("pg.idle_client_error", { error: error.message });
});

/** Locate `sql/*.sql` regardless of whether we run from `src/` (tsx) or `dist/`. */
function sqlDirectory(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return resolve(here, "..", "sql");
}

export function readSql(fileName: string): string {
  return readFileSync(resolve(sqlDirectory(), fileName), "utf8");
}

/**
 * Run every `sql/NNN_*.sql` migration in filename order.
 *
 * The scripts are written with `IF NOT EXISTS` throughout, so re-running is a
 * no-op. Multi-statement scripts are sent as a single simple query, which
 * node-postgres supports when no parameters are bound.
 */
export async function migrate(queryable: Queryable = pool): Promise<void> {
  const files = ["001_init.sql"];
  for (const file of files) {
    const sql = readSql(file);
    await queryable.query(sql);
    logger.info("db.migrated", { file });
  }
}

/** Run `fn` inside a transaction, rolling back on any throw. */
export async function withTransaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    try {
      await client.query("ROLLBACK");
    } catch {
      // ignore: the original error is the interesting one
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function closePool(): Promise<void> {
  await pool.end();
}

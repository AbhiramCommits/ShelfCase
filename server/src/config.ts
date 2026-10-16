import { config as loadEnv } from "dotenv";

loadEnv();

function required(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

export const config = {
  env: required("NODE_ENV", "development"),
  port: Number(required("PORT", "4000")),
  databaseUrl: required("DATABASE_URL", "postgres://shelfcase:shelfcase@localhost:55432/shelfcase"),
  pgPoolMax: Number(required("PG_POOL_MAX", "10")),
  logLevel: required("LOG_LEVEL", "info") as "debug" | "info" | "warn" | "error" | "silent",
  /** Bearer token -> seeded user id. Dev-only; a real deployment swaps this for JWT. */
  devTokens: {
    "dev-alice": "11111111-1111-4111-8111-111111111111",
    "dev-bob": "22222222-2222-4222-8222-222222222222",
    "dev-carol": "33333333-3333-4333-8333-333333333333",
  } as Record<string, string>,
} as const;

export const SEED_USERS = {
  alice: "11111111-1111-4111-8111-111111111111",
  bob: "22222222-2222-4222-8222-222222222222",
  carol: "33333333-3333-4333-8333-333333333333",
} as const;

import { randomUUID } from "node:crypto";
import request from "supertest";
import type { Express } from "express";
import { buildApp } from "../src/app.js";
import { SEED_USERS } from "../src/config.js";
import { pool } from "../src/db.js";

export const ALICE = SEED_USERS.alice;
export const BOB = SEED_USERS.bob;
export const CAROL = SEED_USERS.carol;

export const TOKENS = {
  alice: "dev-alice",
  bob: "dev-bob",
  carol: "dev-carol",
} as const;

export function app(): Express {
  return buildApp();
}

export const auth = (token: (typeof TOKENS)[keyof typeof TOKENS]) => `Bearer ${token}`;

/** Truncate every table and re-seed the three development users. */
export async function resetDatabase(): Promise<void> {
  await pool.query(
    `TRUNCATE trade_items, trades, price_observations, wishlist_entries, items, request_log RESTART IDENTITY CASCADE`,
  );
  await pool.query(`DELETE FROM users`);
  await pool.query(
    `INSERT INTO users (id, display_name, email) VALUES
       ($1, 'Alice', 'alice@shelfcase.test'),
       ($2, 'Bob',   'bob@shelfcase.test'),
       ($3, 'Carol', 'carol@shelfcase.test')`,
    [ALICE, BOB, CAROL],
  );
}

export interface ItemOverrides {
  id?: string;
  title?: string;
  setName?: string;
  category?: string;
  conditionGrade?: string;
  purchasePriceCents?: number;
  estimatedValueCents?: number;
  notes?: string;
  imageLocalPath?: string | null;
}

/** Create an item over HTTP and return the DTO. */
export async function createItem(
  application: Express,
  token: keyof typeof TOKENS,
  overrides: ItemOverrides = {},
): Promise<Record<string, unknown>> {
  const response = await request(application)
    .post("/items")
    .set("Authorization", auth(TOKENS[token]))
    .send({
      id: overrides.id ?? randomUUID(),
      title: overrides.title ?? "Test Item",
      setName: overrides.setName ?? "Test Set",
      category: overrides.category ?? "card",
      conditionGrade: overrides.conditionGrade ?? "nearMint",
      purchasePriceCents: overrides.purchasePriceCents ?? 1_000,
      estimatedValueCents: overrides.estimatedValueCents ?? 2_000,
      notes: overrides.notes ?? "",
      ...(overrides.imageLocalPath === undefined ? {} : { imageLocalPath: overrides.imageLocalPath }),
    })
    .expect(201);

  return response.body.item as Record<string, unknown>;
}

/** Count rows that match a predicate, e.g. `countItems('title = $1', ['x'])`. */
export async function countRows(table: string, where = "true", params: unknown[] = []): Promise<number> {
  const { rows } = await pool.query<{ count: string }>(
    `SELECT count(*)::text AS count FROM ${table} WHERE ${where}`,
    params,
  );
  return Number(rows[0]!.count);
}

export { request, pool, randomUUID };

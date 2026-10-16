import { Router } from "express";
import { pool } from "../db.js";
import { formatCursor, parseCursor } from "../cursor.js";
import { ApiError } from "../errors.js";
import { logger } from "../logger.js";
import {
  toItemDto,
  toObservationDto,
  toTradeDto,
  toWishlistDto,
  type ItemRow,
  type ObservationRow,
  type TradeRow,
  type WishlistRow,
} from "../mappers.js";
import { syncPushSchema, syncPullQuerySchema, itemCreateSchema, itemPatchSchema } from "../schemas.js";
import { insertItem, patchItem, softDeleteItem } from "../services/items.js";
import { wishlistCreateSchema, wishlistPatchSchema } from "../schemas.js";
import { randomUUID } from "node:crypto";

export type PushResultStatus = "applied" | "conflict" | "error";

export interface PushResult {
  entityType: string;
  id: string;
  op: string;
  status: PushResultStatus;
  serverItem?: unknown;
  serverVersion?: number;
  code?: string;
  message?: string;
}

export function syncRouter(): Router {
  const router = Router();

  // ---------------------------------------------------------------- push ---
  router.post("/push", async (req, res, next) => {
    try {
      const body = syncPushSchema.parse(req.body);
      const results: PushResult[] = [];

      for (const change of body.changes) {
        try {
          results.push(await applyChange(req.userId, change));
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          logger.warn("sync.push.change_failed", {
            requestId: req.requestId,
            entityType: change.entityType,
            id: change.id,
            op: change.op,
            error: message,
          });
          results.push({
            entityType: change.entityType,
            id: change.id,
            op: change.op,
            status: "error",
            code: error instanceof ApiError ? error.code : "APPLY_FAILED",
            message,
          });
        }
      }

      const applied = results.filter((r) => r.status === "applied").length;
      const conflicts = results.filter((r) => r.status === "conflict").length;
      const errors = results.filter((r) => r.status === "error").length;

      res.json({ results, applied, conflicts, errors });
    } catch (error) {
      next(error);
    }
  });

  // ---------------------------------------------------------------- pull ---
  router.get("/pull", async (req, res, next) => {
    try {
      const query = syncPullQuerySchema.parse(req.query);
      const cursor = parseCursor(query.since);
      const limit = query.limit;

      const seqFilter = (
        table: string,
        timeColumn: string,
      ): { clause: string; params: unknown[] } => {
        if (cursor.seq > 0) return { clause: `${table}.change_seq > $1`, params: [cursor.seq, limit] };
        if (cursor.updatedAt) return { clause: `${table}.${timeColumn} > $1`, params: [cursor.updatedAt, limit] };
        return { clause: "true", params: [limit] };
      };

      const itemsFilter = seqFilter("i", "updated_at");
      const observationsFilter = seqFilter("po", "observed_at");
      const tradesFilter = seqFilter("t", "updated_at");
      const wishlistFilter = seqFilter("we", "created_at");

      const [items, observations, trades, wishlist] = await Promise.all([
        pool.query<ItemRow>(
          `SELECT i.* FROM items i WHERE ${itemsFilter.clause} ORDER BY i.change_seq ASC LIMIT $${itemsFilter.params.length}`,
          itemsFilter.params,
        ),
        pool.query<ObservationRow>(
          `SELECT po.* FROM price_observations po WHERE ${observationsFilter.clause} ORDER BY po.change_seq ASC LIMIT $${observationsFilter.params.length}`,
          observationsFilter.params,
        ),
        pool.query<TradeRow>(
          `SELECT t.*,
                  COALESCE(array_agg(ti.item_id::text) FILTER (WHERE ti.side = 'offered'), '{}')   AS offered_item_ids,
                  COALESCE(array_agg(ti.item_id::text) FILTER (WHERE ti.side = 'requested'), '{}') AS requested_item_ids
             FROM trades t
             LEFT JOIN trade_items ti ON ti.trade_id = t.id
            WHERE ${tradesFilter.clause}
            GROUP BY t.id
            ORDER BY t.change_seq ASC
            LIMIT $${tradesFilter.params.length}`,
          tradesFilter.params,
        ),
        pool.query<WishlistRow>(
          `SELECT we.* FROM wishlist_entries we WHERE ${wishlistFilter.clause} ORDER BY we.change_seq ASC LIMIT $${wishlistFilter.params.length}`,
          wishlistFilter.params,
        ),
      ]);

      const seqs = [
        ...items.rows.map((row) => Number(row.change_seq)),
        ...observations.rows.map((row) => Number(row.change_seq)),
        ...trades.rows.map((row) => Number(row.change_seq)),
        ...wishlist.rows.map((row) => Number(row.change_seq)),
      ];
      const maxSeq = seqs.length === 0 ? cursor.seq : Math.max(...seqs);

      const hasMore = [items, observations, trades, wishlist].some((result) => result.rows.length === limit);

      res.json({
        items: items.rows.map(toItemDto),
        observations: observations.rows.map(toObservationDto),
        trades: trades.rows.map(toTradeDto),
        wishlistEntries: wishlist.rows.map(toWishlistDto),
        nextCursor: formatCursor(null, maxSeq),
        hasMore,
      });
    } catch (error) {
      next(error);
    }
  });

  return router;
}

async function applyChange(
  userId: string,
  change: {
    entityType: string;
    op: string;
    id: string;
    baseVersion?: number;
    payload: Record<string, unknown>;
  },
): Promise<PushResult> {
  const base = { entityType: change.entityType, id: change.id, op: change.op };

  switch (change.entityType) {
    case "item": {
      if (change.op === "create") {
        const parsed = itemCreateSchema.parse({ ...change.payload, id: change.id });
        const row = await insertItem(pool, userId, parsed);
        return { ...base, status: "applied", serverItem: toItemDto(row), serverVersion: row.version };
      }
      if (change.op === "update") {
        const parsed = itemPatchSchema.parse(change.payload);
        const { version: _ignored, ...fields } = parsed;
        const result = await patchItem(pool, change.id, change.baseVersion, fields);
        if (!result.row) {
          return { ...base, status: "error", code: "NOT_FOUND", message: `No item ${change.id}` };
        }
        if (result.conflict) {
          return {
            ...base,
            status: "conflict",
            serverItem: toItemDto(result.row),
            serverVersion: result.row.version,
          };
        }
        return { ...base, status: "applied", serverItem: toItemDto(result.row), serverVersion: result.row.version };
      }
      const deleted = await softDeleteItem(pool, change.id);
      if (!deleted) return { ...base, status: "error", code: "NOT_FOUND", message: `No item ${change.id}` };
      return { ...base, status: "applied", serverItem: toItemDto(deleted), serverVersion: deleted.version };
    }

    case "wishlist": {
      if (change.op === "create") {
        const parsed = wishlistCreateSchema.parse({ ...change.payload, id: change.id });
        const { rows } = await pool.query<WishlistRow>(
          `INSERT INTO wishlist_entries (id, user_id, title_query, max_price_cents)
           VALUES ($1, $2, $3, $4) RETURNING *`,
          [change.id, userId, parsed.titleQuery, parsed.maxPriceCents],
        );
        return { ...base, status: "applied", serverItem: toWishlistDto(rows[0]!) };
      }
      if (change.op === "update") {
        const parsed = wishlistPatchSchema.parse(change.payload);
        const { rows } = await pool.query<WishlistRow>(
          `UPDATE wishlist_entries
              SET title_query = COALESCE($3, title_query),
                  max_price_cents = COALESCE($4, max_price_cents),
                  change_seq = nextval('change_seq')
            WHERE id = $1 AND user_id = $2
            RETURNING *`,
          [change.id, userId, parsed.titleQuery ?? null, parsed.maxPriceCents ?? null],
        );
        if (!rows[0]) return { ...base, status: "error", code: "NOT_FOUND", message: "No wishlist entry" };
        return { ...base, status: "applied", serverItem: toWishlistDto(rows[0]) };
      }
      const { rowCount } = await pool.query(`DELETE FROM wishlist_entries WHERE id = $1 AND user_id = $2`, [
        change.id,
        userId,
      ]);
      if (rowCount === 0) return { ...base, status: "error", code: "NOT_FOUND", message: "No wishlist entry" };
      return { ...base, status: "applied" };
    }

    case "trade": {
      return {
        ...base,
        status: "error",
        code: "UNSUPPORTED_ENTITY",
        message: "Trades are mutated through /trades, not the push endpoint",
      };
    }

    case "observation": {
      if (change.op === "create") {
        const itemId = String(change.payload.itemId ?? change.id);
        const sourceLabel = String(change.payload.sourceLabel ?? "unknown");
        const valueCents = Number(change.payload.valueCents ?? 0);
        const { rows } = await pool.query<ObservationRow>(
          `INSERT INTO price_observations (id, item_id, source_label, value_cents, observed_at)
           VALUES ($1, $2, $3, $4, COALESCE($5::timestamptz, now()))
           RETURNING *`,
          [randomUUID(), itemId, sourceLabel, valueCents, change.payload.observedAt ?? null],
        );
        return { ...base, status: "applied", serverItem: toObservationDto(rows[0]!) };
      }
      return { ...base, status: "error", code: "UNSUPPORTED_OP", message: `Cannot ${change.op} an observation` };
    }

    default:
      return { ...base, status: "error", code: "UNSUPPORTED_ENTITY", message: `Unknown entity ${change.entityType}` };
  }
}

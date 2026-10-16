import { randomUUID } from "node:crypto";
import { Router } from "express";
import { z } from "zod";
import { pool } from "../db.js";
import { parseCursor, advanceCursor } from "../cursor.js";
import { ApiError } from "../errors.js";
import { toItemDto, toObservationDto, type ItemRow, type ObservationRow } from "../mappers.js";
import {
  itemsQuerySchema,
  itemCreateSchema,
  itemPatchSchema,
  observationCreateSchema,
} from "../schemas.js";
import { insertItem, patchItem, softDeleteItem } from "../services/items.js";
import { findWishlistMatches } from "../services/wishlist.js";

export function itemsRouter(): Router {
  const router = Router();

  // --------------------------------------------------------------- list ---
  router.get("/", async (req, res, next) => {
    try {
      const query = itemsQuerySchema.parse(req.query);
      const cursor = parseCursor(query.since);

      const where: string[] = [];
      const params: unknown[] = [];

      // A composite cursor filters on `change_seq` only: sequence numbers are
      // allocated before commit, so re-applying the wall-clock filter could skip
      // a row whose timestamp lags its sequence.
      if (cursor.seq > 0) {
        params.push(cursor.seq);
        where.push(`i.change_seq > $${params.length}`);
      } else if (cursor.updatedAt) {
        params.push(cursor.updatedAt);
        where.push(`i.updated_at > $${params.length}`);
      }

      const includeDeleted = query.includeDeleted ?? query.since !== undefined;
      if (!includeDeleted) where.push("i.is_deleted = false");

      if (query.category) {
        params.push(query.category);
        where.push(`i.category = $${params.length}`);
      }
      if (query.grade) {
        params.push(query.grade);
        where.push(`i.condition_grade = $${params.length}`);
      }
      if (query.search) {
        params.push(`%${query.search.toLowerCase()}%`);
        where.push(`(lower(i.title) LIKE $${params.length} OR lower(i.set_name) LIKE $${params.length})`);
      }

      params.push(query.limit);
      const limitIdx = params.length;

      const { rows } = await pool.query<ItemRow>(
        `SELECT i.* FROM items i
         ${where.length > 0 ? `WHERE ${where.join(" AND ")}` : ""}
         ORDER BY i.change_seq ASC
         LIMIT $${limitIdx}`,
        params,
      );

      res.json({
        items: rows.map(toItemDto),
        nextCursor: advanceCursor(cursor, rows),
        hasMore: rows.length === query.limit,
      });
    } catch (error) {
      next(error);
    }
  });

  // ------------------------------------------------------------- create ---
  router.post("/", async (req, res, next) => {
    try {
      const body = itemCreateSchema.parse(req.body);
      const item = await insertItem(pool, req.userId, body);
      const wishlistMatches = await findWishlistMatches(
        pool,
        req.userId,
        item.title,
        item.estimated_value_cents,
      );

      res.status(201).json({ item: toItemDto(item), wishlistMatches });
    } catch (error) {
      next(error);
    }
  });

  // --------------------------------------------------------------- read ---
  router.get("/:id", async (req, res, next) => {
    try {
      const { rows } = await pool.query<ItemRow>(`SELECT * FROM items WHERE id = $1`, [req.params.id]);
      const row = rows[0];
      if (!row) throw ApiError.notFound(`No item ${req.params.id}`);
      res.json({ item: toItemDto(row) });
    } catch (error) {
      next(error);
    }
  });

  // -------------------------------------------------------------- patch ---
  router.patch("/:id", async (req, res, next) => {
    try {
      const id = req.params.id;
      const body = itemPatchSchema.parse(req.body);
      const { version, ...fields } = body;

      const result = await patchItem(pool, id, version, fields);

      if (result.conflict) {
        if (!result.row) throw ApiError.notFound(`No item ${id}`);
        throw ApiError.conflict(
          `Item ${id} has moved on: server version ${result.row.version}, client sent ${version ?? "none"}`,
          { serverItem: toItemDto(result.row) },
        );
      }

      if (!result.row) throw ApiError.notFound(`No item ${id}`);
      res.json({ item: toItemDto(result.row) });
    } catch (error) {
      next(error);
    }
  });

  // ------------------------------------------------------------- delete ---
  router.delete("/:id", async (req, res, next) => {
    try {
      const id = req.params.id;
      const parsedVersion = z.coerce.number().int().min(1).optional().safeParse(req.query.version);
      const version = parsedVersion.success ? parsedVersion.data : undefined;

      const { rows } = await pool.query<ItemRow>(`SELECT * FROM items WHERE id = $1`, [id]);
      const current = rows[0];
      if (!current) throw ApiError.notFound(`No item ${id}`);

      if (version !== undefined && version < current.version) {
        throw ApiError.conflict(`Item ${id} has moved on`, { serverItem: toItemDto(current) });
      }

      const deleted = await softDeleteItem(pool, id);
      if (!deleted) throw ApiError.notFound(`No item ${id}`);
      res.json({ item: toItemDto(deleted) });
    } catch (error) {
      next(error);
    }
  });

  // ------------------------------------------------------- observations ---
  router.get("/:id/observations", async (req, res, next) => {
    try {
      const { rows } = await pool.query<ObservationRow>(
        `SELECT * FROM price_observations WHERE item_id = $1 ORDER BY observed_at DESC LIMIT 200`,
        [req.params.id],
      );
      res.json({ observations: rows.map(toObservationDto) });
    } catch (error) {
      next(error);
    }
  });

  router.post("/:id/observations", async (req, res, next) => {
    try {
      const itemId = req.params.id;
      const body = observationCreateSchema.parse(req.body);

      const item = await pool.query<ItemRow>(`SELECT * FROM items WHERE id = $1`, [itemId]);
      if (item.rowCount === 0) throw ApiError.notFound(`No item ${itemId}`);

      const { rows } = await pool.query<ObservationRow>(
        `INSERT INTO price_observations (id, item_id, source_label, value_cents, observed_at)
         VALUES ($1, $2, $3, $4, COALESCE($5::timestamptz, now()))
         RETURNING *`,
        [body.id ?? randomUUID(), itemId, body.sourceLabel, body.valueCents, body.observedAt ?? null],
      );

      res.status(201).json({ observation: toObservationDto(rows[0]!) });
    } catch (error) {
      next(error);
    }
  });

  return router;
}

import { randomUUID } from "node:crypto";
import { Router } from "express";
import { pool } from "../db.js";
import { ApiError } from "../errors.js";
import { toWishlistDto, type WishlistRow } from "../mappers.js";
import { wishlistCreateSchema, wishlistPatchSchema } from "../schemas.js";

export function wishlistRouter(): Router {
  const router = Router();

  router.get("/", async (req, res, next) => {
    try {
      const { rows } = await pool.query<WishlistRow>(
        `SELECT * FROM wishlist_entries WHERE user_id = $1 ORDER BY created_at DESC LIMIT 500`,
        [req.userId],
      );
      res.json({ wishlistEntries: rows.map(toWishlistDto) });
    } catch (error) {
      next(error);
    }
  });

  router.post("/", async (req, res, next) => {
    try {
      const body = wishlistCreateSchema.parse(req.body);
      const { rows } = await pool.query<WishlistRow>(
        `INSERT INTO wishlist_entries (id, user_id, title_query, max_price_cents)
         VALUES ($1, $2, $3, $4)
         RETURNING *`,
        [body.id ?? randomUUID(), req.userId, body.titleQuery, body.maxPriceCents],
      );
      res.status(201).json({ wishlistEntry: toWishlistDto(rows[0]!) });
    } catch (error) {
      next(error);
    }
  });

  router.patch("/:id", async (req, res, next) => {
    try {
      const body = wishlistPatchSchema.parse(req.body);
      const assignments: string[] = [];
      const params: unknown[] = [];

      if (body.titleQuery !== undefined) {
        params.push(body.titleQuery);
        assignments.push(`title_query = $${params.length}`);
      }
      if (body.maxPriceCents !== undefined) {
        params.push(body.maxPriceCents);
        assignments.push(`max_price_cents = $${params.length}`);
      }

      params.push(req.params.id, req.userId);
      const idIdx = params.length - 1;
      const userIdx = params.length;

      if (assignments.length === 0) {
        const existing = await pool.query<WishlistRow>(
          `SELECT * FROM wishlist_entries WHERE id = $1 AND user_id = $2`,
          [req.params.id, req.userId],
        );
        if (!existing.rows[0]) throw ApiError.notFound(`No wishlist entry ${req.params.id}`);
        res.json({ wishlistEntry: toWishlistDto(existing.rows[0]) });
        return;
      }

      const { rows } = await pool.query<WishlistRow>(
        `UPDATE wishlist_entries
            SET ${assignments.join(", ")}, change_seq = nextval('change_seq')
          WHERE id = $${idIdx} AND user_id = $${userIdx}
          RETURNING *`,
        params,
      );

      const updated = rows[0];
      if (!updated) throw ApiError.notFound(`No wishlist entry ${req.params.id}`);
      res.json({ wishlistEntry: toWishlistDto(updated) });
    } catch (error) {
      next(error);
    }
  });

  router.delete("/:id", async (req, res, next) => {
    try {
      const { rowCount } = await pool.query(`DELETE FROM wishlist_entries WHERE id = $1 AND user_id = $2`, [
        req.params.id,
        req.userId,
      ]);
      if (rowCount === 0) throw ApiError.notFound(`No wishlist entry ${req.params.id}`);
      res.status(204).end();
    } catch (error) {
      next(error);
    }
  });

  return router;
}

import { randomUUID } from "node:crypto";
import { Router } from "express";
import { pool, withTransaction, type Queryable, type PoolClient } from "../db.js";
import { ApiError } from "../errors.js";
import { logger } from "../logger.js";
import { toTradeDto, type ItemRow, type TradeRow } from "../mappers.js";
import { tradeCreateSchema, tradesQuerySchema } from "../schemas.js";

const TRADE_SELECT = `
  SELECT t.*,
         COALESCE(array_agg(ti.item_id::text) FILTER (WHERE ti.side = 'offered'), '{}')   AS offered_item_ids,
         COALESCE(array_agg(ti.item_id::text) FILTER (WHERE ti.side = 'requested'), '{}') AS requested_item_ids
    FROM trades t
    LEFT JOIN trade_items ti ON ti.trade_id = t.id
`;

async function loadTrade(queryable: Queryable, id: string): Promise<TradeRow | null> {
  const { rows } = await queryable.query<TradeRow>(
    `${TRADE_SELECT} WHERE t.id = $1 GROUP BY t.id`,
    [id],
  );
  return rows[0] ?? null;
}

/**
 * Move `itemIds` to `newOwnerId`, bumping version/updated_at/change_seq so the
 * swap shows up in every client's delta pull.
 */
async function transferOwnership(
  client: PoolClient,
  itemIds: string[],
  newOwnerId: string,
): Promise<number> {
  if (itemIds.length === 0) return 0;
  const { rowCount } = await client.query(
    `UPDATE items
        SET owner_user_id = $2,
            version = version + 1,
            updated_at = now(),
            change_seq = nextval('change_seq')
      WHERE id = ANY($1::uuid[])`,
    [itemIds, newOwnerId],
  );
  return rowCount ?? 0;
}

async function assertOwned(
  client: PoolClient,
  itemIds: string[],
  ownerId: string,
  what: string,
): Promise<void> {
  const { rows } = await client.query<Pick<ItemRow, "id" | "owner_user_id">>(
    `SELECT id, owner_user_id FROM items WHERE id = ANY($1::uuid[])`,
    [itemIds],
  );
  const found = new Map(rows.map((row) => [row.id, row.owner_user_id]));
  for (const id of itemIds) {
    const owner = found.get(id);
    if (!owner) throw ApiError.validation(`${what}: item ${id} does not exist`);
    if (owner !== ownerId) throw ApiError.forbidden(`${what}: item ${id} is not owned by the expected user`);
  }
}

export function tradesRouter(): Router {
  const router = Router();

  // ------------------------------------------------------------ propose ---
  router.post("/", async (req, res, next) => {
    try {
      const body = tradeCreateSchema.parse(req.body);
      const proposerUserId = req.userId;

      if (body.receiverUserId === proposerUserId) {
        throw ApiError.validation("You cannot propose a trade to yourself");
      }

      const trade = await withTransaction(async (client) => {
        const receiver = await client.query(`SELECT id FROM users WHERE id = $1`, [body.receiverUserId]);
        if (receiver.rowCount === 0) throw ApiError.validation("Unknown receiverUserId");

        await assertOwned(client, body.offeredItemIds, proposerUserId, "offeredItemIds");
        await assertOwned(client, body.requestedItemIds, body.receiverUserId, "requestedItemIds");

        const id = body.id ?? randomUUID();
        const { rows } = await client.query<TradeRow>(
          `INSERT INTO trades (id, proposer_user_id, receiver_user_id, status)
           VALUES ($1, $2, $3, 'proposed')
           RETURNING *`,
          [id, proposerUserId, body.receiverUserId],
        );

        for (const itemId of body.offeredItemIds) {
          await client.query(`INSERT INTO trade_items (trade_id, item_id, side) VALUES ($1, $2, 'offered')`, [
            id,
            itemId,
          ]);
        }
        for (const itemId of body.requestedItemIds) {
          await client.query(`INSERT INTO trade_items (trade_id, item_id, side) VALUES ($1, $2, 'requested')`, [
            id,
            itemId,
          ]);
        }

        return loadTrade(client, rows[0]!.id);
      });

      if (!trade) throw new Error("trade vanished after insert");
      logger.info("trade.proposed", { requestId: req.requestId, tradeId: trade.id });
      res.status(201).json({ trade: toTradeDto(trade) });
    } catch (error) {
      next(error);
    }
  });

  // -------------------------------------------------------------- list ---
  router.get("/", async (req, res, next) => {
    try {
      const query = tradesQuerySchema.parse(req.query);
      const clauses: string[] = [];
      const params: unknown[] = [];

      if (query.role === "incoming") {
        params.push(req.userId);
        clauses.push(`t.receiver_user_id = $${params.length}`);
      } else if (query.role === "outgoing") {
        params.push(req.userId);
        clauses.push(`t.proposer_user_id = $${params.length}`);
      } else {
        params.push(req.userId);
        clauses.push(`(t.receiver_user_id = $${params.length} OR t.proposer_user_id = $${params.length})`);
      }

      if (query.status) {
        params.push(query.status);
        clauses.push(`t.status = $${params.length}`);
      }

      params.push(query.limit);
      const { rows } = await pool.query<TradeRow>(
        `${TRADE_SELECT} WHERE ${clauses.join(" AND ")} GROUP BY t.id ORDER BY t.updated_at DESC LIMIT $${params.length}`,
        params,
      );

      res.json({ trades: rows.map(toTradeDto) });
    } catch (error) {
      next(error);
    }
  });

  // ---------------------------------------------------------------- get ---
  router.get("/:id", async (req, res, next) => {
    try {
      const trade = await loadTrade(pool, req.params.id);
      if (!trade) throw ApiError.notFound(`No trade ${req.params.id}`);
      res.json({ trade: toTradeDto(trade) });
    } catch (error) {
      next(error);
    }
  });

  // ------------------------------------------------------------- accept ---
  router.post("/:id/accept", async (req, res, next) => {
    try {
      const id = req.params.id;

      const outcome = await withTransaction(async (client) => {
        // Serialize concurrent accepts on this trade row.
        const locked = await client.query<TradeRow>(`SELECT * FROM trades WHERE id = $1 FOR UPDATE`, [id]);
        const trade = locked.rows[0];
        if (!trade) throw ApiError.notFound(`No trade ${id}`);

        if (trade.receiver_user_id !== req.userId) {
          throw ApiError.forbidden("Only the receiver can accept a trade");
        }

        // Idempotent: accepting an accepted trade is a no-op, not an error and
        // not a second ownership swap.
        if (trade.status === "accepted") {
          return { trade: await loadTrade(client, id), swapped: 0, noOp: true };
        }
        if (trade.status !== "proposed") {
          throw ApiError.conflict(`Trade ${id} is ${trade.status} and can no longer be accepted`);
        }

        const links = await client.query<{ item_id: string; side: string }>(
          `SELECT item_id, side FROM trade_items WHERE trade_id = $1`,
          [id],
        );
        const offered = links.rows.filter((row) => row.side === "offered").map((row) => row.item_id);
        const requested = links.rows.filter((row) => row.side === "requested").map((row) => row.item_id);

        // Both legs inside the same transaction: a partial swap is impossible.
        const swappedToReceiver = await transferOwnership(client, offered, trade.receiver_user_id);
        const swappedToProposer = await transferOwnership(client, requested, trade.proposer_user_id);

        await client.query(
          `UPDATE trades
              SET status = 'accepted', version = version + 1, updated_at = now(), change_seq = nextval('change_seq')
            WHERE id = $1`,
          [id],
        );

        return {
          trade: await loadTrade(client, id),
          swapped: swappedToReceiver + swappedToProposer,
          noOp: false,
        };
      });

      logger.info("trade.accepted", {
        requestId: req.requestId,
        tradeId: id,
        itemsSwapped: outcome.swapped,
        noOp: outcome.noOp,
      });
      res.json({ trade: toTradeDto(outcome.trade!), itemsSwapped: outcome.swapped, noOp: outcome.noOp });
    } catch (error) {
      next(error);
    }
  });

  // ------------------------------------------------------------ decline ---
  router.post("/:id/decline", async (req, res, next) => {
    try {
      const id = req.params.id;

      const outcome = await withTransaction(async (client) => {
        const locked = await client.query<TradeRow>(`SELECT * FROM trades WHERE id = $1 FOR UPDATE`, [id]);
        const trade = locked.rows[0];
        if (!trade) throw ApiError.notFound(`No trade ${id}`);
        if (trade.receiver_user_id !== req.userId) {
          throw ApiError.forbidden("Only the receiver can decline a trade");
        }
        if (trade.status === "declined") {
          return { trade: await loadTrade(client, id), noOp: true };
        }
        if (trade.status !== "proposed") {
          throw ApiError.conflict(`Trade ${id} is ${trade.status} and can no longer be declined`);
        }

        await client.query(
          `UPDATE trades
              SET status = 'declined', version = version + 1, updated_at = now(), change_seq = nextval('change_seq')
            WHERE id = $1`,
          [id],
        );
        return { trade: await loadTrade(client, id), noOp: false };
      });

      res.json({ trade: toTradeDto(outcome.trade!), noOp: outcome.noOp });
    } catch (error) {
      next(error);
    }
  });

  // ------------------------------------------------------------ cancel ---
  router.post("/:id/cancel", async (req, res, next) => {
    try {
      const id = req.params.id;

      const outcome = await withTransaction(async (client) => {
        const locked = await client.query<TradeRow>(`SELECT * FROM trades WHERE id = $1 FOR UPDATE`, [id]);
        const trade = locked.rows[0];
        if (!trade) throw ApiError.notFound(`No trade ${id}`);
        if (trade.proposer_user_id !== req.userId) {
          throw ApiError.forbidden("Only the proposer can cancel a trade");
        }
        if (trade.status === "cancelled") {
          return { trade: await loadTrade(client, id), noOp: true };
        }
        if (trade.status !== "proposed") {
          throw ApiError.conflict(`Trade ${id} is ${trade.status} and can no longer be cancelled`);
        }

        await client.query(
          `UPDATE trades
              SET status = 'cancelled', version = version + 1, updated_at = now(), change_seq = nextval('change_seq')
            WHERE id = $1`,
          [id],
        );
        return { trade: await loadTrade(client, id), noOp: false };
      });

      res.json({ trade: toTradeDto(outcome.trade!), noOp: outcome.noOp });
    } catch (error) {
      next(error);
    }
  });

  return router;
}

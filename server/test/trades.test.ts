import { beforeEach, describe, expect, it } from "vitest";
import {
  ALICE,
  BOB,
  TOKENS,
  app,
  auth,
  countRows,
  createItem,
  pool,
  randomUUID,
  request,
  resetDatabase,
} from "./helpers.js";

const application = app();

beforeEach(async () => {
  await resetDatabase();
});

async function ownerOf(itemId: string): Promise<string> {
  const { rows } = await pool.query<{ owner_user_id: string }>(`SELECT owner_user_id FROM items WHERE id = $1`, [
    itemId,
  ]);
  return rows[0]!.owner_user_id;
}

describe("POST /trades", () => {
  it("proposes a swap and persists both legs", async () => {
    const aliceCard = await createItem(application, "alice", { title: "Alice Card" });
    const bobCard = await createItem(application, "bob", { title: "Bob Card" });

    const response = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({
        receiverUserId: BOB,
        offeredItemIds: [aliceCard.id],
        requestedItemIds: [bobCard.id],
      })
      .expect(201);

    expect(response.body.trade.status).toBe("proposed");
    expect(response.body.trade.proposerUserId).toBe(ALICE);
    expect(response.body.trade.offeredItemIds).toEqual([aliceCard.id]);
    expect(response.body.trade.requestedItemIds).toEqual([bobCard.id]);
    expect(await countRows("trade_items")).toBe(2);
  });

  it("rejects offering an item you do not own", async () => {
    const bobCard = await createItem(application, "bob", { title: "Bob Card" });
    const aliceCard = await createItem(application, "alice", { title: "Alice Card" });

    const response = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [bobCard.id], requestedItemIds: [aliceCard.id] })
      .expect(403);

    expect(response.body.error.code).toBe("FORBIDDEN");
  });

  it("rejects a trade with yourself", async () => {
    const mine = await createItem(application, "alice");
    await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: ALICE, offeredItemIds: [mine.id], requestedItemIds: [mine.id] })
      .expect(422);
  });

  it("rejects unknown item ids", async () => {
    const mine = await createItem(application, "alice");
    const response = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [mine.id], requestedItemIds: [randomUUID()] })
      .expect(422);
    expect(response.body.error.message).toContain("does not exist");
  });

  it("rejects an unknown receiver", async () => {
    const mine = await createItem(application, "alice");
    const other = await createItem(application, "alice");
    await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: randomUUID(), offeredItemIds: [mine.id], requestedItemIds: [other.id] })
      .expect(422);
  });

  it("validates the body shape", async () => {
    await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: "not-a-uuid", offeredItemIds: [], requestedItemIds: [] })
      .expect(422);
  });
});

describe("POST /trades/:id/accept", () => {
  it("swaps ownership of both legs inside one transaction", async () => {
    const aliceCard = await createItem(application, "alice", { title: "Alice Card" });
    const bobCard = await createItem(application, "bob", { title: "Bob Card" });

    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    const accepted = await request(application)
      .post(`/trades/${proposed.body.trade.id}/accept`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);

    expect(accepted.body.trade.status).toBe("accepted");
    expect(accepted.body.itemsSwapped).toBe(2);
    expect(accepted.body.noOp).toBe(false);

    expect(await ownerOf(aliceCard.id as string)).toBe(BOB);
    expect(await ownerOf(bobCard.id as string)).toBe(ALICE);
  });

  it("is a no-op the second time (no double swap, no error)", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");

    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    await request(application)
      .post(`/trades/${proposed.body.trade.id}/accept`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);

    const second = await request(application)
      .post(`/trades/${proposed.body.trade.id}/accept`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);

    expect(second.body.noOp).toBe(true);
    expect(second.body.itemsSwapped).toBe(0);
    // Ownership must not have flipped back.
    expect(await ownerOf(aliceCard.id as string)).toBe(BOB);
    expect(await ownerOf(bobCard.id as string)).toBe(ALICE);
  });

  it("does not swap anything when two accepts race", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");

    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    const tradeId = proposed.body.trade.id as string;
    const [a, b] = await Promise.all([
      request(application).post(`/trades/${tradeId}/accept`).set("Authorization", auth(TOKENS.bob)),
      request(application).post(`/trades/${tradeId}/accept`).set("Authorization", auth(TOKENS.bob)),
    ]);

    expect(a.status).toBe(200);
    expect(b.status).toBe(200);

    // Exactly one of them performed the swap.
    const swapped = [a.body.itemsSwapped, b.body.itemsSwapped].sort((x, y) => x - y);
    expect(swapped).toEqual([0, 2]);
    expect(await ownerOf(aliceCard.id as string)).toBe(BOB);
  });

  it("forbids the proposer from accepting their own trade", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");
    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    const response = await request(application)
      .post(`/trades/${proposed.body.trade.id}/accept`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(403);
    expect(response.body.error.code).toBe("FORBIDDEN");
  });

  it("404s an unknown trade", async () => {
    await request(application)
      .post(`/trades/${randomUUID()}/accept`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(404);
  });

  it("refuses to accept a declined trade", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");
    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    const tradeId = proposed.body.trade.id as string;
    await request(application).post(`/trades/${tradeId}/decline`).set("Authorization", auth(TOKENS.bob)).expect(200);

    const response = await request(application)
      .post(`/trades/${tradeId}/accept`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(409);
    expect(response.body.error.code).toBe("VERSION_CONFLICT");
  });
});

describe("decline and cancel", () => {
  async function propose(): Promise<string> {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");
    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);
    return proposed.body.trade.id as string;
  }

  it("declines a proposed trade and is idempotent", async () => {
    const tradeId = await propose();
    const first = await request(application)
      .post(`/trades/${tradeId}/decline`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);
    expect(first.body.trade.status).toBe("declined");

    const second = await request(application)
      .post(`/trades/${tradeId}/decline`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);
    expect(second.body.noOp).toBe(true);
  });

  it("forbids the proposer from declining", async () => {
    const tradeId = await propose();
    await request(application).post(`/trades/${tradeId}/decline`).set("Authorization", auth(TOKENS.alice)).expect(403);
  });

  it("lets the proposer cancel and is idempotent", async () => {
    const tradeId = await propose();
    const first = await request(application)
      .post(`/trades/${tradeId}/cancel`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(first.body.trade.status).toBe("cancelled");

    const second = await request(application)
      .post(`/trades/${tradeId}/cancel`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(second.body.noOp).toBe(true);
  });

  it("forbids the receiver from cancelling", async () => {
    const tradeId = await propose();
    await request(application).post(`/trades/${tradeId}/cancel`).set("Authorization", auth(TOKENS.bob)).expect(403);
  });

  it("404s decline and cancel for unknown trades", async () => {
    await request(application)
      .post(`/trades/${randomUUID()}/decline`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(404);
    await request(application)
      .post(`/trades/${randomUUID()}/cancel`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(404);
  });
});

describe("GET /trades", () => {
  it("filters by incoming, outgoing and status", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");
    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    const incoming = await request(application)
      .get("/trades?role=incoming")
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);
    expect(incoming.body.trades).toHaveLength(1);

    const outgoing = await request(application)
      .get("/trades?role=outgoing")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(outgoing.body.trades).toHaveLength(1);

    const noneForCarol = await request(application)
      .get("/trades?role=incoming")
      .set("Authorization", auth(TOKENS.carol))
      .expect(200);
    expect(noneForCarol.body.trades).toHaveLength(0);

    const accepted = await request(application)
      .get("/trades?role=incoming&status=accepted")
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);
    expect(accepted.body.trades).toHaveLength(0);

    const proposedOnly = await request(application)
      .get("/trades?role=incoming&status=proposed")
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);
    expect(proposedOnly.body.trades[0].id).toBe(proposed.body.trade.id);
  });

  it("reads a single trade and 404s an unknown one", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");
    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    await request(application)
      .get(`/trades/${proposed.body.trade.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    await request(application).get(`/trades/${randomUUID()}`).set("Authorization", auth(TOKENS.alice)).expect(404);
  });
});

import { beforeEach, describe, expect, it } from "vitest";
import { BOB, TOKENS, app, auth, countRows, createItem, pool, randomUUID, request, resetDatabase } from "./helpers.js";

const application = app();

beforeEach(async () => {
  await resetDatabase();
});

interface PushResultShape {
  entityType: string;
  id: string;
  op: string;
  status: string;
  serverItem?: Record<string, unknown>;
  serverVersion?: number;
  code?: string;
}

describe("POST /sync/push", () => {
  it("applies a create and echoes the server row", async () => {
    const id = randomUUID();
    const response = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.alice))
      .send({
        changes: [
          {
            entityType: "item",
            op: "create",
            id,
            payload: { title: "Pushed Card", category: "card", estimatedValueCents: 5_000 },
          },
        ],
      })
      .expect(200);

    expect(response.body.applied).toBe(1);
    expect(response.body.conflicts).toBe(0);
    expect(response.body.errors).toBe(0);

    const result = response.body.results[0] as PushResultShape;
    expect(result.status).toBe("applied");
    expect(result.serverItem?.id).toBe(id);
    expect(result.serverVersion).toBe(1);
  });

  it("applies an update guarded by baseVersion", async () => {
    const item = await createItem(application, "alice", { title: "Original" });

    const response = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.alice))
      .send({
        changes: [
          {
            entityType: "item",
            op: "update",
            id: item.id,
            baseVersion: 1,
            payload: { notes: "from push", conditionGrade: "mint" },
          },
        ],
      })
      .expect(200);

    const result = response.body.results[0] as PushResultShape;
    expect(result.status).toBe("applied");
    expect(result.serverVersion).toBe(2);
    expect(result.serverItem?.notes).toBe("from push");
    expect(result.serverItem?.conditionGrade).toBe("mint");
  });

  it("reports a conflict with the server copy when baseVersion is stale", async () => {
    const item = await createItem(application, "alice", { title: "Contested" });
    await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ notes: "server wins this round", version: 1 })
      .expect(200);

    const response = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.alice))
      .send({
        changes: [
          {
            entityType: "item",
            op: "update",
            id: item.id,
            baseVersion: 1,
            payload: { notes: "stale client note" },
          },
        ],
      })
      .expect(200);

    expect(response.body.conflicts).toBe(1);
    const result = response.body.results[0] as PushResultShape;
    expect(result.status).toBe("conflict");
    expect(result.serverVersion).toBe(2);
    expect(result.serverItem?.notes).toBe("server wins this round");
  });

  it("applies a delete as a tombstone", async () => {
    const item = await createItem(application, "alice", { title: "To Delete" });

    const response = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.alice))
      .send({ changes: [{ entityType: "item", op: "delete", id: item.id, payload: {} }] })
      .expect(200);

    const result = response.body.results[0] as PushResultShape;
    expect(result.status).toBe("applied");
    expect(result.serverItem?.isDeleted).toBe(true);
    expect(await countRows("items")).toBe(1);
  });

  it("reports per-change errors without failing the whole batch", async () => {
    const goodId = randomUUID();
    const response = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.alice))
      .send({
        changes: [
          { entityType: "item", op: "create", id: goodId, payload: { title: "Good" } },
          { entityType: "item", op: "update", id: randomUUID(), baseVersion: 1, payload: { notes: "ghost" } },
          { entityType: "trade", op: "create", id: randomUUID(), payload: {} },
          { entityType: "observation", op: "delete", id: randomUUID(), payload: {} },
        ],
      })
      .expect(200);

    expect(response.body.applied).toBe(1);
    expect(response.body.errors).toBe(3);
    const statuses = (response.body.results as PushResultShape[]).map((result) => result.status);
    expect(statuses).toEqual(["applied", "error", "error", "error"]);
  });

  it("applies a wishlist create, update and delete", async () => {
    const id = randomUUID();

    const created = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.bob))
      .send({
        changes: [{ entityType: "wishlist", op: "create", id, payload: { titleQuery: "zard", maxPriceCents: 500 } }],
      })
      .expect(200);
    expect((created.body.results[0] as PushResultShape).status).toBe("applied");

    const updated = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.bob))
      .send({
        changes: [{ entityType: "wishlist", op: "update", id, payload: { maxPriceCents: 900 } }],
      })
      .expect(200);
    expect((updated.body.results[0] as PushResultShape).serverItem?.maxPriceCents).toBe(900);

    const deleted = await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.bob))
      .send({ changes: [{ entityType: "wishlist", op: "delete", id, payload: {} }] })
      .expect(200);
    expect((deleted.body.results[0] as PushResultShape).status).toBe("applied");
    expect(await countRows("wishlist_entries")).toBe(0);
  });

  it("rejects an unparseable payload for the whole batch", async () => {
    await request(application)
      .post("/sync/push")
      .set("Authorization", auth(TOKENS.alice))
      .send({ changes: [{ entityType: "nonsense", op: "create", id: randomUUID(), payload: {} }] })
      .expect(422);
  });
});

describe("GET /sync/pull", () => {
  it("returns items, observations, trades and wishlist entries with a cursor", async () => {
    const item = await createItem(application, "alice", { title: "Pulled" });
    await request(application)
      .post(`/items/${item.id}/observations`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ sourceLabel: "eBay", valueCents: 1_234 })
      .expect(201);
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .send({ titleQuery: "pulled", maxPriceCents: 9_999 })
      .expect(201);

    const response = await request(application).get("/sync/pull").set("Authorization", auth(TOKENS.alice)).expect(200);

    expect(response.body.items).toHaveLength(1);
    expect(response.body.observations).toHaveLength(1);
    expect(response.body.wishlistEntries).toHaveLength(1);
    expect(response.body.trades).toHaveLength(0);
    expect(response.body.nextCursor).toMatch(/^\d{4}-.*\|[0-9]+$/);
    expect(response.body.hasMore).toBe(false);
  });

  it("advances the cursor monotonically and only returns newer rows", async () => {
    await createItem(application, "alice", { title: "One" });
    const first = await request(application).get("/sync/pull").set("Authorization", auth(TOKENS.alice)).expect(200);
    const cursor1 = first.body.nextCursor as string;

    const idle = await request(application)
      .get(`/sync/pull?since=${encodeURIComponent(cursor1)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(idle.body.items).toHaveLength(0);
    expect(Number((idle.body.nextCursor as string).split("|")[1])).toBeGreaterThanOrEqual(
      Number(cursor1.split("|")[1]),
    );

    await createItem(application, "alice", { title: "Two" });
    const second = await request(application)
      .get(`/sync/pull?since=${encodeURIComponent(cursor1)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(second.body.items).toHaveLength(1);
    expect(second.body.items[0].title).toBe("Two");
    expect(Number((second.body.nextCursor as string).split("|")[1])).toBeGreaterThan(Number(cursor1.split("|")[1]));
  });

  it("includes tombstones so deletes propagate", async () => {
    const item = await createItem(application, "alice", { title: "Vanishing" });
    const before = await request(application).get("/sync/pull").set("Authorization", auth(TOKENS.alice)).expect(200);

    await request(application).delete(`/items/${item.id}`).set("Authorization", auth(TOKENS.alice)).expect(200);

    const after = await request(application)
      .get(`/sync/pull?since=${encodeURIComponent(before.body.nextCursor)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);

    expect(after.body.items).toHaveLength(1);
    expect(after.body.items[0].isDeleted).toBe(true);
  });

  it("paginates with limit and reports hasMore", async () => {
    for (let index = 0; index < 3; index += 1) {
      await createItem(application, "alice", { title: `Paged ${index}` });
    }
    const page = await request(application)
      .get("/sync/pull?limit=2")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(page.body.items).toHaveLength(2);
    expect(page.body.hasMore).toBe(true);

    const next = await request(application)
      .get(`/sync/pull?limit=2&since=${encodeURIComponent(page.body.nextCursor)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(next.body.items).toHaveLength(1);
  });

  it("propagates ownership changes from an accepted trade", async () => {
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");

    const cursor = (await request(application).get("/sync/pull").set("Authorization", auth(TOKENS.bob)).expect(200))
      .body.nextCursor as string;

    const proposed = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .send({ receiverUserId: BOB, offeredItemIds: [aliceCard.id], requestedItemIds: [bobCard.id] })
      .expect(201);

    await request(application)
      .post(`/trades/${proposed.body.trade.id}/accept`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);

    const delta = await request(application)
      .get(`/sync/pull?since=${encodeURIComponent(cursor)}`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);

    const aliceRow = delta.body.items.find((row: { id: string }) => row.id === aliceCard.id);
    expect(aliceRow.ownerUserId).toBe(BOB);
    expect(delta.body.trades).toHaveLength(1);
  });
});

describe("telemetry", () => {
  it("accepts a batch of events", async () => {
    const response = await request(application)
      .post("/telemetry")
      .set("Authorization", auth(TOKENS.alice))
      .send({
        events: [
          { name: "sync.completed", durationMs: 412, retries: 2, conflicts: 1 },
          { name: "sync.error", errorMessage: "transport: connection reset" },
        ],
      })
      .expect(202);

    expect(response.body.accepted).toBe(2);
  });

  it("rejects a malformed batch", async () => {
    await request(application)
      .post("/telemetry")
      .set("Authorization", auth(TOKENS.alice))
      .send({ events: [{ name: "" }] })
      .expect(422);
  });
});

describe("cursor arithmetic", () => {
  it("allocates strictly increasing, unique change sequences", async () => {
    for (let index = 0; index < 5; index += 1) {
      await createItem(application, "alice", { title: `Row ${index}` });
    }

    const { rows } = await pool.query<{ change_seq: string }>(`SELECT change_seq FROM items ORDER BY change_seq ASC`);
    const seqs = rows.map((row) => Number(row.change_seq));
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
    expect(new Set(seqs).size).toBe(seqs.length);
  });
});

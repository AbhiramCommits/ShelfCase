import { beforeEach, describe, expect, it } from "vitest";
import {
  ALICE,
  BOB,
  TOKENS,
  app,
  auth,
  countRows,
  createItem,
  randomUUID,
  request,
  resetDatabase,
} from "./helpers.js";

const application = app();

beforeEach(async () => {
  await resetDatabase();
});

describe("GET /health", () => {
  it("reports ok without authentication", async () => {
    const response = await request(application).get("/health").expect(200);
    expect(response.body.status).toBe("ok");
    expect(response.body.service).toBe("shelfcase-api");
  });
});

describe("auth middleware", () => {
  it("rejects a request with no Authorization header", async () => {
    const response = await request(application).get("/items").expect(401);
    expect(response.body.error.code).toBe("UNAUTHORIZED");
    expect(response.body.requestId).toBeTruthy();
  });

  it("rejects an unknown bearer token", async () => {
    const response = await request(application)
      .get("/items")
      .set("Authorization", "Bearer dev-nobody")
      .expect(401);
    expect(response.body.error.message).toContain("dev-nobody");
  });

  it("rejects a malformed Authorization header", async () => {
    await request(application).get("/items").set("Authorization", "Token dev-alice").expect(401);
  });

  it("echoes an inbound X-Request-Id", async () => {
    const response = await request(application)
      .get("/health")
      .set("X-Request-Id", "trace-abc-123")
      .expect(200);
    expect(response.headers["x-request-id"]).toBe("trace-abc-123");
  });
});

describe("item CRUD", () => {
  it("creates an item and returns it with a wishlistMatches array", async () => {
    const id = randomUUID();
    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Charizard Base Set", setName: "Base Set", category: "card", conditionGrade: "mint" })
      .expect(201);

    expect(response.body.item.id).toBe(id);
    expect(response.body.item.ownerUserId).toBe(ALICE);
    expect(response.body.item.version).toBe(1);
    expect(response.body.item.isDeleted).toBe(false);
    expect(response.body.item.syncState).toBe("synced");
    expect(Array.isArray(response.body.wishlistMatches)).toBe(true);
    expect(await countRows("items")).toBe(1);
  });

  it("defaults category, grade and prices when the body omits them", async () => {
    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "Bare Minimum" })
      .expect(201);

    expect(response.body.item.category).toBe("other");
    expect(response.body.item.conditionGrade).toBe("nearMint");
    expect(response.body.item.purchasePriceCents).toBe(0);
    expect(response.body.item.notes).toBe("");
  });

  it("rejects an invalid body with a structured 422", async () => {
    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "", category: "spaceship" })
      .expect(422);

    expect(response.body.error.code).toBe("VALIDATION_ERROR");
    expect(response.body.error.details.length).toBeGreaterThan(0);
  });

  it("reads an item back by id", async () => {
    const item = await createItem(application, "alice", { title: "Sol Ring" });
    const response = await request(application)
      .get(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(response.body.item.title).toBe("Sol Ring");
  });

  it("404s for an unknown item", async () => {
    const response = await request(application)
      .get(`/items/${randomUUID()}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(404);
    expect(response.body.error.code).toBe("NOT_FOUND");
  });

  it("patches fields and bumps the version", async () => {
    const item = await createItem(application, "alice", { title: "Before" });

    const response = await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "After", notes: "sleeved", version: 1 })
      .expect(200);

    expect(response.body.item.title).toBe("After");
    expect(response.body.item.notes).toBe("sleeved");
    expect(response.body.item.version).toBe(2);
  });

  it("rejects a stale version with 409 and the server copy", async () => {
    const item = await createItem(application, "alice", { title: "Contested" });

    // First writer wins and moves the row to version 2.
    await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ notes: "first writer", version: 1 })
      .expect(200);

    // Second writer still believes it is version 1.
    const stale = await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ notes: "second writer", version: 1 })
      .expect(409);

    expect(stale.body.error.code).toBe("VERSION_CONFLICT");
    expect(stale.body.error.details.serverItem.version).toBe(2);
    expect(stale.body.error.details.serverItem.notes).toBe("first writer");

    const current = await request(application)
      .get(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(current.body.item.notes).toBe("first writer");
  });

  it("allows a patch with no version (last-writer-wins)", async () => {
    const item = await createItem(application, "alice");
    const response = await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "LWW" })
      .expect(200);
    expect(response.body.item.title).toBe("LWW");
    expect(response.body.item.version).toBe(2);
  });

  it("404s a patch against a missing item", async () => {
    await request(application)
      .patch(`/items/${randomUUID()}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "ghost" })
      .expect(404);
  });

  it("returns the unchanged item when a patch has no fields", async () => {
    const item = await createItem(application, "alice", { title: "Stable" });
    const response = await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({})
      .expect(200);
    expect(response.body.item.title).toBe("Stable");
    expect(response.body.item.version).toBe(1);
  });

  it("soft-deletes and hides the item from the default listing", async () => {
    const item = await createItem(application, "alice", { title: "Doomed" });

    const deleted = await request(application)
      .delete(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(deleted.body.item.isDeleted).toBe(true);
    expect(deleted.body.item.version).toBe(2);

    // Still in the table (tombstone), but not in a default listing.
    expect(await countRows("items")).toBe(1);
    const listing = await request(application).get("/items").set("Authorization", auth(TOKENS.alice)).expect(200);
    expect(listing.body.items).toHaveLength(0);

    const withDeleted = await request(application)
      .get("/items?includeDeleted=true")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(withDeleted.body.items).toHaveLength(1);
  });

  it("rejects deleting a stale version", async () => {
    const item = await createItem(application, "alice");
    await request(application)
      .patch(`/items/${item.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "moved on", version: 1 })
      .expect(200);

    await request(application)
      .delete(`/items/${item.id}?version=1`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(409);
  });
});

describe("item listing filters and delta sync", () => {
  it("filters by category, grade and search text", async () => {
    await createItem(application, "alice", { title: "Alpha Card", category: "card", conditionGrade: "mint" });
    await createItem(application, "alice", { title: "Beta Figure", category: "figure", conditionGrade: "poor" });

    const cards = await request(application)
      .get("/items?category=card")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(cards.body.items.map((i: { title: string }) => i.title)).toEqual(["Alpha Card"]);

    const poor = await request(application)
      .get("/items?grade=poor")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(poor.body.items.map((i: { title: string }) => i.title)).toEqual(["Beta Figure"]);

    const search = await request(application)
      .get("/items?search=alpha")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(search.body.items.map((i: { title: string }) => i.title)).toEqual(["Alpha Card"]);
  });

  it("returns only rows changed after the supplied cursor", async () => {
    const first = await createItem(application, "alice", { title: "First" });
    await createItem(application, "alice", { title: "Second" });

    const page = await request(application)
      .get("/items")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    const cursor = page.body.nextCursor as string;
    expect(cursor).toMatch(/\|/);

    // Nothing new yet.
    const empty = await request(application)
      .get(`/items?since=${encodeURIComponent(cursor)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(empty.body.items).toHaveLength(0);

    await request(application)
      .patch(`/items/${first.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ notes: "touched" })
      .expect(200);

    const delta = await request(application)
      .get(`/items?since=${encodeURIComponent(cursor)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(delta.body.items).toHaveLength(1);
    expect(delta.body.items[0].id).toBe(first.id);
  });

  it("also accepts a bare ISO8601 cursor", async () => {
    await createItem(application, "alice", { title: "Old" });
    const response = await request(application)
      .get(`/items?since=${encodeURIComponent(new Date(Date.now() + 60_000).toISOString())}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(response.body.items).toHaveLength(0);
  });

  it("pages with limit and reports hasMore", async () => {
    for (let index = 0; index < 5; index += 1) {
      await createItem(application, "alice", { title: `Item ${index}` });
    }
    const first = await request(application)
      .get("/items?limit=2")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(first.body.items).toHaveLength(2);
    expect(first.body.hasMore).toBe(true);

    const second = await request(application)
      .get(`/items?limit=2&since=${encodeURIComponent(first.body.nextCursor)}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(second.body.items).toHaveLength(2);
    expect(second.body.items[0].id).not.toBe(first.body.items[0].id);
  });
});

describe("price observations", () => {
  it("creates and lists observations newest-first", async () => {
    const item = await createItem(application, "alice", { title: "Priced" });

    await request(application)
      .post(`/items/${item.id}/observations`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ sourceLabel: "eBay", valueCents: 1_500, observedAt: "2024-01-01T00:00:00.000Z" })
      .expect(201);

    await request(application)
      .post(`/items/${item.id}/observations`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ sourceLabel: "TCGPlayer", valueCents: 1_800, observedAt: "2024-06-01T00:00:00.000Z" })
      .expect(201);

    const list = await request(application)
      .get(`/items/${item.id}/observations`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);

    expect(list.body.observations).toHaveLength(2);
    expect(list.body.observations[0].sourceLabel).toBe("TCGPlayer");
    expect(list.body.observations[0].valueCents).toBe(1_800);
  });

  it("404s an observation for a missing item", async () => {
    await request(application)
      .post(`/items/${randomUUID()}/observations`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ sourceLabel: "eBay", valueCents: 100 })
      .expect(404);
  });
});

describe("unknown routes", () => {
  it("returns a structured 404", async () => {
    const response = await request(application)
      .get("/nope")
      .set("Authorization", auth(TOKENS.alice))
      .expect(404);
    expect(response.body.error.code).toBe("NOT_FOUND");
  });
});

describe("ownership", () => {
  it("scopes created items to the authenticated user", async () => {
    const aliceItem = await createItem(application, "alice", { title: "Alice's" });
    const bobItem = await createItem(application, "bob", { title: "Bob's" });
    expect(aliceItem.ownerUserId).toBe(ALICE);
    expect(bobItem.ownerUserId).toBe(BOB);
  });
});

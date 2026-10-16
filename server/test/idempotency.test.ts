import { beforeEach, describe, expect, it } from "vitest";
import {
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

describe("idempotency middleware", () => {
  it("replays the stored response for a repeated POST", async () => {
    const key = randomUUID();
    const body = { title: "Idempotent Card" };

    const first = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send(body)
      .expect(201);

    const second = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send(body)
      .expect(201);

    expect(second.headers["idempotency-replayed"]).toBe("true");
    expect(second.body.item.id).toBe(first.body.item.id);
    expect(await countRows("items")).toBe(1);
  });

  it("creates exactly one row across many concurrent identical POSTs", async () => {
    const key = randomUUID();
    const responses = await Promise.all(
      Array.from({ length: 8 }, () =>
        request(application)
          .post("/items")
          .set("Authorization", auth(TOKENS.alice))
          .set("Idempotency-Key", key)
          .send({ title: "Concurrent" }),
      ),
    );

    const created = responses.filter((response) => response.status === 201);
    const inFlight = responses.filter((response) => response.status === 409);
    expect(created.length + inFlight.length).toBe(8);
    expect(inFlight.every((response) => response.body.error.code === "IDEMPOTENCY_IN_PROGRESS")).toBe(true);

    // Every response that succeeded refers to the same row, and only one row exists.
    const ids = new Set(created.map((response) => response.body.item.id as string));
    expect(ids.size).toBe(1);
    expect(await countRows("items")).toBe(1);
  });

  it("treats different keys as different operations", async () => {
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", randomUUID())
      .send({ title: "One" })
      .expect(201);

    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", randomUUID())
      .send({ title: "Two" })
      .expect(201);

    expect(await countRows("items")).toBe(2);
  });

  it("keys the log per idempotency key, not per route", async () => {
    const key = randomUUID();
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send({ titleQuery: "charizard", maxPriceCents: 1_000 })
      .expect(201);

    // Replaying the same key against a different route returns the original response.
    const replay = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send({ title: "Something else" })
      .expect(201);

    expect(replay.body.wishlistEntry).toBeDefined();
    expect(await countRows("items")).toBe(0);
  });

  it("stores the response so a later retry gets byte-identical output", async () => {
    const key = randomUUID();
    const payload = { title: "Replay Me", estimatedValueCents: 4242 };

    const first = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send(payload)
      .expect(201);

    const retry = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send(payload)
      .expect(201);

    expect(retry.body).toEqual(first.body);
  });

  it("errors are not cached: a failed request can be retried", async () => {
    const key = randomUUID();

    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send({ title: "" })
      .expect(422);

    // Same key, corrected body — must be allowed to proceed.
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send({ title: "Fixed" })
      .expect(201);

    expect(await countRows("items")).toBe(1);
  });

  it("leaves GET requests alone", async () => {
    await createItem(application, "alice");
    await request(application)
      .get("/items")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", randomUUID())
      .expect(200);
    expect(await countRows("request_log")).toBe(0);
  });

  it("applies to trades as well as items", async () => {
    const key = randomUUID();
    const aliceCard = await createItem(application, "alice");
    const bobCard = await createItem(application, "bob");

    const payload = {
      receiverUserId: "22222222-2222-4222-8222-222222222222",
      offeredItemIds: [aliceCard.id],
      requestedItemIds: [bobCard.id],
    };

    const first = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send(payload)
      .expect(201);

    const second = await request(application)
      .post("/trades")
      .set("Authorization", auth(TOKENS.alice))
      .set("Idempotency-Key", key)
      .send(payload)
      .expect(201);

    expect(second.body.trade.id).toBe(first.body.trade.id);
    expect(await countRows("trades")).toBe(1);
  });
});

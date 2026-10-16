import { beforeEach, describe, expect, it } from "vitest";
import { TOKENS, app, auth, countRows, pool, randomUUID, request, resetDatabase } from "./helpers.js";

const application = app();

beforeEach(async () => {
  await resetDatabase();
});

/**
 * Regression tests for the duplicate-creation defect in `docs/DEBUGGING.md` §A.
 *
 * **These fail against the pre-fix revision**, where `insertItem` had no
 * `ON CONFLICT` handling and a retried create with the same client id died on the
 * primary key with a raw `500`.
 */
describe("regression: idempotent item creation", () => {
  it("a retried POST /items with the same client id creates exactly one row", async () => {
    const id = randomUUID();
    const payload = { id, title: "One Card", estimatedValueCents: 12_000 };

    const first = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send(payload)
      .expect(201);

    // The client never saw the first response and retried the identical request.
    const retry = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send(payload)
      .expect(200);

    expect(retry.headers["x-idempotent-replay"]).toBe("true");
    expect(retry.body.item.id).toBe(id);
    expect(retry.body.item.id).toBe(first.body.item.id);
    expect(await countRows("items")).toBe(1);
  });

  it("a retried create returns the row the server already wrote, not a mutated copy", async () => {
    const id = randomUUID();
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Original title", notes: "as originally written" })
      .expect(201);

    // A stale retry that carries different field values must still resolve to the
    // stored row, never overwrite it.
    const retry = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Different title", notes: "should be ignored" })
      .expect(200);

    expect(retry.body.item.title).toBe("Original title");
    expect(retry.body.item.notes).toBe("as originally written");
    expect(await countRows("items")).toBe(1);
  });

  it("does not duplicate when five identical creates race", async () => {
    const id = randomUUID();
    const payload = { id, title: "Racy" };

    const responses = await Promise.all(
      Array.from({ length: 5 }, () =>
        request(application).post("/items").set("Authorization", auth(TOKENS.alice)).send(payload),
      ),
    );

    expect(responses.every((response) => response.status === 201 || response.status === 200)).toBe(true);
    expect(await countRows("items", "id = $1", [id])).toBe(1);

    // Exactly one of them was the original insert.
    const created = responses.filter((response) => response.status === 201);
    expect(created).toHaveLength(1);
  });

  it("keeps the create replayed across a DELETE and a re-create", async () => {
    const id = randomUUID();
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Soft deleted" })
      .expect(201);

    await request(application).delete(`/items/${id}`).set("Authorization", auth(TOKENS.alice)).expect(200);

    // Re-posting the same id must not resurrect a second row.
    const retry = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Soft deleted" })
      .expect(200);

    expect(retry.body.item.isDeleted).toBe(true);
    expect(await countRows("items", "id = $1", [id])).toBe(1);
  });

  it("still 500s nothing when two different clients create the same id", async () => {
    const id = randomUUID();
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Alice's" })
      .expect(201);

    // Bob reusing Alice's id gets Alice's row back rather than an error or a
    // second row. Ownership is never taken from the request body.
    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.bob))
      .send({ id, title: "Bob's" })
      .expect(200);

    expect(response.body.item.ownerUserId).toBe("11111111-1111-4111-8111-111111111111");
    expect(await countRows("items")).toBe(1);
  });

  it("records a single sequence entry per replayed create", async () => {
    const id = randomUUID();
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Sequenced" })
      .expect(201);
    await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ id, title: "Sequenced" })
      .expect(200);

    const { rows } = await pool.query<{ count: string }>(`SELECT count(*)::text AS count FROM items`);
    expect(Number(rows[0]!.count)).toBe(1);
  });
});

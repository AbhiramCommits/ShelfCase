import { beforeEach, describe, expect, it } from "vitest";
import {
  BOB,
  TOKENS,
  app,
  auth,
  countRows,
  request,
  resetDatabase,
} from "./helpers.js";

const application = app();

beforeEach(async () => {
  await resetDatabase();
});

describe("wishlist CRUD", () => {
  it("creates, lists, updates and deletes entries scoped to the user", async () => {
    const created = await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .send({ titleQuery: "charizard", maxPriceCents: 50_000 })
      .expect(201);

    expect(created.body.wishlistEntry.titleQuery).toBe("charizard");
    expect(created.body.wishlistEntry.userId).toBe(
      "11111111-1111-4111-8111-111111111111",
    );

    const listed = await request(application)
      .get("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .expect(200);
    expect(listed.body.wishlistEntries).toHaveLength(1);

    const otherUser = await request(application)
      .get("/wishlist")
      .set("Authorization", auth(TOKENS.bob))
      .expect(200);
    expect(otherUser.body.wishlistEntries).toHaveLength(0);

    const patched = await request(application)
      .patch(`/wishlist/${created.body.wishlistEntry.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({ maxPriceCents: 99_000 })
      .expect(200);
    expect(patched.body.wishlistEntry.maxPriceCents).toBe(99_000);

    await request(application)
      .delete(`/wishlist/${created.body.wishlistEntry.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .expect(204);

    expect(await countRows("wishlist_entries")).toBe(0);
  });

  it("rejects a blank title query", async () => {
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .send({ titleQuery: "   ", maxPriceCents: 100 })
      .expect(422);
  });

  it("404s updates and deletes for entries owned by someone else", async () => {
    const created = await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .send({ titleQuery: "charizard", maxPriceCents: 1_000 })
      .expect(201);

    await request(application)
      .patch(`/wishlist/${created.body.wishlistEntry.id}`)
      .set("Authorization", auth(TOKENS.bob))
      .send({ maxPriceCents: 2_000 })
      .expect(404);

    await request(application)
      .delete(`/wishlist/${created.body.wishlistEntry.id}`)
      .set("Authorization", auth(TOKENS.bob))
      .expect(404);
  });

  it("returns the entry unchanged for an empty patch", async () => {
    const created = await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .send({ titleQuery: "sol ring", maxPriceCents: 1_000 })
      .expect(201);

    const patched = await request(application)
      .patch(`/wishlist/${created.body.wishlistEntry.id}`)
      .set("Authorization", auth(TOKENS.alice))
      .send({})
      .expect(200);
    expect(patched.body.wishlistEntry.titleQuery).toBe("sol ring");
  });
});

describe("wishlist matching on item create", () => {
  it("returns matching wishlist entries so the client can notify", async () => {
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.bob))
      .send({ titleQuery: "charizard", maxPriceCents: 10_000 })
      .expect(201);

    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "Charizard Base Set Holo", estimatedValueCents: 9_500 })
      .expect(201);

    expect(response.body.wishlistMatches).toHaveLength(1);
    expect(response.body.wishlistMatches[0].userId).toBe(BOB);
    expect(response.body.wishlistMatches[0].titleQuery).toBe("charizard");
  });

  it("does not match when the price is above the ceiling", async () => {
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.bob))
      .send({ titleQuery: "charizard", maxPriceCents: 1_000 })
      .expect(201);

    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "Charizard Base Set Holo", estimatedValueCents: 9_500 })
      .expect(201);

    expect(response.body.wishlistMatches).toHaveLength(0);
  });

  it("never matches the creator's own wishlist", async () => {
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.alice))
      .send({ titleQuery: "charizard", maxPriceCents: 99_999 })
      .expect(201);

    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "Charizard", estimatedValueCents: 100 })
      .expect(201);

    expect(response.body.wishlistMatches).toHaveLength(0);
  });

  it("matches case-insensitively on a substring", async () => {
    await request(application)
      .post("/wishlist")
      .set("Authorization", auth(TOKENS.bob))
      .send({ titleQuery: "ZARD", maxPriceCents: 99_999 })
      .expect(201);

    const response = await request(application)
      .post("/items")
      .set("Authorization", auth(TOKENS.alice))
      .send({ title: "mega CHARIzard ex", estimatedValueCents: 100 })
      .expect(201);

    expect(response.body.wishlistMatches).toHaveLength(1);
  });
});

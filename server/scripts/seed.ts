/**
 * Deterministic demo dataset.
 *
 * Everything is derived from a seeded PRNG and fixed UUIDs, so running
 * `npm run seed` repeatedly converges on exactly the same rows (upserts keyed on
 * `id`) and the printed counts are stable.
 *
 * Usage: npm run seed
 */
import { pool, migrate, closePool } from "../src/db.js";
import { SEED_USERS } from "../src/config.js";

const SEED = 0x5eed1234;

/** mulberry32 — small, fast, deterministic. */
function makeRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const random = makeRandom(SEED);
const pick = <T>(values: readonly T[]): T => values[Math.floor(random() * values.length)]!;
const intBetween = (min: number, max: number): number => min + Math.floor(random() * (max - min + 1));

const CATEGORIES = ["card", "figure", "vinyl", "other"] as const;
const GRADES = ["mint", "nearMint", "excellent", "good", "poor"] as const;

const TITLES: Record<(typeof CATEGORIES)[number], string[]> = {
  card: [
    "Charizard Base Set Holo",
    "Black Lotus",
    "Mox Sapphire",
    "Blue-Eyes White Dragon",
    "Sol Ring",
    "Time Walk",
    "Pikachu Illustrator",
    "Dark Magician Girl",
    "Jace, the Mind Sculptor",
    "Liliana of the Veil",
    "Blastoise 1st Edition",
    "Mox Jet",
  ],
  figure: [
    "Hot Toys Iron Man Mark 85",
    "S.H. Figuarts Goku",
    "Mafex Spider-Man 075",
    "Nendoroid Hatsune Miku",
    "Funko Pop! Batman #01",
    "Revoltech Evangelion Unit-01",
    "Storm Collectibles Scorpion",
    "Bandai Metal Build Strike Freedom",
  ],
  vinyl: [
    "Kind of Blue — First Press",
    "The Dark Side of the Moon — Harvest",
    "Abbey Road — Apple Press",
    "Blue Train — Blue Note Mono",
    "Rumours — Warner Bros",
    "Nevermind — DGC Original",
    "Illmatic — Columbia",
    "Blonde — Boys Don't Cry",
  ],
  other: [
    "Pokemon Booster Box 1999",
    "Sealed NES Classic Edition",
    "Rolex Submariner 16610",
    "Signed Michael Jordan Jersey",
    "LEGO UCS Millennium Falcon",
    "Original Star Wars Kenner Boba Fett",
  ],
};

const SET_NAMES: Record<(typeof CATEGORIES)[number], string[]> = {
  card: ["Base Set", "Alpha", "Beta", "Legend of Blue Eyes", "Commander Legends"],
  figure: ["Marvel Legends", "Dragon Ball Z", "Amazing Yamaguchi", "Figuarts Zero"],
  vinyl: ["Blue Note", "Harvest", "Apple", "Columbia", "DGC"],
  other: ["Factory Sealed", "Estate Sale", "Auction Lot", "Private Collection"],
};

const SOURCES = ["eBay", "TCGPlayer", "Discogs", "Heritage Auctions", "CardMarket"] as const;

async function main(): Promise<void> {
  await migrate();

  // ------------------------------------------------------------- users ---
  await pool.query(
    `INSERT INTO users (id, display_name, email) VALUES
       ($1, 'Alice Nguyen',  'alice@shelfcase.test'),
       ($2, 'Bob Ramirez',   'bob@shelfcase.test'),
       ($3, 'Carol Whitaker','carol@shelfcase.test')
     ON CONFLICT (id) DO UPDATE
       SET display_name = EXCLUDED.display_name, email = EXCLUDED.email`,
    [SEED_USERS.alice, SEED_USERS.bob, SEED_USERS.carol],
  );

  const owners = [SEED_USERS.alice, SEED_USERS.alice, SEED_USERS.bob, SEED_USERS.carol];

  // ------------------------------------------------------------- items ---
  const ITEM_COUNT = 48;
  const itemIds: string[] = [];
  const itemOwner = new Map<string, string>();
  const itemValue = new Map<string, number>();

  for (let index = 0; index < ITEM_COUNT; index += 1) {
    const category = CATEGORIES[index % CATEGORIES.length]!;
    const title = TITLES[category][Math.floor(index / CATEGORIES.length) % TITLES[category].length]!;
    const setName = pick(SET_NAMES[category]);
    const grade = pick(GRADES);
    const purchasePriceCents = intBetween(500, 250_000);
    const estimatedValueCents = Math.round(purchasePriceCents * (0.6 + random() * 1.6));
    const owner = owners[index % owners.length]!;
    const id = `a0000000-0000-4000-a000-${String(index).padStart(12, "0")}`;
    const acquiredDaysAgo = intBetween(1, 900);

    await pool.query(
      `INSERT INTO items
         (id, owner_user_id, title, set_name, category, condition_grade,
          purchase_price_cents, estimated_value_cents, acquired_at, notes, image_local_path)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now() - ($9 || ' days')::interval, $10, NULL)
       ON CONFLICT (id) DO UPDATE
         SET owner_user_id = EXCLUDED.owner_user_id,
             title = EXCLUDED.title,
             set_name = EXCLUDED.set_name,
             category = EXCLUDED.category,
             condition_grade = EXCLUDED.condition_grade,
             purchase_price_cents = EXCLUDED.purchase_price_cents,
             estimated_value_cents = EXCLUDED.estimated_value_cents,
             notes = EXCLUDED.notes,
             updated_at = now()`,
      [
        id,
        owner,
        title,
        setName,
        category,
        grade,
        purchasePriceCents,
        estimatedValueCents,
        acquiredDaysAgo,
        `${grade} — acquired via ${pick(SOURCES)}`,
      ],
    );

    itemIds.push(id);
    itemOwner.set(id, owner);
    itemValue.set(id, estimatedValueCents);
  }

  // ---------------------------------------------- price observations ---
  let observationIndex = 0;

  for (const itemId of itemIds) {
    const base = Math.max(100, Math.round((itemValue.get(itemId) ?? 1_000) * (0.75 + random() * 0.5)));
    const samples = intBetween(3, 6); // 48 items x 3..6 => 144..288 observations
    for (let sample = 0; sample < samples; sample += 1) {
      const drift = 1 + (random() - 0.45) * 0.25;
      const valueCents = Math.max(1, Math.round(base * drift));
      const daysAgo = intBetween(0, 400);
      const id = `b0000000-0000-4000-a000-${String(observationIndex).padStart(12, "0")}`;
      observationIndex += 1;

      await pool.query(
        `INSERT INTO price_observations (id, item_id, source_label, value_cents, observed_at)
         VALUES ($1, $2, $3, $4, now() - ($5 || ' days')::interval)
         ON CONFLICT (id) DO UPDATE
           SET value_cents = EXCLUDED.value_cents, observed_at = EXCLUDED.observed_at`,
        [id, itemId, pick(SOURCES), valueCents, daysAgo],
      );
    }
  }

  // ------------------------------------------------------------ trades ---
  const aliceItems = itemIds.filter((id) => itemOwner.get(id) === SEED_USERS.alice);
  const bobItems = itemIds.filter((id) => itemOwner.get(id) === SEED_USERS.bob);
  const carolItems = itemIds.filter((id) => itemOwner.get(id) === SEED_USERS.carol);

  const tradePlans = [
    { proposer: SEED_USERS.alice, receiver: SEED_USERS.bob, offered: aliceItems.slice(0, 2), requested: bobItems.slice(0, 1), status: "proposed" },
    { proposer: SEED_USERS.bob, receiver: SEED_USERS.alice, offered: bobItems.slice(1, 2), requested: aliceItems.slice(2, 3), status: "proposed" },
    { proposer: SEED_USERS.carol, receiver: SEED_USERS.alice, offered: carolItems.slice(0, 1), requested: aliceItems.slice(3, 4), status: "declined" },
    { proposer: SEED_USERS.alice, receiver: SEED_USERS.carol, offered: aliceItems.slice(4, 5), requested: carolItems.slice(1, 2), status: "cancelled" },
    { proposer: SEED_USERS.bob, receiver: SEED_USERS.carol, offered: bobItems.slice(2, 3), requested: carolItems.slice(2, 3), status: "accepted" },
  ].filter((plan) => plan.offered.length > 0 && plan.requested.length > 0);

  let tradeIndex = 0;
  for (const plan of tradePlans) {
    const id = `c0000000-0000-4000-a000-${String(tradeIndex).padStart(12, "0")}`;
    tradeIndex += 1;

    await pool.query(
      `INSERT INTO trades (id, proposer_user_id, receiver_user_id, status)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, updated_at = now()`,
      [id, plan.proposer, plan.receiver, plan.status],
    );

    await pool.query(`DELETE FROM trade_items WHERE trade_id = $1`, [id]);

    for (const itemId of plan.offered) {
      await pool.query(`INSERT INTO trade_items (trade_id, item_id, side) VALUES ($1, $2, 'offered')`, [id, itemId]);
    }
    for (const itemId of plan.requested) {
      await pool.query(`INSERT INTO trade_items (trade_id, item_id, side) VALUES ($1, $2, 'requested')`, [id, itemId]);
    }

    // Keep accepted trades consistent with the ownership swap the API performs.
    if (plan.status === "accepted") {
      await pool.query(`UPDATE items SET owner_user_id = $1 WHERE id = ANY($2::uuid[])`, [
        plan.receiver,
        plan.offered,
      ]);
      await pool.query(`UPDATE items SET owner_user_id = $1 WHERE id = ANY($2::uuid[])`, [
        plan.proposer,
        plan.requested,
      ]);
    }
  }

  // ---------------------------------------------------------- wishlist ---
  const wishlistPlans = [
    { user: SEED_USERS.bob, query: "charizard", max: 120_000 },
    { user: SEED_USERS.bob, query: "black lotus", max: 400_000 },
    { user: SEED_USERS.carol, query: "iron man", max: 90_000 },
    { user: SEED_USERS.carol, query: "kind of blue", max: 30_000 },
    { user: SEED_USERS.alice, query: "boba fett", max: 55_000 },
    { user: SEED_USERS.alice, query: "dark side", max: 25_000 },
  ];

  for (const [index, plan] of wishlistPlans.entries()) {
    await pool.query(
      `INSERT INTO wishlist_entries (id, user_id, title_query, max_price_cents)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET title_query = EXCLUDED.title_query, max_price_cents = EXCLUDED.max_price_cents`,
      [`d0000000-0000-4000-a000-${String(index).padStart(12, "0")}`, plan.user, plan.query, plan.max],
    );
  }

  // ------------------------------------------------------------- report ---
  const counts = await pool.query<{ table_name: string; row_count: string }>(`
    SELECT 'users'             AS table_name, count(*)::text AS row_count FROM users
    UNION ALL SELECT 'items',              count(*)::text FROM items
    UNION ALL SELECT 'price_observations', count(*)::text FROM price_observations
    UNION ALL SELECT 'trades',             count(*)::text FROM trades
    UNION ALL SELECT 'trade_items',        count(*)::text FROM trade_items
    UNION ALL SELECT 'wishlist_entries',   count(*)::text FROM wishlist_entries
  `);

  console.log("seeded row counts:");
  for (const row of counts.rows) {
    console.log(`  ${row.table_name.padEnd(20)} ${row.row_count}`);
  }
}

main()
  .then(() => closePool())
  .catch(async (error: unknown) => {
    console.error("seed failed:", error instanceof Error ? error.message : error);
    await closePool();
    process.exit(1);
  });

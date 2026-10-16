import type { Queryable } from "../db.js";

export interface WishlistMatchDto {
  id: string;
  userId: string;
  titleQuery: string;
  maxPriceCents: number;
  createdAt: string;
}

/**
 * Wishlist entries (belonging to anyone *other than* the owner) that a
 * newly-created item satisfies. Returned inline on `POST /items` so the client
 * can raise a local notification without a second round trip.
 */
export async function findWishlistMatches(
  queryable: Queryable,
  ownerUserId: string,
  title: string,
  estimatedValueCents: number,
): Promise<WishlistMatchDto[]> {
  const { rows } = await queryable.query(
    `SELECT id, user_id, title_query, max_price_cents, created_at
       FROM wishlist_entries
      WHERE user_id <> $1
        AND max_price_cents >= $3
        AND trim(title_query) <> ''
        AND lower($2) LIKE '%' || lower(trim(title_query)) || '%'
      ORDER BY created_at ASC
      LIMIT 50`,
    [ownerUserId, title, estimatedValueCents],
  );

  return rows.map((row) => ({
    id: String(row.id),
    userId: String(row.user_id),
    titleQuery: String(row.title_query),
    maxPriceCents: Number(row.max_price_cents),
    createdAt: new Date(row.created_at as string).toISOString(),
  }));
}

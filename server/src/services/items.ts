import { randomUUID } from "node:crypto";
import type { Queryable } from "../db.js";
import type { ItemRow } from "../mappers.js";
import type { ItemCreateInput, ItemPatchInput } from "../schemas.js";

export type { ItemCreateInput, ItemPatchInput };

/**
 * Insert a new item.
 *
 * Ownership is always taken from the authenticated caller, never from the
 * request body — `ownerUserId` is listed in the payload schema only so clients
 * can round-trip a full `CollectibleItem` through the sync push endpoint.
 */
export async function insertItem(
  queryable: Queryable,
  ownerUserId: string,
  body: ItemCreateInput,
): Promise<ItemRow> {
  const id = body.id ?? randomUUID();

  const { rows } = await queryable.query<ItemRow>(
    `INSERT INTO items
       (id, owner_user_id, title, set_name, category, condition_grade,
        purchase_price_cents, estimated_value_cents, acquired_at, notes, image_local_path)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9::timestamptz, now()), $10, $11)
     RETURNING *`,
    [
      id,
      ownerUserId,
      body.title,
      body.setName,
      body.category,
      body.conditionGrade,
      body.purchasePriceCents,
      body.estimatedValueCents,
      body.acquiredAt ?? null,
      body.notes,
      body.imageLocalPath ?? null,
    ],
  );

  return rows[0]!;
}

/** Soft delete that participates in delta sync via `change_seq`. */
export async function softDeleteItem(queryable: Queryable, id: string): Promise<ItemRow | null> {
  const { rows } = await queryable.query<ItemRow>(
    `UPDATE items
        SET is_deleted = true, version = version + 1, updated_at = now(), change_seq = nextval('change_seq')
      WHERE id = $1
      RETURNING *`,
    [id],
  );
  return rows[0] ?? null;
}

/**
 * Apply a field patch guarded by optimistic concurrency.
 *
 * @returns `{ row }` on success, `{ row: existing, conflict: true }` when the
 *          caller's `expectedVersion` is stale.
 */
export async function patchItem(
  queryable: Queryable,
  id: string,
  expectedVersion: number | undefined,
  fields: Omit<ItemPatchInput, "version">,
): Promise<{ row: ItemRow | null; conflict: boolean }> {
  const existing = await queryable.query<ItemRow>(`SELECT * FROM items WHERE id = $1`, [id]);
  const current = existing.rows[0];
  if (!current) return { row: null, conflict: false };

  if (expectedVersion !== undefined && expectedVersion < current.version) {
    return { row: current, conflict: true };
  }

  const assignments: string[] = [];
  const params: unknown[] = [];
  const push = (column: string, value: unknown) => {
    params.push(value);
    assignments.push(`${column} = $${params.length}`);
  };

  if (fields.title !== undefined) push("title", fields.title);
  if (fields.setName !== undefined) push("set_name", fields.setName);
  if (fields.category !== undefined) push("category", fields.category);
  if (fields.conditionGrade !== undefined) push("condition_grade", fields.conditionGrade);
  if (fields.purchasePriceCents !== undefined) push("purchase_price_cents", fields.purchasePriceCents);
  if (fields.estimatedValueCents !== undefined) push("estimated_value_cents", fields.estimatedValueCents);
  if (fields.acquiredAt !== undefined) push("acquired_at", fields.acquiredAt);
  if (fields.notes !== undefined) push("notes", fields.notes);
  if (fields.imageLocalPath !== undefined) push("image_local_path", fields.imageLocalPath);

  if (assignments.length === 0) return { row: current, conflict: false };

  params.push(id);
  const idIdx = params.length;
  params.push(current.version);
  const versionIdx = params.length;

  const { rows } = await queryable.query<ItemRow>(
    `UPDATE items
        SET ${assignments.join(", ")},
            version = version + 1,
            updated_at = now(),
            change_seq = nextval('change_seq')
      WHERE id = $${idIdx} AND version = $${versionIdx}
      RETURNING *`,
    params,
  );

  if (!rows[0]) {
    const latest = await queryable.query<ItemRow>(`SELECT * FROM items WHERE id = $1`, [id]);
    return { row: latest.rows[0] ?? null, conflict: true };
  }
  return { row: rows[0], conflict: false };
}

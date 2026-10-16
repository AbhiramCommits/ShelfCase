/**
 * Delta-sync cursors.
 *
 * `updated_at` alone is not a safe cursor: two rows committed inside the same
 * millisecond are indistinguishable, so a client that pages with
 * `updated_at > lastSeen` can skip a row forever. Every mutable table therefore
 * also carries `change_seq` from one global sequence, and the cursor is
 *
 *     <updated_at ISO8601>|<change_seq>
 *
 * A bare ISO8601 string is still accepted (treated as `change_seq = 0`) so the
 * documented `?since=` API keeps working for simple clients.
 */
export interface Cursor {
  updatedAt: string | null;
  seq: number;
}

const EPOCH = "1970-01-01T00:00:00.000Z";

export function parseCursor(raw: string | undefined): Cursor {
  if (!raw) return { updatedAt: null, seq: 0 };
  const separator = raw.lastIndexOf("|");
  if (separator === -1) {
    return { updatedAt: normalizeIso(raw), seq: 0 };
  }
  const iso = raw.slice(0, separator);
  const seq = Number(raw.slice(separator + 1));
  return {
    updatedAt: normalizeIso(iso),
    seq: Number.isFinite(seq) && seq > 0 ? Math.floor(seq) : 0,
  };
}

export function formatCursor(updatedAt: Date | string | null, seq: number | string): string {
  const iso = updatedAt === null ? EPOCH : normalizeIso(updatedAt);
  return `${iso}|${seq}`;
}

function normalizeIso(value: Date | string): string {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new Error(`Invalid ISO8601 cursor component: ${String(value)}`);
  }
  return date.toISOString();
}

/** Highest cursor across a page of rows, or the incoming cursor when empty. */
export function advanceCursor(
  incoming: Cursor,
  rows: Array<{ updated_at: Date | string; change_seq: string | number }>,
): string {
  if (rows.length === 0) {
    return incoming.updatedAt === null
      ? formatCursor(null, incoming.seq)
      : formatCursor(incoming.updatedAt, incoming.seq);
  }
  let best = rows[0]!;
  for (const row of rows) {
    if (Number(row.change_seq) > Number(best.change_seq)) best = row;
  }
  return formatCursor(best.updated_at, best.change_seq);
}

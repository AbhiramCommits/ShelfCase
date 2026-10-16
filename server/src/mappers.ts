/**
 * Row -> wire mappers. The API speaks camelCase; PostgreSQL speaks snake_case.
 * `syncState` is a client-side concern, so the server always reports `synced`.
 */

export interface ItemRow {
  id: string;
  owner_user_id: string;
  title: string;
  set_name: string;
  category: string;
  condition_grade: string;
  purchase_price_cents: number;
  estimated_value_cents: number;
  acquired_at: Date | string;
  notes: string;
  image_local_path: string | null;
  created_at: Date | string;
  updated_at: Date | string;
  version: number;
  is_deleted: boolean;
  change_seq: string | number;
}

export interface ItemDto {
  id: string;
  ownerUserId: string;
  userId: string;
  title: string;
  setName: string;
  category: string;
  conditionGrade: string;
  purchasePriceCents: number;
  estimatedValueCents: number;
  acquiredAt: string;
  notes: string;
  imageLocalPath: string | null;
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
  syncState: "synced";
}

const iso = (value: Date | string): string =>
  value instanceof Date ? value.toISOString() : new Date(value).toISOString();

export function toItemDto(row: ItemRow): ItemDto {
  return {
    id: row.id,
    ownerUserId: row.owner_user_id,
    userId: row.owner_user_id,
    title: row.title,
    setName: row.set_name,
    category: row.category,
    conditionGrade: row.condition_grade,
    purchasePriceCents: row.purchase_price_cents,
    estimatedValueCents: row.estimated_value_cents,
    acquiredAt: iso(row.acquired_at),
    notes: row.notes,
    imageLocalPath: row.image_local_path,
    createdAt: iso(row.created_at),
    updatedAt: iso(row.updated_at),
    version: row.version,
    isDeleted: row.is_deleted,
    syncState: "synced",
  };
}

export interface ObservationRow {
  id: string;
  item_id: string;
  source_label: string;
  value_cents: number;
  observed_at: Date | string;
  change_seq: string | number;
}

export interface ObservationDto {
  id: string;
  itemId: string;
  sourceLabel: string;
  valueCents: number;
  observedAt: string;
  changeSeq?: number;
}

export function toObservationDto(row: ObservationRow): ObservationDto {
  return {
    id: row.id,
    itemId: row.item_id,
    sourceLabel: row.source_label,
    valueCents: row.value_cents,
    observedAt: iso(row.observed_at),
    changeSeq: Number(row.change_seq),
  };
}

export interface TradeRow {
  id: string;
  proposer_user_id: string;
  receiver_user_id: string;
  status: string;
  created_at: Date | string;
  updated_at: Date | string;
  version: number;
  change_seq: string | number;
  offered_item_ids?: string[] | null;
  requested_item_ids?: string[] | null;
}

export interface TradeDto {
  id: string;
  proposerUserId: string;
  receiverUserId: string;
  offeredItemIds: string[];
  requestedItemIds: string[];
  status: string;
  createdAt: string;
  updatedAt: string;
  version: number;
}

export function toTradeDto(row: TradeRow): TradeDto {
  return {
    id: row.id,
    proposerUserId: row.proposer_user_id,
    receiverUserId: row.receiver_user_id,
    offeredItemIds: row.offered_item_ids ?? [],
    requestedItemIds: row.requested_item_ids ?? [],
    status: row.status,
    createdAt: iso(row.created_at),
    updatedAt: iso(row.updated_at),
    version: row.version,
  };
}

export interface WishlistRow {
  id: string;
  user_id: string;
  title_query: string;
  max_price_cents: number;
  created_at: Date | string;
  change_seq: string | number;
}

export interface WishlistDto {
  id: string;
  userId: string;
  titleQuery: string;
  maxPriceCents: number;
  createdAt: string;
}

export function toWishlistDto(row: WishlistRow): WishlistDto {
  return {
    id: row.id,
    userId: row.user_id,
    titleQuery: row.title_query,
    maxPriceCents: row.max_price_cents,
    createdAt: iso(row.created_at),
  };
}

import { z } from "zod";

export const CATEGORIES = ["card", "figure", "vinyl", "other"] as const;
export const GRADES = ["mint", "nearMint", "excellent", "good", "poor"] as const;
export const TRADE_STATUSES = ["proposed", "accepted", "declined", "cancelled"] as const;
export const SYNC_ENTITY_TYPES = ["item", "wishlist", "trade", "observation"] as const;

export const categorySchema = z.enum(CATEGORIES);
export const gradeSchema = z.enum(GRADES);
export const tradeStatusSchema = z.enum(TRADE_STATUSES);
export const isoDate = z.string().datetime({ offset: true });

export const itemCreateSchema = z.object({
  /** Client-generated so an offline create keeps its identity across retries. */
  id: z.string().uuid().optional(),
  title: z.string().trim().min(1).max(300),
  setName: z.string().max(300).default(""),
  category: categorySchema.default("other"),
  conditionGrade: gradeSchema.default("nearMint"),
  purchasePriceCents: z.number().int().min(0).default(0),
  estimatedValueCents: z.number().int().default(0),
  acquiredAt: isoDate.optional(),
  notes: z.string().max(4000).default(""),
  imageLocalPath: z.string().max(1000).nullable().optional(),
});

export const itemPatchSchema = z
  .object({
    title: z.string().trim().min(1).max(300).optional(),
    setName: z.string().max(300).optional(),
    category: categorySchema.optional(),
    conditionGrade: gradeSchema.optional(),
    purchasePriceCents: z.number().int().min(0).optional(),
    estimatedValueCents: z.number().int().optional(),
    acquiredAt: isoDate.optional(),
    notes: z.string().max(4000).optional(),
    imageLocalPath: z.string().max(1000).nullable().optional(),
    /** Optimistic-concurrency guard. Omit only for last-writer-wins. */
    version: z.number().int().min(1).optional(),
  })
  .strict();

export const observationCreateSchema = z.object({
  id: z.string().uuid().optional(),
  sourceLabel: z.string().trim().min(1).max(120),
  valueCents: z.number().int(),
  observedAt: isoDate.optional(),
});

export const itemsQuerySchema = z.object({
  since: z.string().max(160).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100),
  includeDeleted: z
    .enum(["true", "false"])
    .optional()
    .transform((value) => value === "true"),
  category: categorySchema.optional(),
  grade: gradeSchema.optional(),
  search: z.string().max(200).optional(),
});

export const wishlistCreateSchema = z.object({
  id: z.string().uuid().optional(),
  titleQuery: z.string().trim().min(1).max(200),
  maxPriceCents: z.number().int().min(0),
});

export const wishlistPatchSchema = z
  .object({
    titleQuery: z.string().trim().min(1).max(200).optional(),
    maxPriceCents: z.number().int().min(0).optional(),
  })
  .strict();

export const tradeCreateSchema = z.object({
  id: z.string().uuid().optional(),
  receiverUserId: z.string().uuid(),
  offeredItemIds: z.array(z.string().uuid()).min(1).max(50),
  requestedItemIds: z.array(z.string().uuid()).min(1).max(50),
});

export const tradesQuerySchema = z.object({
  role: z.enum(["incoming", "outgoing", "all"]).default("all"),
  status: tradeStatusSchema.optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});

export const syncPushSchema = z.object({
  changes: z
    .array(
      z.object({
        entityType: z.enum(SYNC_ENTITY_TYPES),
        op: z.enum(["create", "update", "delete"]),
        id: z.string().uuid(),
        baseVersion: z.number().int().min(1).optional(),
        clientUpdatedAt: isoDate.optional(),
        payload: z.record(z.unknown()).default({}),
      }),
    )
    .max(1000),
});

export const syncPullQuerySchema = z.object({
  since: z.string().max(160).optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(200),
});

export type ItemCreateInput = z.infer<typeof itemCreateSchema>;
export type ItemPatchInput = z.infer<typeof itemPatchSchema>;
export type SyncPushInput = z.infer<typeof syncPushSchema>;

-- ShelfCase schema. Idempotent: safe to run on every boot.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- One global, monotonic change sequence. Every mutable row carries a
-- `change_seq` drawn from it, which gives delta sync a total order that
-- `updated_at` alone cannot (millisecond ties silently drop rows).
CREATE SEQUENCE IF NOT EXISTS change_seq AS bigint START WITH 1 INCREMENT BY 1;

-- ---------------------------------------------------------------- users ---
CREATE TABLE IF NOT EXISTS users (
    id           uuid PRIMARY KEY,
    display_name text        NOT NULL,
    email        text        NOT NULL UNIQUE,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- items ---
CREATE TABLE IF NOT EXISTS items (
    id                    uuid PRIMARY KEY,
    owner_user_id         uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    title                 text        NOT NULL,
    set_name              text        NOT NULL DEFAULT '',
    category              text        NOT NULL DEFAULT 'other'
        CHECK (category IN ('card', 'figure', 'vinyl', 'other')),
    condition_grade       text        NOT NULL DEFAULT 'nearMint'
        CHECK (condition_grade IN ('mint', 'nearMint', 'excellent', 'good', 'poor')),
    purchase_price_cents  integer     NOT NULL DEFAULT 0 CHECK (purchase_price_cents >= 0),
    estimated_value_cents integer     NOT NULL DEFAULT 0,
    acquired_at           timestamptz NOT NULL DEFAULT now(),
    notes                 text        NOT NULL DEFAULT '',
    image_local_path      text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    version               integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
    is_deleted            boolean     NOT NULL DEFAULT false,
    change_seq            bigint      NOT NULL DEFAULT nextval('change_seq')
);

CREATE INDEX IF NOT EXISTS items_change_seq_idx ON items (change_seq);
CREATE INDEX IF NOT EXISTS items_owner_idx ON items (owner_user_id);
CREATE INDEX IF NOT EXISTS items_updated_at_idx ON items (updated_at);

-- ---------------------------------------------------- price_observations ---
CREATE TABLE IF NOT EXISTS price_observations (
    id           uuid PRIMARY KEY,
    item_id      uuid        NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    source_label text        NOT NULL,
    value_cents  integer     NOT NULL,
    observed_at  timestamptz NOT NULL DEFAULT now(),
    change_seq   bigint      NOT NULL DEFAULT nextval('change_seq')
);

CREATE INDEX IF NOT EXISTS price_observations_item_idx ON price_observations (item_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS price_observations_change_seq_idx ON price_observations (change_seq);

-- --------------------------------------------------------------- trades ---
CREATE TABLE IF NOT EXISTS trades (
    id                uuid PRIMARY KEY,
    proposer_user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    receiver_user_id  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status            text        NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed', 'accepted', 'declined', 'cancelled')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    version           integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
    change_seq        bigint      NOT NULL DEFAULT nextval('change_seq')
);

CREATE INDEX IF NOT EXISTS trades_change_seq_idx ON trades (change_seq);
CREATE INDEX IF NOT EXISTS trades_receiver_idx ON trades (receiver_user_id, status);
CREATE INDEX IF NOT EXISTS trades_proposer_idx ON trades (proposer_user_id, status);

-- ----------------------------------------------------------- trade_items ---
CREATE TABLE IF NOT EXISTS trade_items (
    trade_id uuid NOT NULL REFERENCES trades (id) ON DELETE CASCADE,
    item_id  uuid NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    side     text NOT NULL CHECK (side IN ('offered', 'requested')),
    PRIMARY KEY (trade_id, item_id, side)
);

CREATE INDEX IF NOT EXISTS trade_items_item_idx ON trade_items (item_id);

-- ------------------------------------------------------ wishlist_entries ---
CREATE TABLE IF NOT EXISTS wishlist_entries (
    id              uuid PRIMARY KEY,
    user_id         uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    title_query     text        NOT NULL,
    max_price_cents integer     NOT NULL DEFAULT 0 CHECK (max_price_cents >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    change_seq      bigint      NOT NULL DEFAULT nextval('change_seq')
);

CREATE INDEX IF NOT EXISTS wishlist_entries_user_idx ON wishlist_entries (user_id);
CREATE INDEX IF NOT EXISTS wishlist_entries_change_seq_idx ON wishlist_entries (change_seq);

-- ---------------------------------------------------------- request_log ---
-- Response replay for the Idempotency-Key contract. `status_code` and
-- `completed` are additions to the brief's column list; without them a
-- concurrent retry cannot tell an in-flight claim from a finished response.
CREATE TABLE IF NOT EXISTS request_log (
    idempotency_key text        PRIMARY KEY,
    user_id         uuid,
    response_body   jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    status_code     integer,
    completed       boolean     NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS request_log_created_idx ON request_log (created_at);

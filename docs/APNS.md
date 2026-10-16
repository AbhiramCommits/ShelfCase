# APNs payload shape

The iOS client registers with `UNUserNotificationCenter` and expects the backend
to send **alert** pushes with a `kind` discriminator in the custom payload. The
client never trusts payload contents for state; it treats a push as a hint to run
`SyncEngine.sync()` and, for the two user-visible kinds, to raise a local
notification (see `Notifications/PushRegistrar.swift`).

## Common envelope

```json
{
  "aps": {
    "alert": { "title": "Wishlist match", "body": "“Charizard Base Set” matches your search at $95.00." },
    "sound": "default",
    "badge": 3,
    "thread-id": "wishlist",
    "mutable-content": 1
  },
  "kind": "wishlistMatch",
  "schemaVersion": 1
}
```

`kind` is one of `wishlistMatch`, `tradeProposal`, `tradeAccepted`,
`tradeDeclined`, `priceAlert`, `syncNudge`.

## Kinds

### `wishlistMatch`

Sent when `POST /items` returns a non-empty `wishlistMatches` array for a user
other than the uploader.

```json
{
  "aps": { "alert": { "title": "Wishlist match", "body": "…" }, "sound": "default", "thread-id": "wishlist" },
  "kind": "wishlistMatch",
  "schemaVersion": 1,
  "itemId": "9f1c…",
  "matchedQuery": "charizard",
  "maxPriceCents": 10000,
  "estimatedValueCents": 9500,
  "title": "Charizard Base Set Holo"
}
```

### `tradeProposal`

Sent on `POST /trades` to `receiver_user_id`.

```json
{
  "aps": { "alert": { "title": "New trade proposal", "body": "Bob wants to swap 2 item(s) with you." }, "thread-id": "trades" },
  "kind": "tradeProposal",
  "schemaVersion": 1,
  "tradeId": "0ab3…",
  "proposerUserId": "11111111-1111-4111-8111-111111111111",
  "offeredItemIds": ["…", "…"],
  "requestedItemIds": ["…"]
}
```

### `tradeAccepted` / `tradeDeclined`

Sent to the proposer when the receiver acts. Accepting swaps ownership inside one
transaction server-side, so the client only needs to pull the delta.

```json
{
  "aps": { "alert": { "title": "Trade accepted", "body": "Your swap went through." }, "thread-id": "trades" },
  "kind": "tradeAccepted",
  "schemaVersion": 1,
  "tradeId": "0ab3…",
  "itemsSwapped": 2
}
```

### `priceAlert`

Sent when a `price_observations` row moves an item outside a user's threshold.

```json
{
  "aps": { "alert": { "title": "Price move", "body": "Black Lotus is up 12% this week." }, "thread-id": "prices" },
  "kind": "priceAlert",
  "schemaVersion": 1,
  "itemId": "…",
  "previousValueCents": 400000,
  "valueCents": 448000
}
```

### `syncNudge`

A silent push used to wake a client that has been offline for a while. Deliberately
**content-available only** so it never shows a banner.

```json
{
  "aps": { "content-available": 1 },
  "kind": "syncNudge",
  "schemaVersion": 1
}
```

## Client handling contract

| Step | Behaviour |
|------|-----------|
| Token | `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` → `PushRegistrar.shared.store(deviceToken:)` |
| Foreground | `userNotificationCenter(_:willPresent:)` returns `[.banner, .sound, .list]` |
| Tap | `userNotificationCenter(_:didReceive:)` records a `push.opened` telemetry event |
| Unknown `kind` or `schemaVersion > 1` | Ignored, except that a `syncNudge`-style silent push still triggers `sync()` |
| All kinds | The push is a hint only. Fresh state always comes from `GET /sync/pull`; the payload is never written into SwiftData directly. |

## What still requires credentials

Producing a real device token and sending these payloads requires an Apple
Developer account: an APNs auth key (`.p8`), the team id, and the key id. Locally
the client only exercises the *local* notification paths, which is why the app
also raises a local notification at the moment `POST /items` returns
`wishlistMatches` — that path works with no push entitlement at all.

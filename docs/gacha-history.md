# Portable gacha history

`haneoka-gacha-history-v1` is the shared TypeScript and Dart history contract. It carries server-returned facts and supports JSON export, file import, local accumulation and selected-record export.

| Capability                | TypeScript                                  | Dart                                            |
| ------------------------- | ------------------------------------------- | ----------------------------------------------- |
| Public import             | `@haneoka/game-data-exporter/gacha-history` | `package:game_data_exporter/gacha_history.dart` |
| Parse and project JSON    | `parseHistory(value)`                       | `HistorySnapshot.fromJson(value)`               |
| Merge collected snapshots | `mergeHistory(newer, older)`                | `newer.withOlder(older)`                        |
| Export selected batches   | Host selects `batches`                      | `snapshot.selected(indexes)`                    |
| Serialize                 | `JSON.stringify(snapshot)`                  | `jsonEncode(snapshot.toJson())`                 |

Both JSON readers explicitly project the fields below. The portable output contains no player ID, credential, device ID, save document or catalog asset URL. Catalog lookup, localization, card images, account association and persistence belong to the host.

```json
{
  "schema": "haneoka-gacha-history-v1",
  "source": { "server": "global-hmt", "clientVersion": "1.0.6" },
  "queriedAt": "2026-10-19T00:00:00.000Z",
  "historyKind": "execution",
  "legacyOmittedCount": 0,
  "coverage": {
    "scope": "server-returned",
    "retentionDays": null,
    "orderWithinBatch": null
  },
  "batches": []
}
```

Each batch has nullable `poolId`, `productId`, `executedAt`, `freeGems`, `paidGems` and `tickets`, plus a nonempty `prizes` array. A prize has a decimal-string `prizeId` and boolean `converted`. IDs are positive signed-64-bit decimal strings. JSON numeric IDs support Otonote safe-integer compatibility through 9,007,199,254,740,991; use decimal strings for the full signed-64-bit range. Amounts are nonnegative integers through 2,147,483,647; `executedAt` is Unix seconds through 253,402,271,999. Missing values stay `null`.

`source.server` is `jp`, `global-hmt`, `global-en` or `global-kr`. Coverage scope is `server-returned`, `local-collected` or `selected-records`. `historyKind` is `execution`, `legacy` or `empty` for native server reads. JSON imports retain their history-kind label. The readers also accept the existing `otonote-gacha-history` format at schema version 1, project its `source.serverId` and coverage aliases, and return the shared contract.

Imports accept at most 100,000 batches and 250,000 prizes. File readers enforce the exported 16 MiB byte limit (`HISTORY_BYTES` / `historyResponseLimit`) before parsing JSON. The native protobuf decoder applies the same byte, batch and prize limits.

Merge snapshots after the host has established that they belong to one account. A batch identity includes its pool, product, timestamp, costs and sorted prize multiset. Merging preserves the greatest multiplicity seen for each identical batch, so repeated identical draws survive without double-counting overlap. Newer empty responses retain older collected records. Different history kinds remain separate. TypeScript rejects different servers; Dart returns the newer snapshot unchanged for that case.

The current server response supplies execution batches and an older per-prize history. When execution batches exist, native decoding exports them and records the omitted older count. When only the older list exists, each entry becomes a batch with unavailable pool, product and costs set to `null`. Empty responses produce an empty snapshot. Retention duration and order within a batch remain unspecified.

## Native CLI and session lifecycle

```sh
dart run game_data_exporter:gacha_history --server global-hmt --output history.json /path/to/persist-save
```

The Dart CLI decodes one encrypted or decrypted persist document with `SaveCodec`, constructs `SavedGameSession` from `_certification`, discovers the public recommended client version and invokes `GameHistoryClient.read`. The same reader is reusable in native hosts. The selected server controls the fixed TLS endpoint; the CLI accepts no manual credentials or endpoint override.

JP public version discovery calls `app.announcement.AnnouncementService/GetList` with `x-platform` set to `iOS` on iOS and `Android` on other native platforms. Global discovery calls `app.masterdata.MasterdataService/Version`. Authenticated history uses `app.gacha.GachaService/History`. Recommended versions are cached per region and rediscovered once after a client-update response. Native Dart transport and live session acceptance require real-server validation for the selected region.

The output writes only `HistorySnapshot.toJson()`. Errors expose short codes. The CLI clears input byte buffers after decoding, and the encrypted-save decoder clears its decrypted byte buffer. Session strings remain in process memory until the process exits.

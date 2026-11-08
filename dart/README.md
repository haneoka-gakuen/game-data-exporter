# Dart game-data exporter

## Gacha history

From this directory:

```sh
dart pub get
dart run game_data_exporter:gacha_history --server jp --output history.json /path/to/persist-save
```

`--server` accepts `jp`, `global-hmt`, `global-en` and `global-kr`. The input is one `LocalPersistData` file, encrypted or decrypted, up to 16 MiB. The output is a history snapshot without credentials. Errors print a short code and exit nonzero.

```dart
import 'dart:convert';
import 'dart:io';
import 'package:game_data_exporter/gacha_history.dart';

final document = SaveCodec.decode(await File(persistPath).readAsBytes());
final session = SavedGameSession.fromPersist(document);
if (session == null) throw const FormatException('history_session_missing');
final history = await GameHistoryClient().read(session, GameHistoryRegion.jp);
await File(outputPath).writeAsString(jsonEncode(history.toJson()));
```

`SavedGameSession.fromCertification` accepts an already decoded `_certification` map. Session fields are private and never serialised. `SaveCodec` (`package:game_data_exporter/save_codec.dart`) decodes local saves on its own.

`HistorySnapshot.fromJson`, `withOlder` and `selected` implement the [shared history contract](../docs/gacha-history.md). `GameHistoryClient.readPlayerData` reads the account's card, character and band item progress in the same `_player` shape as a local save.

Pass `GameHistoryClient(proxyFor: ...)` to route game requests through the host's HTTP proxy.

## Inventory projection

`projectThirdPartyInventory` reads a decoded OtoNote or MoeNotes JSON map into the
same `InventoryCandidate` the TypeScript exporter produces, or returns `null` for
another format. Errors carry the exporter's codes in `InventoryImportError.code`.

The inventory projection accepts decoded JSON. File selection, archive decoding,
release-specific range checks, preview, confirmation and persistence belong to
the importing application. Imported account growth includes character ranks,
individual active instrument levels and TGW CARD rank. Notices preserve unknown,
conflicting, review-pending and unsupported facts without inventing values. A
MoeNotes box linked to a separate save raises `box_linked_save_required`.

The TypeScript and Dart projections share the public candidate contract and
producer semantics.

# Dart game-data exporter

## Gacha history

From this directory:

```sh
dart pub get
dart run game_data_exporter:gacha_history --server jp --output history.json /path/to/persist-save
```

`--server` accepts `jp`, `global-hmt`, `global-en` and `global-kr`. The input is one original encrypted `LocalPersistData` file or its decrypted JSON document, bounded to 16 MiB. The command reads `_certification` directly, so an accompanying player-profile file is optional. It uses the same `GameHistoryClient` as native applications and writes a credential-free history snapshot. `--help` describes the command. Errors print a short code and return a nonzero exit status.

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

`SavedGameSession.fromCertification` also accepts an already-decoded `_certification` map. Session fields are private and have no JSON serializer. `SaveCodec` is separately available from `package:game_data_exporter/save_codec.dart` for local-save import. File selection and account association belong to the host application.

`HistorySnapshot.fromJson`, `withOlder` and `selected` implement the [shared history contract](../docs/gacha-history.md). `decodeHistoryResponse` projects the bounded protobuf response into that contract. The native reader uses TLS gRPC, public recommended-version discovery, and an authenticated history request. JP discovery uses `app.announcement.AnnouncementService/GetList` with `x-platform`; Global uses `app.masterdata.MasterdataService/Version`.

## Inventory projection

`projectThirdPartyInventory` projects Otonote personal growth/inventory JSON and
MoeNotes card-box JSON into the same current-fact candidate used by the TypeScript
exporter. It accepts a decoded JSON map and returns an `InventoryCandidate`, or
`null` for another format. `InventoryImportError.code` uses the exporter's error
codes. `toJson()` emits the candidate DTO; the receiving application assigns its
own candidate ID.

The inventory projection accepts decoded JSON. File selection, archive decoding,
release-specific range checks, preview, confirmation and persistence belong to
the importing application. Imported account growth includes character ranks,
individual active instrument levels and TGW CARD rank. Notices preserve unknown,
conflicting, review-pending and unsupported facts without inventing values. A
MoeNotes box linked to a separate save raises `box_linked_save_required`.

The TypeScript and Dart projections share the public candidate contract and
producer semantics.

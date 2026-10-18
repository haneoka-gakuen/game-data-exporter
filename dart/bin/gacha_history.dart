import 'dart:convert';
import 'dart:io';

import 'package:game_data_exporter/gacha_history.dart';

const _usage =
    '''Export server-returned gacha history from a local persist save.

Usage:
  dart run game_data_exporter:gacha_history --server SERVER --output history.json PERSIST_SAVE

Servers: jp, global-hmt, global-en, global-kr
PERSIST_SAVE: one original encrypted LocalPersistData file or decrypted JSON.
''';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 &&
      (arguments.single == '--help' || arguments.single == '-h')) {
    stdout.write(_usage);
    return;
  }

  String? server, output, input;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--server' || argument == '--output') {
      if (++index == arguments.length) return _fail('history_usage', 64);
      final value = arguments[index];
      if (value.isEmpty || value.startsWith('--')) {
        return _fail('history_usage', 64);
      }
      if (argument == '--server' && server == null) {
        server = value;
      } else if (argument == '--output' && output == null) {
        output = value;
      } else {
        return _fail('history_usage', 64);
      }
    } else if (argument.startsWith('-') || input != null) {
      return _fail('history_usage', 64);
    } else {
      input = argument;
    }
  }
  final regions = GameHistoryRegion.values.where(
    (region) => region.id == server,
  );
  if (regions.isEmpty || output == null || input == null) {
    return _fail('history_usage', 64);
  }

  final source = File(input), destination = File(output);
  SavedGameSession? session;
  try {
    if (source.absolute.uri.normalizePath() ==
            destination.absolute.uri.normalizePath() ||
        (await destination.exists() &&
            await FileSystemEntity.identical(source.path, destination.path))) {
      return _fail('history_output_matches_input', 64);
    }
    if (await source.length() > SaveCodec.maxFileBytes) {
      return _fail('history_save_too_large', 65);
    }
    final bytes = await source.readAsBytes();
    try {
      session = SavedGameSession.fromPersist(SaveCodec.decode(bytes));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  } on FileSystemException {
    return _fail('history_input_unreadable', 66);
  } catch (_) {
    return _fail('history_save_invalid', 65);
  }
  if (session == null) return _fail('history_session_missing', 65);

  final HistorySnapshot snapshot;
  try {
    snapshot = await GameHistoryClient().read(session, regions.single);
  } on GameHistoryException catch (error) {
    return _fail(error.code, 69);
  } catch (_) {
    return _fail('history_network_error', 69);
  }
  try {
    await destination.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(snapshot.toJson())}\n',
      flush: true,
    );
  } on FileSystemException {
    return _fail('history_output_unwritable', 73);
  }
  stdout.writeln('Exported ${snapshot.executions.length} batches.');
}

void _fail(String code, int status) {
  stderr.writeln(code);
  exitCode = status;
}

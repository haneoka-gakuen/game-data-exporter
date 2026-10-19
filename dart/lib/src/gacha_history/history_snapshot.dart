import 'dart:convert';
import 'dart:typed_data';

import 'package:protobuf/protobuf.dart';

import '../../gacha_history_points.dart';

const historySnapshotSchema = 'haneoka-gacha-history-v1';
const historyResponseLimit = 16 * 1024 * 1024;

int historyOffsetMinutes(String server) => switch (server) {
  'jp' || 'global-kr' => 540,
  'global-hmt' => 480,
  'global-en' => 0,
  _ => throw const FormatException('history_server'),
};

class HistoryPrize {
  const HistoryPrize(this.prizeId, this.converted);
  final String prizeId;
  final bool converted;
  Map<String, Object?> toJson() => {'prizeId': prizeId, 'converted': converted};
}

class HistoryExecution {
  const HistoryExecution({
    required this.poolId,
    required this.productId,
    required this.executedAt,
    required this.prizes,
    this.freeGems,
    this.paidGems,
    this.tickets,
  });
  final String? poolId, productId;
  final int? executedAt, freeGems, paidGems, tickets;
  final List<HistoryPrize> prizes;
  Map<String, Object?> toJson() => {
    'poolId': poolId,
    'productId': productId,
    'executedAt': executedAt,
    'freeGems': freeGems,
    'paidGems': paidGems,
    'tickets': tickets,
    'prizes': prizes.map((value) => value.toJson()).toList(),
  };
}

class HistorySnapshot {
  const HistorySnapshot({
    required this.server,
    required this.clientVersion,
    required this.queriedAt,
    required this.historyKind,
    required this.executions,
    this.legacyOmittedCount = 0,
    this.scope = 'server-returned',
    this.accountKey,
    this.accountState,
  });
  final String server, clientVersion, historyKind;
  final DateTime queriedAt;
  final List<HistoryExecution> executions;
  final int legacyOmittedCount;
  final String scope;
  final String? accountKey;
  final HistoryAccountState? accountState;

  HistorySnapshot withAccountState(HistoryAccountState? state) =>
      HistorySnapshot(
        server: server,
        clientVersion: clientVersion,
        queriedAt: queriedAt,
        historyKind: historyKind,
        executions: executions,
        legacyOmittedCount: legacyOmittedCount,
        scope: scope,
        accountKey: accountKey,
        accountState: state == null
            ? null
            : parseHistoryAccountState(state, expectedServer: server),
      );

  HistorySnapshot forAccount(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
        (accountKey != null && accountKey != key)) {
      throw const FormatException('history_account');
    }
    return HistorySnapshot(
      server: server,
      clientVersion: clientVersion,
      queriedAt: queriedAt,
      historyKind: historyKind,
      executions: executions,
      legacyOmittedCount: legacyOmittedCount,
      scope: scope,
      accountKey: key,
      accountState: accountState,
    );
  }

  HistorySnapshot withOlder(HistorySnapshot older) {
    if (older.server != server) return this;
    if (accountKey != null &&
        older.accountKey != null &&
        accountKey != older.accountKey) {
      throw const FormatException('history_account');
    }
    final state = _latestAccountState(accountState, older.accountState);
    if (executions.isEmpty && older.executions.isNotEmpty) {
      return HistorySnapshot(
        server: server,
        clientVersion: clientVersion,
        queriedAt: queriedAt,
        historyKind: older.historyKind,
        executions: older.executions,
        legacyOmittedCount: older.legacyOmittedCount,
        scope: 'local-collected',
        accountKey: accountKey ?? older.accountKey,
        accountState: state,
      );
    }
    if (older.historyKind != historyKind) return withAccountState(state);
    String identity(HistoryExecution row) {
      final prizes =
          row.prizes
              .map((prize) => '${prize.prizeId}:${prize.converted}')
              .toList()
            ..sort();
      return jsonEncode([
        row.poolId,
        row.productId,
        row.executedAt,
        row.freeGems,
        row.paidGems,
        row.tickets,
        prizes,
      ]);
    }

    final remaining = <String, int>{};
    for (final row in executions) {
      remaining.update(identity(row), (count) => count + 1, ifAbsent: () => 1);
    }
    final combined = [...executions];
    for (final row in older.executions) {
      final key = identity(row), count = remaining[key] ?? 0;
      if (count > 0) {
        remaining[key] = count - 1;
      } else {
        combined.add(row);
      }
    }
    return HistorySnapshot(
      server: server,
      clientVersion: clientVersion,
      queriedAt: queriedAt,
      historyKind: historyKind,
      executions: List.unmodifiable(combined),
      legacyOmittedCount: legacyOmittedCount,
      scope: combined.length > executions.length ? 'local-collected' : scope,
      accountKey: accountKey ?? older.accountKey,
      accountState: state,
    );
  }

  HistorySnapshot selected(Set<int> indexes) => HistorySnapshot(
    server: server,
    clientVersion: clientVersion,
    queriedAt: queriedAt,
    historyKind: historyKind,
    executions: [
      for (final (index, row) in executions.indexed)
        if (indexes.contains(index)) row,
    ],
    legacyOmittedCount: legacyOmittedCount,
    scope: 'selected-records',
    accountKey: accountKey,
    accountState: accountState,
  );

  Map<String, Object?> toJson() => {
    'schema': historySnapshotSchema,
    'source': {
      'server': server,
      'clientVersion': clientVersion,
      if (accountKey != null) 'accountKey': accountKey,
    },
    'queriedAt': queriedAt.toUtc().toIso8601String(),
    'historyKind': historyKind,
    'legacyOmittedCount': legacyOmittedCount,
    if (accountState != null)
      'accountState': parseHistoryAccountState(
        accountState,
        expectedServer: server,
      ),
    'coverage': {
      'scope': scope,
      'retentionDays': null,
      'orderWithinBatch': null,
    },
    'batches': executions.map((value) => value.toJson()).toList(),
  };

  static HistorySnapshot fromJson(Object? value) {
    if (value is! Map) throw const FormatException('history_snapshot');
    final compatible =
        value['format'] == 'otonote-gacha-history' &&
        value['schemaVersion'] == 1;
    if (value['schema'] != historySnapshotSchema && !compatible) {
      throw const FormatException('history_snapshot');
    }
    final source = value['source'];
    final rows = value['batches'];
    if (source is! Map || rows is! List || rows.length > 100000) {
      throw const FormatException('history_snapshot');
    }
    final server = '${source['server'] ?? source['serverId'] ?? ''}';
    if (!const {
      'jp',
      'global-hmt',
      'global-en',
      'global-kr',
    }.contains(server)) {
      throw const FormatException('history_server');
    }
    final date = DateTime.tryParse('${value['queriedAt'] ?? ''}');
    if (date == null) throw const FormatException('history_date');
    final accountKey = source['accountKey'];
    if (accountKey != null &&
        (accountKey is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(accountKey))) {
      throw const FormatException('history_account');
    }
    var count = 0;
    final executions = <HistoryExecution>[];
    for (final row in rows) {
      if (row is! Map || row['prizes'] is! List) {
        throw const FormatException('history_batch');
      }
      final prizes = <HistoryPrize>[];
      for (final prize in row['prizes'] as List) {
        if (prize is! Map || prize['converted'] is! bool || ++count > 250000) {
          throw const FormatException('history_prize');
        }
        prizes.add(
          HistoryPrize(
            _identifier(prize['prizeId'])!,
            prize['converted'] as bool,
          ),
        );
      }
      if (prizes.isEmpty) throw const FormatException('history_batch');
      executions.add(
        HistoryExecution(
          poolId: _identifier(row['poolId'], nullable: true),
          productId: _identifier(row['productId'], nullable: true),
          executedAt: _amount(row['executedAt'], maximum: 253402271999),
          freeGems: _amount(row['freeGems']),
          paidGems: _amount(row['paidGems']),
          tickets: _amount(row['tickets']),
          prizes: List.unmodifiable(prizes),
        ),
      );
    }
    final coverage = value['coverage'];
    return HistorySnapshot(
      server: server,
      clientVersion: '${source['clientVersion'] ?? ''}',
      queriedAt: date,
      accountKey: accountKey as String?,
      accountState: value['accountState'] == null
          ? null
          : parseHistoryAccountState(
              value['accountState'],
              expectedServer: server,
            ),
      historyKind:
          '${value['historyKind'] ?? (coverage is Map ? coverage['historyKind'] : null) ?? 'execution'}',
      legacyOmittedCount:
          _amount(
            value['legacyOmittedCount'] ??
                (coverage is Map ? coverage['legacyOmittedCount'] : null),
          ) ??
          0,
      executions: List.unmodifiable(executions),
      scope:
          coverage is Map &&
              const {
                'server-returned',
                'local-collected',
                'selected-records',
              }.contains(coverage['scope'])
          ? coverage['scope'] as String
          : 'server-returned',
    );
  }
}

List<HistorySnapshot> mergeHistoryCollection(
  Iterable<HistorySnapshot> stored,
  HistorySnapshot incoming,
) {
  for (final history in stored) {
    if (history.server != incoming.server ||
        (history.accountKey != null &&
            incoming.accountKey != null &&
            history.accountKey != incoming.accountKey)) {
      throw const FormatException('history_account');
    }
  }
  final state = stored.fold<HistoryAccountState?>(
    incoming.accountState,
    (state, history) => _latestAccountState(state, history.accountState),
  );
  if (incoming.executions.isEmpty &&
      stored.any((history) => history.executions.isNotEmpty)) {
    return List.unmodifiable(
      stored
          .map(
            (history) => incoming.queriedAt.isBefore(history.queriedAt)
                ? history
                : incoming.withOlder(history),
          )
          .map(
            (history) =>
                state == null ? history : history.withAccountState(state),
          ),
    );
  }
  final previous = stored
      .where((history) => history.historyKind == incoming.historyKind)
      .firstOrNull;
  final history = previous == null
      ? incoming
      : incoming.queriedAt.isBefore(previous.queriedAt)
      ? previous.withOlder(incoming)
      : incoming.withOlder(previous);
  final result =
      [
        ...stored.where(
          (row) =>
              row.historyKind != incoming.historyKind &&
              row.historyKind != 'empty',
        ),
        history,
      ]..sort(
        (a, b) => a.historyKind == 'execution'
            ? -1
            : b.historyKind == 'execution'
            ? 1
            : b.queriedAt.compareTo(a.queriedAt),
      );
  return List.unmodifiable(
    result.map(
      (history) => state == null ? history : history.withAccountState(state),
    ),
  );
}

HistoryAccountState? _latestAccountState(
  HistoryAccountState? a,
  HistoryAccountState? b,
) {
  if (a == null) return b;
  if (b == null) return a;
  return DateTime.parse(a['collectedAt'] as String).millisecondsSinceEpoch >=
          DateTime.parse(b['collectedAt'] as String).millisecondsSinceEpoch
      ? a
      : b;
}

String? _identifier(Object? value, {bool nullable = false}) {
  if (value is num) {
    if (!value.isFinite ||
        value != value.truncateToDouble() ||
        value > 9007199254740991) {
      throw const FormatException('history_id');
    }
    value = value.toInt();
  }
  return _decimal(value, nullable: nullable);
}

String? _decimal(Object? value, {bool nullable = false}) {
  if (value == null && nullable) return null;
  final text = '$value';
  final number = BigInt.tryParse(text);
  if (!RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(text) ||
      number == null ||
      number > BigInt.parse('9223372036854775807')) {
    throw const FormatException('history_id');
  }
  return text;
}

int? _amount(Object? value, {int maximum = 2147483647}) {
  if (value == null) return null;
  final number = value is int ? value : int.tryParse('$value');
  if (number == null || number < 0 || number > maximum) {
    throw const FormatException('history_amount');
  }
  return number;
}

Map<int, int> _scalars(Uint8List bytes, Set<int> fields) {
  final reader = CodedBufferReader(bytes, sizeLimit: historyResponseLimit);
  final values = <int, int>{};
  while (!reader.isAtEnd()) {
    final tag = reader.readTag(), field = tag >> 3;
    if (fields.contains(field)) {
      if (tag & 7 != 0 || values.containsKey(field)) {
        throw const FormatException('history_field');
      }
      final value = reader.readInt64().toInt();
      if (value < 0) throw const FormatException('history_field');
      values[field] = value;
    } else if (!reader.skipField(tag)) {
      throw const FormatException('history_field');
    }
  }
  return values;
}

HistoryPrize _prize(Uint8List bytes, {bool legacy = false}) {
  final values = _scalars(bytes, legacy ? {1, 2, 3} : {1, 2});
  final converted = values[legacy ? 3 : 2] ?? 0;
  if (converted > 1) throw const FormatException('history_prize');
  return HistoryPrize(_decimal(values[1])!, converted == 1);
}

HistorySnapshot decodeHistoryResponse(
  Uint8List bytes, {
  required String server,
  required String clientVersion,
}) {
  if (bytes.length > historyResponseLimit) {
    throw const FormatException('history_size');
  }
  final reader = CodedBufferReader(bytes, sizeLimit: historyResponseLimit);
  final legacy = <Uint8List>[], rawExecutions = <Uint8List>[];
  while (!reader.isAtEnd()) {
    final tag = reader.readTag();
    if (tag >> 3 == 1 || tag >> 3 == 2) {
      if (tag & 7 != 2) throw const FormatException('history_field');
      final target = tag >> 3 == 1 ? legacy : rawExecutions;
      target.add(reader.readBytesAsView());
      if (target.length > 100000) throw const FormatException('history_size');
    } else if (!reader.skipField(tag)) {
      throw const FormatException('history_field');
    }
  }
  if (bytes.isNotEmpty && legacy.isEmpty && rawExecutions.isEmpty) {
    throw const FormatException('history_response');
  }
  final executions = <HistoryExecution>[];
  var count = 0;
  for (final raw in rawExecutions) {
    final values = _scalars(raw, {1, 2, 3, 4, 5, 6});
    final inner = CodedBufferReader(raw, sizeLimit: historyResponseLimit);
    final prizes = <HistoryPrize>[];
    while (!inner.isAtEnd()) {
      final tag = inner.readTag();
      if (tag >> 3 == 7) {
        if (tag & 7 != 2 || ++count > 250000) {
          throw const FormatException('history_prize');
        }
        prizes.add(_prize(inner.readBytesAsView()));
      } else if (!inner.skipField(tag)) {
        throw const FormatException('history_field');
      }
    }
    if (prizes.isEmpty) throw const FormatException('history_batch');
    executions.add(
      HistoryExecution(
        poolId: _decimal(values[1]),
        productId: _decimal(values[2] == 0 ? null : values[2], nullable: true),
        executedAt: _amount(
          values[6] == 0 ? null : values[6],
          maximum: 253402271999,
        ),
        freeGems: _amount(values[3] ?? 0),
        paidGems: _amount(values[4] ?? 0),
        tickets: _amount(values[5] ?? 0),
        prizes: List.unmodifiable(prizes),
      ),
    );
  }
  if (rawExecutions.isEmpty) {
    for (final raw in legacy) {
      final values = _scalars(raw, {1, 2, 3});
      executions.add(
        HistoryExecution(
          poolId: null,
          productId: null,
          executedAt: _amount(
            values[2] == 0 ? null : values[2],
            maximum: 253402271999,
          ),
          prizes: [_prize(raw, legacy: true)],
        ),
      );
    }
  }
  return HistorySnapshot(
    server: server,
    clientVersion: clientVersion,
    queriedAt: DateTime.now().toUtc(),
    historyKind: rawExecutions.isNotEmpty
        ? 'execution'
        : legacy.isNotEmpty
        ? 'legacy'
        : 'empty',
    legacyOmittedCount: rawExecutions.isNotEmpty ? legacy.length : 0,
    executions: List.unmodifiable(executions),
  );
}

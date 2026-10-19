/// Current point balances and redemption counters, separate from draw history.
library;

import 'dart:convert';
import 'dart:math' as math;

const historyAccountStateSchema = 'haneoka-gacha-account-state-v1';
const historyAccountStateBytes = 4 * 1024 * 1024;
const _maxSafeInteger = 9007199254740991;
const _maxRows = 100000;
const _regions = ['jp', 'global-hmt', 'global-en', 'global-kr'];
typedef HistoryAccountState = Map<String, Object?>;
typedef GachaTargetProgress = Map<String, Object?>;

Never _invalid() =>
    throw const FormatException('history_account_state_invalid');
Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, {bool optional = false}) {
  if (optional && value == null) return [];
  return value is List && value.length <= _maxRows
      ? List<Object?>.from(value)
      : _invalid();
}

int? _integer(Object? value, {bool nullable = false}) {
  if (nullable && value == null) return null;
  final n = value is num
      ? value
      : value is String && RegExp(r'^\d+$').hasMatch(value)
      ? num.tryParse(value)
      : null;
  return n != null &&
          n.isFinite &&
          n >= 0 &&
          n <= _maxSafeInteger &&
          n == n.truncateToDouble()
      ? n.toInt()
      : _invalid();
}

String _identity(Object? value) {
  if (value is num &&
      (!value.isFinite ||
          value.abs() > _maxSafeInteger ||
          value != value.truncateToDouble())) {
    _invalid();
  }
  final result = value is num ? '${value.toInt()}' : '$value';
  return RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(result) &&
          BigInt.parse(result) <= BigInt.parse('9223372036854775807')
      ? result
      : _invalid();
}

int? _resetType(Object? value, {bool nullable = false}) {
  final n = _integer(value, nullable: nullable);
  return n == null || (n >= 1 && n <= 4) ? n : _invalid();
}

String _region(Object? value) =>
    _regions.contains(value) ? value as String : _invalid();

/// Validate calendar fields before parsing; JS and Dart normalize invalid dates.
String? _timeText(Object? value, {required bool instant}) {
  if (!instant && (value == null || value == '')) return null;
  if (value is! String) return _invalid();
  final match = RegExp(
    r'^(\d{4})([-/])(\d{2})\2(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?(Z|[+-]\d{2}:?\d{2})?$',
  ).firstMatch(value);
  if (match == null ||
      (instant && (match[2] != '-' || value[10] != 'T' || match[9] == null))) {
    return _invalid();
  }
  final year = int.parse(match[1]!),
      month = int.parse(match[3]!),
      day = int.parse(match[4]!),
      hour = int.parse(match[5]!),
      minute = int.parse(match[6]!),
      second = int.parse(match[7]!);
  final days = [
    31,
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];
  if (year < 1 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > days[month - 1] ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return _invalid();
  }
  final zone = match[9];
  if (zone != null && zone != 'Z') {
    final offset = zone.substring(1).replaceAll(':', '');
    if (int.parse(offset.substring(0, 2)) > 23 ||
        int.parse(offset.substring(2)) > 59) {
      return _invalid();
    }
  }
  if (instant && DateTime.tryParse(value) == null) return _invalid();
  return value;
}

void _onlyKeys(Map<String, Object?> row, List<String> allowed) {
  if (row.keys.any((key) => !allowed.contains(key))) _invalid();
}

List<Map<String, Object?>> _unique(
  List<Map<String, Object?>> rows,
  String key,
) {
  final seen = <Object?>{};
  for (final row in rows) {
    if (!seen.add(row[key])) _invalid();
  }
  return rows;
}

/// Reads only the named Player branches. Missing rows and amounts remain unknown.
HistoryAccountState projectHistoryAccountState(
  Object? player, {
  required String server,
  required String collectedAt,
}) {
  final root = _map(player);
  server = _region(server);
  collectedAt = _timeText(collectedAt, instant: true)!;
  final gachaPoints = _unique([
    for (final value in _list(root['_gachaRecords'], optional: true))
      (() {
        final row = _map(value);
        return <String, Object?>{
          'gachaId': _identity(row['_id']),
          'balance': _integer(row['_gachaPoint'], nullable: true),
        };
      })(),
  ], 'gachaId');
  final exchange = root['_exchange'] == null
      ? <String, Object?>{}
      : _map(root['_exchange']);
  final exchanges = _unique([
    for (final value in _list(exchange['_products'], optional: true))
      (() {
        final row = _map(value);
        final counter = row['_timeResettableCounter'] == null
            ? <String, Object?>{}
            : _map(row['_timeResettableCounter']);
        return <String, Object?>{
          'exchangeProductId': _identity(row['_productId']),
          'count': _integer(counter['_count'], nullable: true),
          'resetType': _resetType(counter['_resetType'], nullable: true),
          'counterUpdatedAt': _timeText(
            counter['_lastUpdateTimeStr'],
            instant: false,
          ),
        };
      })(),
  ], 'exchangeProductId');
  return {
    'schema': historyAccountStateSchema,
    'source': {'server': server},
    'collectedAt': collectedAt,
    'gachaPoints': gachaPoints,
    'exchanges': exchanges,
  };
}

/// Portable JSON boundary, bound to the caller's selected server when provided.
HistoryAccountState parseHistoryAccountState(
  Object? value, {
  String? expectedServer,
}) {
  if (value is String) {
    if (utf8.encode(value).length > historyAccountStateBytes) return _invalid();
    try {
      value = jsonDecode(value);
    } on FormatException {
      return _invalid();
    }
  }
  final root = _map(value), source = _map(_map(value)['source']);
  _onlyKeys(root, [
    'schema',
    'source',
    'collectedAt',
    'gachaPoints',
    'exchanges',
  ]);
  _onlyKeys(source, ['server']);
  if (root['schema'] != historyAccountStateSchema) return _invalid();
  final server = _region(source['server']);
  if (expectedServer != null && server != _region(expectedServer)) {
    throw const FormatException('history_account_state_server_mismatch');
  }
  final gachaPoints = _unique([
    for (final value in _list(root['gachaPoints']))
      (() {
        final row = _map(value);
        _onlyKeys(row, ['gachaId', 'balance']);
        if (!row.containsKey('balance')) return _invalid();
        return <String, Object?>{
          'gachaId': _identity(row['gachaId']),
          'balance': _integer(row['balance'], nullable: true),
        };
      })(),
  ], 'gachaId');
  final exchanges = _unique([
    for (final value in _list(root['exchanges']))
      (() {
        final row = _map(value);
        _onlyKeys(row, [
          'exchangeProductId',
          'count',
          'resetType',
          'counterUpdatedAt',
        ]);
        if (![
          'count',
          'resetType',
          'counterUpdatedAt',
        ].every(row.containsKey)) {
          return _invalid();
        }
        return <String, Object?>{
          'exchangeProductId': _identity(row['exchangeProductId']),
          'count': _integer(row['count'], nullable: true),
          'resetType': _resetType(row['resetType'], nullable: true),
          'counterUpdatedAt': _timeText(
            row['counterUpdatedAt'],
            instant: false,
          ),
        };
      })(),
  ], 'exchangeProductId');
  return {
    'schema': historyAccountStateSchema,
    'source': {'server': server},
    'collectedAt': _timeText(root['collectedAt'], instant: true),
    'gachaPoints': gachaPoints,
    'exchanges': exchanges,
  };
}

const _rewardFields = [
  'id',
  'kind',
  'resourceType',
  'resourceId',
  'count',
  'name',
  'secondary',
  'image',
  'href',
  'rarity',
  'cardType',
  'characterId',
  'characterIds',
  'characterDetails',
  'musicId',
  'musicTitle',
  'jacketThumbUrl',
  'jacketUrl',
  'bandId',
  'bandIds',
  'musicType',
  'musicCategories',
  'bandName',
  'artistName',
  'bandDetails',
];
Map<String, Object?> _rewardProjection(Object? value) {
  final row = _map(value);
  _integer(row['resourceType']);
  _identity(row['resourceId']);
  _integer(row['count']);
  return {
    for (final key in _rewardFields)
      if (row.containsKey(key)) key: jsonDecode(jsonEncode(row[key])),
  };
}

List<int?>? _dateProjection(Object? value) => value == null
    ? null
    : [for (final stamp in _list(value)) _integer(stamp, nullable: true)];
int? _safeProduct(int? a, int b) =>
    a == null || (b > 0 && a > _maxSafeInteger ~/ b) ? null : a * b;

/// Joins fixed-price targets by ResourceType 7 + gachaId. The supplied catalog
/// belongs to [server]. Dates retain normalized locale slots. Periodic counters
/// preserve their recorded scope; a verified reset calendar is required to
/// derive the current interval.
List<GachaTargetProgress> gachaTargetProgress(
  Map<String, Object?> pool,
  Map<String, Object?> exchanges,
  HistoryAccountState? state, {
  required String server,
  required String gachaProductId,
}) {
  server = _region(server);
  final snapshot = state == null
      ? null
      : parseHistoryAccountState(state, expectedServer: server);
  final gachaId = _identity(pool['id']), selectedId = _identity(gachaProductId);
  final selected = [
    for (final row in _list(pool['drawOptions']).map(_map))
      if (_identity(row['id']) == selectedId) row,
  ];
  if (selected.length != 1) {
    throw const FormatException('gacha_point_product_not_found');
  }
  final drawCount = _integer(selected.single['drawCount'])!,
      pointGain = _integer(selected.single['gachaPoint'])!;
  if (drawCount == 0) return _invalid();
  int? balance;
  final counters = <String, Map<String, Object?>>{};
  if (snapshot != null) {
    for (final row in _list(snapshot['gachaPoints']).map(_map)) {
      if (row['gachaId'] == gachaId) balance = row['balance'] as int?;
    }
    for (final row in _list(snapshot['exchanges']).map(_map)) {
      counters[row['exchangeProductId'] as String] = row;
    }
  }
  final result = <GachaTargetProgress>[], seen = <String>{};
  for (final entry in _map(exchanges['entries']).entries) {
    final exchange = _map(entry.value),
        currency = _map(_map(entry.value)['currency']);
    if (_integer(currency['resourceType']) != 7 ||
        _identity(currency['resourceId']) != gachaId) {
      continue;
    }
    final exchangeId = _identity(exchange['id'] ?? entry.key);
    for (final value in _list(exchange['products'])) {
      final target = _map(value),
          exchangeProductId = _identity(_map(value)['id']);
      if (!seen.add(exchangeProductId)) return _invalid();
      final reward = _rewardProjection(target['reward']),
          basePointCost = _integer(target['cost'])!,
          limitCount = _integer(target['limit'])!,
          targetReset = _resetType(target['resetType'], nullable: true),
          counter = counters[exchangeProductId];
      final supported =
          target['paymentSteps'] is List &&
          target['paymentStepResourceCounts'] is List &&
          (target['paymentSteps'] as List).isEmpty &&
          (target['paymentStepResourceCounts'] as List).isEmpty;
      final pointCost = supported ? basePointCost : null;
      final pointsNeeded = pointCost == null || balance == null
          ? null
          : math.max(0, pointCost - balance);
      final productUsesNeeded = pointsNeeded == null || pointGain == 0
          ? null
          : (pointsNeeded ~/ pointGain) +
                (pointsNeeded % pointGain == 0 ? 0 : 1);
      final recordedExchangeCount = counter?['count'] as int?;
      final redeemedCount = targetReset == 1 && counter?['resetType'] == 1
          ? recordedExchangeCount
          : null;
      result.add({
        'gachaId': gachaId,
        'exchangeId': exchangeId,
        'exchangeProductId': exchangeProductId,
        'gachaProductId': selectedId,
        'reward': reward,
        'supported': supported,
        'basePointCost': basePointCost,
        'pointCost': pointCost,
        'pointBalance': balance,
        'pointsNeeded': pointsNeeded,
        'pointGain': pointGain,
        'productUsesNeeded': productUsesNeeded,
        'additionalDrawsNeeded': _safeProduct(productUsesNeeded, drawCount),
        'limitCount': limitCount,
        'resetType': targetReset,
        'recordedExchangeCount': recordedExchangeCount,
        'counterResetType': counter?['resetType'],
        'counterUpdatedAt': counter?['counterUpdatedAt'],
        'redeemedCount': redeemedCount,
        'redeemedQuantity': _safeProduct(
          redeemedCount,
          _integer(reward['count'])!,
        ),
        'remainingExchangeLimit': limitCount > 0 && redeemedCount != null
            ? math.max(0, limitCount - redeemedCount)
            : null,
        'exchangeStartAt': _dateProjection(exchange['startAt']),
        'exchangeEndAt': _dateProjection(exchange['endAt']),
        'startAt': _dateProjection(target['startAt']),
        'endAt': _dateProjection(target['endAt']),
      });
    }
  }
  return result;
}

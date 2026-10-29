/// Descriptive statistics for projected gacha batches. Expected values are
/// batch counts supplied by the caller's official pool/product projection.
library;

import 'dart:math' as math;

const _kinds = ['member', 'support', 'item', 'unknown'];
const _rarities = ['SSR', 'EX', 'BD', 'SR', 'R', 'item', 'unknown'];
const _costs = ['freeGems', 'paidGems', 'tickets'];
const _expected = ['high', 'memberSsr', 'supportSsr', 'pickup'];
const _rarityCodes = {
  '2': 'R',
  '3': 'SR',
  '4': 'SSR',
  '10': 'EX',
  '20': 'BD',
  'R': 'R',
  'SR': 'SR',
  'SSR': 'SSR',
  'EX': 'EX',
  'BD': 'BD',
};

Map<String, Object?> _map(Object? v) =>
    v is Map ? Map<String, Object?>.from(v) : const {};
num? _finiteAmount(Object? v) => v is num && v.isFinite && v >= 0 ? v : null;
int? _integerAmount(Object? v) =>
    v is num &&
        v.isFinite &&
        v >= 0 &&
        v <= 9007199254740991 &&
        v == v.truncateToDouble()
    ? v.toInt()
    : null;

/// Expected draw counts from normalized group/prize weights and the executed product.
/// Returns null for SpecialLot, ensured-new, user-selected pickups or incomplete metadata.
/// A guaranteed product requires its complete nominal draw count.
Map<String, double>? gachaHistoryExpectation(
  Map<String, Object?> pool,
  Map<String, Object?> option,
  int actualDrawCount,
) {
  final n = _integerAmount(actualDrawCount);
  final count = _integerAmount(option['guaranteedCount']);
  final rarity = _integerAmount(option['guaranteedRarity']);
  final type = _integerAmount(option['guaranteedType']);
  final selected = _integerAmount(pool['pickUpSelectCount'] ?? 0);
  // GachaEnsureType: None=1, MemberCard=2, SupportCard=3, either card=4, SpecialLot=5.
  if (n == null ||
      count == null ||
      rarity == null ||
      type == null ||
      selected == null ||
      option['guaranteedNew'] != false ||
      selected > 0 ||
      type < 1 ||
      type > 4 ||
      pool['rates'] is! List)
    return null;
  final guaranteed = count > 0 && (rarity > 0 || type != 1);
  final g = math.min(count, n);
  if (guaranteed &&
      (_integerAmount(option['drawCount']) != n ||
          count > n ||
          (pool['guaranteeRule'] != 'slot' &&
              pool['guaranteeRule'] != 'redraw')))
    return null;
  final ordinary = List.filled(4, 0.0),
      eligible = List.filled(4, 0.0),
      ineligible = List.filled(4, 0.0);
  double total = 0, ensured = 0, rejected = 0;
  for (final rawGroup in pool['rates'] as List) {
    if (rawGroup is! Map) return null;
    final group = _map(rawGroup), weight = _finiteAmount(rawGroup['rate']);
    if (weight == null) return null;
    if (weight == 0) continue;
    if (group['prizes'] is! List) return null;
    final entries = <(double, List<bool>, bool)>[];
    double inner = 0;
    for (final rawPrize in group['prizes'] as List) {
      if (rawPrize is! Map) return null;
      final prize = _map(rawPrize), p = _finiteAmount(rawPrize['rate']);
      if (p == null) return null;
      if (p == 0) continue;
      final resource = _integerAmount(prize['resourceType']);
      final kind = resource != null && resource > 0
          ? resource == 2
                ? 'member'
                : resource == 3
                ? 'support'
                : 'item'
          : prize['kind'] == 'MemberCard'
          ? 'member'
          : prize['kind'] == 'SupportCard'
          ? 'support'
          : prize['kind'] == 'Item'
          ? 'item'
          : null;
      final card = kind == 'member' || kind == 'support';
      final r = _integerAmount(
        prize['rarity'] ?? group['rarity'] ?? (card ? null : 0),
      );
      if (kind == null ||
          r == null ||
          (card && ![2, 3, 4, 10, 20].contains(r)) ||
          prize['pickup'] is! bool)
        return null;
      entries.add((
        p.toDouble(),
        [
          card && [4, 10, 20].contains(r),
          kind == 'member' && r == 4,
          kind == 'support' && r == 4,
          prize['pickup'] as bool,
        ],
        r >= rarity &&
            (type == 1 ||
                (type == 2 && kind == 'member') ||
                (type == 3 && kind == 'support') ||
                (type == 4 && card)),
      ));
      inner += p;
    }
    if (!(inner > 0) || !inner.isFinite) return null;
    total += weight;
    for (final entry in entries) {
      final mass = weight * (entry.$1 / inner);
      if (entry.$3) {
        ensured += mass;
      } else {
        rejected += mass;
      }
      for (var j = 0; j < _expected.length; j++) {
        if (entry.$2[j]) {
          ordinary[j] += mass;
          (entry.$3 ? eligible : ineligible)[j] += mass;
        }
      }
    }
  }
  if (!(total > 0) || !total.isFinite || (guaranteed && !(ensured > 0)))
    return null;
  final q = math.min(1.0, ensured / total);
  final redraws =
      guaranteed && pool['guaranteeRule'] == 'redraw' && rejected > 0
      ? _expectedShortfall(n, g, q)
      : 0.0;
  final result = <String, double>{};
  for (var j = 0; j < _expected.length; j++) {
    final p = ordinary[j] / total,
        a = ensured > 0 ? eligible[j] / ensured : 0.0;
    final value = !guaranteed
        ? n * p
        : pool['guaranteeRule'] == 'slot'
        ? (n - g) * p + g * a
        : n * p +
              redraws * (a - (rejected > 0 ? ineligible[j] / rejected : 0.0));
    result[_expected[j]] = math.max(0.0, math.min(n.toDouble(), value));
  }
  return result;
}

/// E[max(0, guaranteed - successes)] for successes ~ Binomial(n, q).
double _expectedShortfall(int n, int guaranteed, double q) {
  if (q <= 0) return guaranteed.toDouble();
  if (q >= 1 || guaranteed == 0) return 0;
  final pivot = math.min(guaranteed - 1, ((n + 1) * q).floor());
  var log = pivot * math.log(q) + (n - pivot) * math.log(1 - q);
  for (var i = 1; i <= math.min(pivot, n - pivot); i++) {
    log += math.log((n - i + 1) / i);
  }
  final atPivot = math.exp(log);
  var result = (guaranteed - pivot) * atPivot, probability = atPivot;
  for (var k = pivot; k > 0 && probability > 0; k--) {
    probability *= (k / (n - k + 1)) * ((1 - q) / q);
    result += (guaranteed - k + 1) * probability;
  }
  probability = atPivot;
  for (var k = pivot; k < guaranteed - 1 && probability > 0; k++) {
    probability *= ((n - k) / (k + 1)) * (q / (1 - q));
    result += (guaranteed - k - 1) * probability;
  }
  return math.max(0.0, math.min(guaranteed.toDouble(), result));
}

Map<String, int> _prizeCounts() => {
  'count': 0,
  'pickup': 0,
  'nonPickup': 0,
  'pickupUnknown': 0,
  'converted': 0,
};
Map<String, int> _drawCounts() => {
  'total': 0,
  'high': 0,
  'ssr': 0,
  'memberSsr': 0,
  'supportSsr': 0,
  'special': 0,
  'member': 0,
  'support': 0,
  'item': 0,
  'unknown': 0,
  'other': 0,
  'unknownRarity': 0,
  'pickup': 0,
  'nonPickup': 0,
  'pickupUnknown': 0,
  'converted': 0,
};
List<Map<String, Object?>> _distribution() => [
  for (final rarity in _rarities) {'rarity': rarity, ..._prizeCounts()},
];

final class _ExpectedState {
  num value = 0;
  int observed = 0, knownDraws = 0, knownBatches = 0;
}

final class _AggregateState {
  final counts = _drawCounts();
  int batches = 0;
  final cost = <String, Map<String, Object?>>{
    for (final key in _costs)
      key: {
        'value': null,
        'partial': false,
        'knownBatches': 0,
        'unknownBatches': 0,
      },
  };
  final expected = {for (final key in _expected) key: _ExpectedState()};
}

(String, String) _classify(Map<String, Object?> p) {
  final kind = _kinds.contains(p['kind']) ? p['kind'] as String : 'unknown';
  final raw = p['rarity'];
  final code = raw is num && _integerAmount(raw) != null
      ? raw.toInt().toString()
      : (raw ?? '').toString().trim().toUpperCase();
  return (
    kind,
    kind == 'item'
        ? 'item'
        : kind == 'unknown'
        ? 'unknown'
        : _rarityCodes[code] ?? 'unknown',
  );
}

void _addFlags(Map<String, Object?> c, Map<String, Object?> p) {
  final key = p['pickup'] == true
      ? 'pickup'
      : p['pickup'] == false
      ? 'nonPickup'
      : 'pickupUnknown';
  c[key] = (c[key] as int) + 1;
  if (p['converted'] == true) c['converted'] = (c['converted'] as int) + 1;
}

void _addDraw(
  Map<String, int> c,
  Map<String, Object?> p,
  String kind,
  String rarity,
) {
  c['total'] = c['total']! + 1;
  c[kind] = c[kind]! + 1;
  if (kind == 'item' || kind == 'unknown') c['other'] = c['other']! + 1;
  if ((kind == 'member' || kind == 'support') && rarity == 'unknown') {
    c['unknownRarity'] = c['unknownRarity']! + 1;
  }
  if (rarity == 'SSR') {
    c['ssr'] = c['ssr']! + 1;
    final key = kind == 'member' ? 'memberSsr' : 'supportSsr';
    c[key] = c[key]! + 1;
  }
  if (const ['SSR', 'EX', 'BD'].contains(rarity)) c['high'] = c['high']! + 1;
  if (rarity == 'EX' || rarity == 'BD') c['special'] = c['special']! + 1;
  _addFlags(c, p);
}

void _addBatch(
  _AggregateState s,
  Map<String, Object?> b,
  int draws,
  Map<String, int> observed,
) {
  s.batches++;
  final cost = _map(b['cost']), expected = _map(b['expected']);
  for (final key in _costs) {
    final value = _integerAmount(cost[key]), target = s.cost[key]!;
    if (value == null) {
      target['unknownBatches'] = (target['unknownBatches'] as int) + 1;
      target['partial'] = true;
    } else {
      target['knownBatches'] = (target['knownBatches'] as int) + 1;
      target['value'] = (target['value'] as num? ?? 0) + value;
    }
  }
  for (final key in _expected) {
    final value = _finiteAmount(expected[key]);
    if (value != null && value <= draws) {
      final target = s.expected[key]!;
      target.value += value;
      target.observed += observed[key]!;
      target.knownDraws += draws;
      target.knownBatches++;
    }
  }
}

Map<String, Object?> _rates(Map<String, int> c) => {
  'observedHighRate': c['total']! > 0 ? c['high']! / c['total']! : null,
  'observedSsrRate': c['total']! > 0 ? c['ssr']! / c['total']! : null,
  'pullsPerHigh': c['high']! > 0 ? c['total']! / c['high']! : null,
};

Map<String, Object?> _finish(_AggregateState s) {
  final expected = <String, Map<String, Object?>>{};
  for (final key in _expected) {
    final v = s.expected[key]!;
    expected[key] = {
      'value': v.knownBatches > 0 ? v.value : null,
      'observed': v.observed,
      'delta': v.knownBatches > 0 ? v.observed - v.value : null,
      'knownDraws': v.knownDraws,
      'unknownDraws': s.counts['total']! - v.knownDraws,
    };
  }
  if (s.batches == 0) {
    for (final key in _costs) s.cost[key]!['value'] = 0;
  }
  return {
    ...s.counts,
    'batches': s.batches,
    ..._rates(s.counts),
    'expected': expected,
    'expectedHigh': expected['high']!['value'],
    'delta': expected['high']!['delta'],
    'knownDraws': expected['high']!['knownDraws'],
    'unknownDraws': expected['high']!['unknownDraws'],
    'cost': s.cost,
  };
}

String? gachaHistoryDay(String? pulledAt, [int offsetMinutes = 480]) {
  if (offsetMinutes.abs() > 1440) throw RangeError('gacha_analysis_offset');
  return _historyDay(pulledAt, offsetMinutes);
}

String? _historyDay(Object? input, int offset) {
  if (input is! String || input.isEmpty || input.contains(',')) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(?:[zZ]|([+-])(\d{2}):?(\d{2}))?)?$',
  ).firstMatch(input);
  if (match == null) return null;
  final y = int.parse(match[1]!),
      m = int.parse(match[2]!),
      d = int.parse(match[3]!);
  if (m < 1 || m > 12 || d < 1) return null;
  final calendar = DateTime.utc(y, m, d);
  if (calendar.year != y || calendar.month != m || calendar.day != d)
    return null;
  if (match[4] != null) {
    final h = int.parse(match[4]!), minute = int.parse(match[5]!);
    final second = int.parse(match[6] ?? '0');
    if (h > 24 ||
        minute > 59 ||
        second > 59 ||
        (h == 24 &&
            (minute != 0 ||
                second != 0 ||
                (match[7] ?? '').contains(RegExp(r'[1-9]')))))
      return null;
  }
  if (int.parse(match[9] ?? '0') > 23 || int.parse(match[10] ?? '0') > 59) {
    return null;
  }
  final iso = input.length == 10
      ? '${input}T00:00:00Z'
      : RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(input)
      ? input
      : '${input}Z';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return null;
  final date = parsed.toUtc().add(Duration(minutes: offset));
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

int _nullableCompare(String? a, String? b) => a == b
    ? 0
    : a == null
    ? 1
    : b == null
    ? -1
    : a.compareTo(b);

/// Every prize row counts as one draw. Rates are fractions from zero to one.
/// Missing costs and expected values retain explicit incomplete coverage.
Map<String, Object?> analyzeGachaHistory(
  List<Map<String, Object?>> batches, [
  int offsetMinutes = 480,
]) {
  if (offsetMinutes.abs() > 1440) throw RangeError('gacha_analysis_offset');
  final overall = _AggregateState();
  final pools = <String?, _AggregateState>{};
  final days = <String?, Map<String, Object?>>{};
  final dayCounts = <String?, Map<String, int>>{};
  final cards = <String, Map<String, Object?>>{};
  final allDistribution = _distribution();
  final kindCounts = {for (final kind in _kinds) kind: _drawCounts()};
  final kindDistribution = {for (final kind in _kinds) kind: _distribution()};
  for (final batch in batches) {
    final prizes = batch['prizes'];
    if (prizes is! List) throw const FormatException('gacha_analysis_batch');
    final rawPoolId = batch['poolId'];
    final poolId = rawPoolId is String ? rawPoolId : null;
    final pool = pools.putIfAbsent(poolId, _AggregateState.new);
    final day = _historyDay(batch['pulledAt'], offsetMinutes);
    final daily = days.putIfAbsent(day, () => {'day': day, 'batches': 0});
    final dc = dayCounts.putIfAbsent(day, _drawCounts);
    daily['batches'] = (daily['batches'] as int) + 1;
    final observed = _drawCounts();
    for (final raw in prizes) {
      final p = _map(raw);
      final quantity = _integerAmount(p['quantity']);
      if (p['id'] is! String || quantity == null) {
        throw const FormatException('gacha_analysis_prize');
      }
      final (kind, rarity) = _classify(p);
      final section = kindCounts[kind]!;
      for (final target in [
        overall.counts,
        pool.counts,
        dc,
        observed,
        section,
      ]) {
        _addDraw(target, p, kind, rarity);
      }
      for (final rows in [allDistribution, kindDistribution[kind]!]) {
        final row = rows[_rarities.indexOf(rarity)];
        row['count'] = (row['count'] as int) + 1;
        _addFlags(row, p);
      }
      final key = '$kind:${p['id']}';
      final card = cards.putIfAbsent(
        key,
        () => {
          'key': key,
          'id': p['id'],
          'kind': kind,
          'quantity': 0,
          ..._prizeCounts(),
        },
      );
      card['count'] = (card['count'] as int) + 1;
      card['quantity'] = (card['quantity'] as int) + quantity;
      _addFlags(card, p);
    }
    _addBatch(overall, batch, prizes.length, observed);
    _addBatch(pool, batch, prizes.length, observed);
  }
  final poolRows =
      [
        for (final entry in pools.entries)
          <String, Object?>{'poolId': entry.key, ..._finish(entry.value)},
      ]..sort(
        (a, b) => (b['total'] as int).compareTo(a['total'] as int) != 0
            ? (b['total'] as int).compareTo(a['total'] as int)
            : _nullableCompare(a['poolId'] as String?, b['poolId'] as String?),
      );
  final dayRows = [
    for (final entry in days.entries)
      <String, Object?>{...dayCounts[entry.key]!, ...entry.value},
  ]..sort((a, b) => _nullableCompare(a['day'] as String?, b['day'] as String?));
  final cardRows = cards.values.toList()
    ..sort(
      (a, b) => (b['count'] as int).compareTo(a['count'] as int) != 0
          ? (b['count'] as int).compareTo(a['count'] as int)
          : (a['key'] as String).compareTo(b['key'] as String),
    );
  return {
    ..._finish(overall),
    'kinds': [
      for (final kind in _kinds)
        {
          ...kindCounts[kind]!,
          'kind': kind,
          ..._rates(kindCounts[kind]!),
          'distribution': kindDistribution[kind]!,
        },
    ],
    'distribution': allDistribution,
    'pools': poolRows,
    'days': dayRows,
    'cards': cardRows,
    'undated': dayCounts[null]?['total'] ?? 0,
  };
}

/// Free and paid gem prices are independent; tickets are left in their own unit.
Map<String, Object?> summarizeGachaHistoryMoney(
  Map<String, Object?> cost, {
  num? freeUnitGemPrice,
  num? paidUnitGemPrice,
}) {
  Map<String, Object?> component(Object? rawAmount, num? rawPrice) {
    final amount = _map(rawAmount), price = _finiteAmount(rawPrice);
    final base = _finiteAmount(amount['value']);
    final product = price != null && base != null ? price * base : null;
    final value = product != null && product.isFinite ? product : null;
    return {
      'value': value,
      'unitGemPrice': price,
      'partial': amount['partial'] == true || value == null,
    };
  }

  final free = component(cost['freeGems'], freeUnitGemPrice);
  final paid = component(cost['paidGems'], paidUnitGemPrice);
  final partial = free['partial'] == true || paid['partial'] == true;
  final sum = partial ? null : (free['value'] as num) + (paid['value'] as num);
  return {
    'freeGems': free,
    'paidGems': paid,
    'sum': sum != null && sum.isFinite ? sum : null,
    'partial': partial || (sum != null && !sum.isFinite),
  };
}

final class _ProgressGroup {
  final int time;
  final batchIds = <String>[];
  final prizes = <Map<String, Object?>>[];
  _ProgressGroup(this.time);
}

final class _HitGroup {
  final int lower, upper, count;
  _HitGroup(this.lower, this.upper, this.count);
}

int? _historyTime(String? value) {
  if (gachaHistoryDay(value, 0) == null) return null;
  final iso = value!.length == 10
      ? '${value}T00:00:00Z'
      : RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(value)
      ? value
      : '${value}Z';
  return DateTime.parse(iso).millisecondsSinceEpoch;
}

bool? _progressTarget(Map<String, Object?> p, String kind, String metric) {
  final (actualKind, rarity) = _classify(p);
  if (actualKind != kind) {
    return actualKind == 'unknown' && (metric == 'high' || p['pickup'] != false)
        ? null
        : false;
  }
  return metric == 'pickup'
      ? p['pickup'] is bool
            ? p['pickup'] as bool
            : null
      : rarity == 'unknown'
      ? null
      : const ['SSR', 'EX', 'BD'].contains(rarity);
}

Map<String, Object?> _emptyGaps(int? count) => {
  'count': count,
  'shortest': null,
  'longest': null,
  'mean': null,
};
Map<String, num> _interval(num min, num max) => {'min': min, 'max': max};
int _smaller(int a, int b) => a < b ? a : b;
int _larger(int a, int b) => a > b ? a : b;

Map<String, Object?> _gapSummary(List<_HitGroup> groups) {
  final count = groups.fold(0, (n, g) => n + g.count) - 1;
  if (count <= 0) return _emptyGaps(0);
  final ranges = <Map<String, num>>[];
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    if (g.count > 1) ranges.add(_interval(0, g.upper - g.lower + 1 - g.count));
    if (i > 0) {
      final p = groups[i - 1];
      ranges.add(
        _interval(
          _larger(0, g.lower - p.upper - 1),
          (g.upper - g.count + 1) - (p.lower + p.count - 1) - 1,
        ),
      );
    }
  }
  final upper = ranges.fold(0, (n, r) => _larger(n, r['max']! as int));
  // Earliest feasible hits leave room to maximize the smallest gap.
  bool fitsMinimum(int gap) {
    int? last;
    for (final g in groups) {
      last =
          _larger(g.lower, last == null ? g.lower : last + gap + 1) +
          (g.count - 1) * (gap + 1);
      if (last > g.upper) return false;
    }
    return true;
  }

  bool fitsMaximum(int gap) {
    // The latest feasible hit in each group reaches the next group best.
    int? last;
    for (final g in groups) {
      if (last == null) {
        last = g.upper;
        continue;
      }
      final first = _smaller(g.upper - g.count + 1, last + gap + 1);
      if (first < g.lower) return false;
      last = _smaller(g.upper, first + (g.count - 1) * (gap + 1));
    }
    return true;
  }

  var lo = 0, hi = upper;
  while (lo < hi) {
    final middle = (lo + hi + 1) ~/ 2;
    if (fitsMinimum(middle)) {
      lo = middle;
    } else {
      hi = middle - 1;
    }
  }
  final shortest = _interval(
    ranges.fold<int>(upper, (n, r) => _smaller(n, r['min']! as int)),
    lo,
  );
  lo = 0;
  hi = upper;
  while (lo < hi) {
    final middle = (lo + hi) ~/ 2;
    if (fitsMaximum(middle)) {
      hi = middle;
    } else {
      lo = middle + 1;
    }
  }
  final first = groups.first, last = groups.last;
  // Summed gaps telescope to the distance from the first hit to the last hit.
  final mean = groups.length == 1
      ? _interval(0, (first.upper - first.lower + 1 - first.count) / count)
      : _interval(
          _larger(
                0,
                (last.lower + last.count - 1) -
                    (first.upper - first.count + 1) -
                    count,
              ) /
              count,
          (last.upper - first.lower - count) / count,
        );
  return {
    'count': count,
    'shortest': shortest,
    'longest': _interval(lo, upper),
    'mean': mean,
  };
}

Map<String, Object?> _progressMetric(
  List<Map<String, Object?>> all,
  List<_ProgressGroup> groups,
  int undated,
  int undatedKind,
  String kind,
  String metric,
) {
  final states = all.map((p) => _progressTarget(p, kind, metric)).toList();
  final count = states.where((v) => v == true).length,
      unknownDraws = states.where((v) => v == null).length;
  final hits = <_HitGroup>[], hitBatches = <Map<String, Object?>>[];
  var before = 0, beforeKind = 0;
  int? lastUnknownEnd;
  for (final g in groups) {
    final targets = g.prizes
        .map((p) => _progressTarget(p, kind, metric))
        .toList();
    final n = g.prizes.length, k = targets.where((v) => v == true).length;
    final kindDraws = g.prizes.where((p) => _classify(p).$1 == kind).length;
    if (targets.contains(null)) lastUnknownEnd = before + n;
    if (k > 0) {
      hits.add(_HitGroup(before + 1, before + n, k));
      hitBatches.add({
        'batchIds': g.batchIds,
        'pulledAt': DateTime.fromMillisecondsSinceEpoch(
          g.time,
          isUtc: true,
        ).toIso8601String(),
        'count': k,
        'poolPosition': _interval(before + 1, before + n + undated),
        'kindPosition': _interval(
          beforeKind + 1,
          beforeKind + kindDraws + undatedKind,
        ),
      });
    }
    before += n;
    beforeKind += kindDraws;
  }
  final last = hits.isEmpty ? null : hits.last,
      possibleEnd = _larger(
        hits.isEmpty ? 0 : hits.last.upper,
        lastUnknownEnd ?? 0,
      );
  return {
    'count': count,
    'datedCount': hits.fold<int>(0, (n, g) => n + g.count),
    'unknownDraws': unknownDraws,
    'hitBatches': hitBatches,
    'gaps': undated > 0 || unknownDraws > 0
        ? _emptyGaps(null)
        : _gapSummary(hits),
    'trailingMisses': undated > 0
        ? null
        : _interval(
            before - possibleEnd,
            before - (last == null ? 0 : last.lower + last.count - 1),
          ),
    'partial': undated > 0 || unknownDraws > 0,
  };
}

/// Positions, gaps and trailing misses use all recorded draws in the pool.
/// Equal timestamps share one unordered group; kind positions are supplementary.
Map<String, Object?> gachaHistoryProgress(List<Map<String, Object?>> batches) {
  final pools = <String?, List<Map<String, Object?>>>{};
  for (final batch in batches) {
    final id = batch['poolId'] is String ? batch['poolId'] as String : null;
    pools.putIfAbsent(id, () => []).add(batch);
  }
  final result = <Map<String, Object?>>[];
  for (final entry in pools.entries) {
    final all = <Map<String, Object?>>[], unplaced = <Map<String, Object?>>[];
    final byTime = <int, _ProgressGroup>{};
    for (final batch in entry.value) {
      final rawPrizes = batch['prizes'];
      if (rawPrizes is! List)
        throw const FormatException('gacha_analysis_batch');
      final prizes = <Map<String, Object?>>[];
      for (final raw in rawPrizes) {
        final p = _map(raw);
        if (p['id'] is! String || _integerAmount(p['quantity']) == null)
          throw const FormatException('gacha_analysis_prize');
        prizes.add(p);
      }
      all.addAll(prizes);
      final time = _historyTime(
        batch['pulledAt'] is String ? batch['pulledAt'] as String : null,
      );
      if (time == null) {
        unplaced.addAll(prizes);
        continue;
      }
      final group = byTime.putIfAbsent(time, () => _ProgressGroup(time));
      group.batchIds.add(batch['id'] as String);
      group.prizes.addAll(prizes);
    }
    final groups = byTime.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    final kinds = <Map<String, Object?>>[];
    for (final kind in const ['member', 'support']) {
      final total = all.where((p) => _classify(p).$1 == kind).length,
          undatedKind = unplaced.where((p) => _classify(p).$1 == kind).length;
      kinds.add({
        'kind': kind,
        'total': total,
        'datedDraws': total - undatedKind,
        'high': _progressMetric(
          all,
          groups,
          unplaced.length,
          undatedKind,
          kind,
          'high',
        ),
        'pickup': _progressMetric(
          all,
          groups,
          unplaced.length,
          undatedKind,
          kind,
          'pickup',
        ),
      });
    }
    result.add({
      'poolId': entry.key,
      'total': all.length,
      'datedDraws': all.length - unplaced.length,
      'undatedDraws': unplaced.length,
      'unknownKindDraws': all.where((p) => _classify(p).$1 == 'unknown').length,
      'kinds': kinds,
    });
  }
  result.sort(
    (a, b) => (b['total'] as int).compareTo(a['total'] as int) != 0
        ? (b['total'] as int).compareTo(a['total'] as int)
        : _nullableCompare(a['poolId'] as String?, b['poolId'] as String?),
  );
  return {'pools': result};
}

bool? _hitTarget(Map<String, Object?> p, String target) {
  final (kind, rarity) = _classify(p);
  if (kind == 'item') return false;
  if (kind == 'unknown') return null;
  if (target == 'pickup')
    return p['pickup'] is bool ? p['pickup'] as bool : null;
  return rarity == 'unknown'
      ? null
      : const ['SSR', 'EX', 'BD'].contains(rarity);
}

final class _HitTimeGroup {
  final int time;
  final List<Map<String, Object?>> rows = [];
  _HitTimeGroup(this.time);
}

/// Chronological hits per pool across both card kinds (`high` or `pickup`).
/// Undated draws stay outside positions.
List<Map<String, Object?>> gachaHistoryHits(
  List<Map<String, Object?>> batches,
  String target,
) {
  final pools = <String?, List<Map<String, Object?>>>{};
  for (final batch in batches) {
    if (batch['prizes'] is! List) {
      throw const FormatException('gacha_analysis_batch');
    }
    final id = batch['poolId'] is String ? batch['poolId'] as String : null;
    pools.putIfAbsent(id, () => []).add(batch);
  }
  final result = <Map<String, Object?>>[];
  for (final entry in pools.entries) {
    final groups = <int, _HitTimeGroup>{};
    var total = 0, undatedDraws = 0, unknownDraws = 0;
    for (final batch in entry.value) {
      final prizes = [for (final p in batch['prizes'] as List) _map(p)];
      total += prizes.length;
      unknownDraws += prizes.where((p) => _hitTarget(p, target) == null).length;
      final time = _historyTime(
        batch['pulledAt'] is String ? batch['pulledAt'] as String : null,
      );
      if (time == null) {
        undatedDraws += prizes.length;
        continue;
      }
      groups.putIfAbsent(time, () => _HitTimeGroup(time)).rows.add(batch);
    }
    final hits = <Map<String, Object?>>[];
    var before = 0;
    _HitGroup? previous;
    for (final group
        in groups.values.toList()..sort((a, b) => a.time.compareTo(b.time))) {
      final found = [
        for (final batch in group.rows)
          for (final raw in batch['prizes'] as List)
            if (_hitTarget(_map(raw), target) == true) (batch, _map(raw)),
      ];
      final size = group.rows.fold<int>(
        0,
        (n, batch) => n + (batch['prizes'] as List).length,
      );
      final lower = before + 1, upper = before + size, k = found.length;
      final pulledAt = DateTime.fromMillisecondsSinceEpoch(
        group.time,
        isUtc: true,
      ).toIso8601String();
      for (final (i, (batch, prize)) in found.indexed) {
        final since = i > 0
            ? _interval(0, upper - lower + 1 - k)
            : previous != null
            ? _interval(
                _larger(0, lower - previous.upper - 1),
                upper - k + 1 - (previous.lower + previous.count - 1) - 1,
              )
            : _interval(lower - 1, upper - k);
        hits.add({
          'batchId': batch['id'],
          'pulledAt': pulledAt,
          'prize': prize,
          'position': _interval(lower + i, upper - (k - 1 - i)),
          'since': since,
        });
      }
      if (k > 0) previous = _HitGroup(lower, upper, k);
      before = upper;
    }
    result.add({
      'poolId': entry.key,
      'total': total,
      'undatedDraws': undatedDraws,
      'unknownDraws': unknownDraws,
      'hits': hits,
      'trailing': undatedDraws > 0
          ? null
          : previous != null
          ? _interval(
              before - previous.upper,
              before - (previous.lower + previous.count - 1),
            )
          : _interval(before, before),
    });
  }
  result.sort(
    (a, b) => (b['total'] as int).compareTo(a['total'] as int) != 0
        ? (b['total'] as int).compareTo(a['total'] as int)
        : _nullableCompare(a['poolId'] as String?, b['poolId'] as String?),
  );
  return result;
}

double _logGamma(double x) {
  const g = [
    676.5203681218851,
    -1259.1392167224028,
    771.32342877765313,
    -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
    9.9843695780195716e-6,
    1.5056327351493116e-7,
  ];
  if (x < 0.5) {
    return math.log(math.pi / math.sin(math.pi * x)) - _logGamma(1 - x);
  }
  x -= 1;
  var a = 0.99999999999980993;
  final t = x + 7.5;
  for (var i = 0; i < g.length; i++) {
    a += g[i] / (x + i + 1);
  }
  return 0.5 * math.log(2 * math.pi) +
      (x + 0.5) * math.log(t) -
      t +
      math.log(a);
}

typedef _Window = ({int lo, List<double> probs});

_Window _binomialWindow(int n, double p) {
  if (p <= 0) return (lo: 0, probs: [1.0]);
  if (p >= 1) return (lo: n, probs: [1.0]);
  final mean = n * p, sd = math.sqrt(n * p * (1 - p));
  final lo = _larger(0, (mean - 12 * sd - 4).floor()),
      hi = _smaller(n, (mean + 12 * sd + 4).ceil());
  final mode = _smaller(hi, _larger(lo, ((n + 1) * p).floor()));
  final probs = List<double>.filled(hi - lo + 1, 0);
  probs[mode - lo] = math.exp(
    _logGamma(n + 1.0) -
        _logGamma(mode + 1.0) -
        _logGamma(n - mode + 1.0) +
        mode * math.log(p) +
        (n - mode) * math.log(1 - p),
  );
  final odds = p / (1 - p);
  for (var k = mode; k < hi; k++) {
    probs[k + 1 - lo] = probs[k - lo] * ((n - k) / (k + 1)) * odds;
  }
  for (var k = mode; k > lo; k--) {
    probs[k - 1 - lo] = probs[k - lo] * (k / (n - k + 1)) / odds;
  }
  return (lo: lo, probs: probs);
}

_Window _convolve(_Window a, _Window b, double mean, double sd) {
  final lo = _larger(a.lo + b.lo, (mean - 12 * sd - 4).floor()),
      hi = _smaller(
        a.lo + a.probs.length + b.lo + b.probs.length - 2,
        (mean + 12 * sd + 4).ceil(),
      );
  final probs = List<double>.filled(_larger(1, hi - lo + 1), 0);
  for (var i = 0; i < a.probs.length; i++) {
    final x = a.probs[i];
    if (x < 1e-300) continue;
    for (var j = 0; j < b.probs.length; j++) {
      final k = a.lo + i + b.lo + j - lo;
      if (k >= 0 && k < probs.length) probs[k] += x * b.probs[j];
    }
  }
  return (lo: lo, probs: probs);
}

/// Where the observed count falls among outcomes of the same draws at
/// official rates. Each batch contributes its draws at that batch's mean
/// per-draw rate; batches without expectations are left out.
Map<String, Object?>? gachaHistoryLuck(
  List<Map<String, Object?>> batches,
  String target,
) {
  final byRate = <double, int>{};
  var observed = 0, draws = 0;
  num expected = 0;
  for (final batch in batches) {
    final prizes = [for (final p in batch['prizes'] as List) _map(p)];
    final n = prizes.length,
        value = _finiteAmount(_map(batch['expected'])[target]);
    if (n == 0 || value == null || value > n) continue;
    final counts = _drawCounts();
    for (final p in prizes) {
      final (kind, rarity) = _classify(p);
      _addDraw(counts, p, kind, rarity);
    }
    observed += counts[target]!;
    expected += value;
    draws += n;
    final key = (value / n * 1e12).round() / 1e12;
    byRate[key] = (byRate[key] ?? 0) + n;
  }
  if (draws == 0) return null;
  _Window distribution = (lo: 0, probs: [1.0]);
  var mean = 0.0, spread = 0.0;
  for (final entry
      in byRate.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    final p = entry.key, n = entry.value;
    mean += n * p;
    spread += n * p * (1 - p);
    distribution = _convolve(
      distribution,
      _binomialWindow(n, p),
      mean,
      math.sqrt(spread),
    );
  }
  final total = distribution.probs.fold<double>(0, (s, v) => s + v);
  var below = 0.0, at = 0.0;
  for (var i = 0; i < distribution.probs.length; i++) {
    final k = distribution.lo + i;
    if (k < observed) {
      below += distribution.probs[i] / total;
    } else if (k == observed) {
      at = distribution.probs[i] / total;
    }
  }
  if (observed < distribution.lo) below = at = 0;
  return {
    'observed': observed,
    'expected': expected,
    'draws': draws,
    'percentile': (below + at / 2).clamp(0.0, 1.0),
    'atLeast': (1 - below).clamp(0.0, 1.0),
  };
}

/// Official single-draw probabilities from normalized group and prize weights.
Map<String, Object?>? gachaPoolRates(Map<String, Object?> pool) {
  final rates = pool['rates'];
  if (rates is! List) return null;
  final rarities = <String, double>{
    'SSR': 0,
    'EX': 0,
    'BD': 0,
    'SR': 0,
    'R': 0,
    'item': 0,
  };
  var high = 0.0, memberHigh = 0.0, supportHigh = 0.0, pickup = 0.0;
  num total = 0;
  for (final rawGroup in rates) {
    final group = _map(rawGroup), weight = _finiteAmount(group['rate']);
    if (weight == null || group['prizes'] is! List) return null;
    if (weight == 0) continue;
    final prizes = [for (final p in group['prizes'] as List) _map(p)];
    final inner = prizes.fold<num>(
      0,
      (s, p) => s + (_finiteAmount(p['rate']) ?? 0),
    );
    if (!(inner > 0)) return null;
    total += weight;
    for (final prize in prizes) {
      final mass = weight * (_finiteAmount(prize['rate']) ?? 0) / inner;
      final type = _integerAmount(prize['resourceType']);
      final kind = type == 2
          ? 'member'
          : type == 3
          ? 'support'
          : 'item';
      final rarity = kind == 'item'
          ? 'item'
          : _rarityCodes['${_integerAmount(prize['rarity'] ?? group['rarity']) ?? ''}'];
      if (rarity == null) return null;
      rarities[rarity] = rarities[rarity]! + mass;
      if (const ['SSR', 'EX', 'BD'].contains(rarity)) {
        high += mass;
        if (kind == 'member') {
          memberHigh += mass;
        } else {
          supportHigh += mass;
        }
      }
      if (prize['pickup'] == true) pickup += mass;
    }
  }
  if (!(total > 0)) return null;
  return {
    'high': high / total,
    'memberHigh': memberHigh / total,
    'supportHigh': supportHigh / total,
    'pickup': pickup / total,
    'rarities': {
      for (final entry in rarities.entries) entry.key: entry.value / total,
    },
  };
}

/// Calendar months in server time; undated batches are excluded.
List<Map<String, Object?>> gachaHistoryMonths(
  List<Map<String, Object?>> batches, [
  int offsetMinutes = 480,
]) {
  final months = <String, _AggregateState>{};
  for (final batch in batches) {
    final month = gachaHistoryDay(
      batch['pulledAt'] is String ? batch['pulledAt'] as String : null,
      offsetMinutes,
    )?.substring(0, 7);
    if (month == null) continue;
    final state = months.putIfAbsent(month, _AggregateState.new);
    final prizes = [for (final p in batch['prizes'] as List) _map(p)];
    final observed = _drawCounts();
    for (final p in prizes) {
      final (kind, rarity) = _classify(p);
      _addDraw(state.counts, p, kind, rarity);
      _addDraw(observed, p, kind, rarity);
    }
    _addBatch(state, batch, prizes.length, observed);
  }
  return [
    for (final entry
        in months.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
      {
        'month': entry.key,
        ...entry.value.counts,
        'batches': entry.value.batches,
        'cost': entry.value.cost,
      },
  ];
}

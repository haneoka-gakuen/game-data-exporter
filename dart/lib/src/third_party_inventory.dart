part of '../game_data_exporter.dart';

// Same fact projection as game-data-exporter/src/third-party-inventory.ts.
Never _thirdInvalid() => throw const InventoryImportError('box_invalid_json');

const _thirdAbsent = Object();
Object? _thirdField(Map row, Object key) =>
    row.containsKey(key) ? row[key] : _thirdAbsent;

Map _thirdRow(Object? value) => value is Map ? value : _thirdInvalid();

List _thirdList(Object? value) {
  if (value is! List) _thirdInvalid();
  if (value.length > _rowsPerList) {
    throw const InventoryImportError('box_row_budget');
  }
  return value;
}

Iterable<MapEntry> _thirdEntries(Object? value) {
  final row = _thirdRow(value);
  if (row.length > _rowsPerList) {
    throw const InventoryImportError('box_row_budget');
  }
  return row.entries;
}

int _thirdId(Object? value) => _positiveId(value) ?? _thirdInvalid();
int _thirdNumber(Object? value) => _integer(value) ?? _thirdInvalid();

String _thirdServer(Object? value, Map<String, String> aliases) =>
    value is String ? aliases[value] ?? _thirdInvalid() : _thirdInvalid();

InventoryCandidate _thirdCandidate(String? server) =>
    InventoryCandidate(declaredServer: server);

void _otoInventory(Map inventory, InventoryCandidate result) {
  final release = inventory['sourceReleaseId'];
  if (_integer(inventory['schemaVersion']) != 1 ||
      release is! String ||
      release.trim().isEmpty ||
      release.length > 256) {
    _thirdInvalid();
  }
  final growth = inventory.containsKey('growth')
      ? _thirdRow(inventory['growth'])
      : const {};
  final seen = <String>{};
  for (final (kind, field) in const [
    ('member', 'memberCardIds'),
    ('support', 'supportCardIds'),
  ]) {
    for (final raw in _thirdList(inventory[field])) {
      if (raw is! String) _thirdInvalid();
      final match = RegExp('^$kind-card-([1-9][0-9]*)\$').firstMatch(raw);
      if (match == null || !seen.add(raw)) _thirdInvalid();
      final id = _thirdId(match.group(1));
      final item = growth.containsKey(raw) ? _thirdRow(growth[raw]) : const {};
      int? read(String field) {
        if (item[field] == null) {
          result.notices.add(
            InventoryNotice('unknown', 'inventory.growth.$raw.$field'),
          );
          return null;
        }
        return _thirdNumber(item[field]);
      }

      final level = read('level'), rank = read('rank');
      if (kind == 'member') {
        result.members.add(
          InventoryMember(
            id,
            level: level,
            rank: rank,
            awakeCount: read('awake'),
            liveSkillLevel: read('skillLevel'),
            performanceSkillLevel: read('gekisouSkillLevel'),
          ),
        );
      } else {
        result.snapshots.add(InventorySnapshot(id, level: level, rank: rank));
      }
    }
  }
}

InventoryCandidate _projectOto(Map root, {required bool personal}) {
  final server = personal || root.containsKey('serverId')
      ? _thirdServer(root['serverId'], const {
          'jp': 'jp',
          'global-hmt': 'intl',
          'global-en': 'intl',
          'global-kr': 'intl',
        })
      : null;
  if (personal && root['region'] != (server == 'jp' ? 'jp' : 'global')) {
    _thirdInvalid();
  }
  final result = _thirdCandidate(server);
  _otoInventory(personal ? _thirdRow(root['inventory']) : root, result);
  if (!personal) return result;
  final account = _thirdRow(root['account']);
  for (final field in const ['characterRanks', 'bandItems']) {
    if (!account.containsKey(field)) continue;
    for (final entry in _thirdEntries(account[field])) {
      final id = _thirdId(entry.key), value = _thirdNumber(entry.value);
      if (field == 'characterRanks') {
        result.characters.add((id, value));
      } else {
        result.bandItems.add((id, value));
      }
    }
  }
  if (account.containsKey('tgwCardRank')) {
    result.vipRank = _thirdNumber(account['tgwCardRank']);
  }
  if (account.containsKey('bandItemTotals')) {
    result.notices.add(
      const InventoryNotice('unsupported_field', 'account.bandItemTotals'),
    );
  }
  if (account.keys.any(
    (key) => !const {
      'characterRanks',
      'bandItems',
      'tgwCardRank',
      'bandItemTotals',
    }.contains(key),
  )) {
    result.notices.add(const InventoryNotice('unsupported_field', 'account'));
  }
  return result;
}

InventoryCandidate _projectMoe(Map root) {
  if (root['save'] != null) {
    throw const InventoryImportError('box_linked_save_required');
  }
  final result = _thirdCandidate(
    _thirdServer(root['server'], const {
      'jp': 'jp',
      'tw': 'intl',
      'en': 'intl',
      'kr': 'intl',
    }),
  );
  final player = _thirdRow(root['player']), seen = <String>{};
  Object? read(Object? value, String path) {
    if (identical(value, _thirdAbsent)) {
      result.notices.add(InventoryNotice('unknown', path));
      return null;
    }
    final field = _thirdRow(value), status = field['status'];
    if (!const {'unknown', 'observed', 'manual', 'conflict'}.contains(status) ||
        field['needsReview'] is! bool ||
        !field.containsKey('value')) {
      _thirdInvalid();
    }
    if (status == 'unknown' || status == 'conflict') {
      result.notices.add(InventoryNotice(status as String, path));
      return null;
    }
    if (field['needsReview'] == true) {
      result.notices.add(InventoryNotice('needs_review', path));
      return null;
    }
    return field['value'] ?? _thirdInvalid();
  }

  int? number(Object? value, String path) {
    final known = read(value, path);
    return known == null ? null : _thirdNumber(known);
  }

  final cards = _thirdList(root['cards']);
  for (var index = 0; index < cards.length; index++) {
    final card = _thirdRow(cards[index]), path = 'cards[$index]';
    final kind = card['kind'];
    if (kind != 'member' && kind != 'snap') _thirdInvalid();
    final identity = read(_thirdField(card, 'identity'), '$path.identity');
    if (identity == null) continue;
    final id = _thirdId(identity);
    if (!seen.add('$kind:$id')) _thirdInvalid();
    final fields = _thirdRow(card['fields']);
    final level = number(_thirdField(fields, 'level'), '$path.fields.level');
    final rank = number(_thirdField(fields, 'rank'), '$path.fields.rank');
    if (kind == 'member') {
      result.members.add(
        InventoryMember(
          id,
          level: level,
          rank: rank,
          awakeCount: number(
            _thirdField(fields, 'awake'),
            '$path.fields.awake',
          ),
          liveSkillLevel: number(
            _thirdField(fields, 'liveSkillLevel'),
            '$path.fields.liveSkillLevel',
          ),
          performanceSkillLevel: number(
            _thirdField(fields, 'gekisouSkillLevel'),
            '$path.fields.gekisouSkillLevel',
          ),
        ),
      );
    } else {
      result.snapshots.add(InventorySnapshot(id, level: level, rank: rank));
      for (final field in const [
        'awake',
        'liveSkillLevel',
        'gekisouSkillLevel',
      ]) {
        final value = fields[field];
        if (value is Map &&
            value['status'] != 'unknown' &&
            read(value, '$path.fields.$field') != null) {
          result.notices.add(
            InventoryNotice('unsupported_field', '$path.fields.$field'),
          );
        }
      }
    }
  }
  for (final entry in _thirdEntries(player['characterRanks'] ?? const {})) {
    final rank = number(entry.value, 'player.characterRanks.${entry.key}');
    if (rank != null) result.characters.add((_thirdId(entry.key), rank));
  }
  final items = _thirdRow(player['bandItems'] ?? const {});
  final states = _thirdRow(player['bandItemStates'] ?? const {});
  final keys = {...items.keys, ...states.keys};
  if (keys.length > _rowsPerList) {
    throw const InventoryImportError('box_row_budget');
  }
  for (final key in keys) {
    final id = _thirdId(key), path = 'player.bandItemStates.$key';
    final state = read(_thirdField(states, key), path);
    if (state == null) continue;
    if (!const {
      'owned',
      'active',
      'inactive',
      'not-owned',
      'no-bonus',
    }.contains(state)) {
      _thirdInvalid();
    }
    if (state == 'not-owned') {
      result.bandItems.add((id, 0));
    } else if (state == 'inactive' || state == 'no-bonus') {
      result.notices.add(InventoryNotice('inactive_band_item', path));
    } else {
      final level = number(_thirdField(items, key), 'player.bandItems.$key');
      if (level != null) result.bandItems.add((id, level));
    }
  }
  result.vipRank = number(_thirdField(player, 'vipRank'), 'player.vipRank');
  if (number(
        _thirdField(player, 'characterTotalRank'),
        'player.characterTotalRank',
      ) !=
      null) {
    result.notices.add(
      const InventoryNotice('unsupported_summary', 'player.characterTotalRank'),
    );
  }
  for (final key in const ['memory', 'eventIds']) {
    if (read(_thirdField(player, key), 'player.$key') != null) {
      result.notices.add(InventoryNotice('unsupported_field', 'player.$key'));
    }
  }
  for (final entry in _thirdEntries(player['catalogFields'] ?? const {})) {
    if (read(entry.value, 'player.catalogFields') != null) {
      result.notices.add(
        const InventoryNotice('unsupported_field', 'player.catalogFields'),
      );
    }
  }
  return result;
}

InventoryCandidate? projectThirdPartyInventory(Map root) {
  if (root['format'] == 'otonote-personal-growth') {
    if (_integer(root['schemaVersion']) != 1) _thirdInvalid();
    return _projectOto(root, personal: true);
  }
  if (root['format'] == 'moenotes.card-box/1') return _projectMoe(root);
  if (!root.containsKey('format') &&
      _integer(root['schemaVersion']) == 1 &&
      root['sourceReleaseId'] is String &&
      root['memberCardIds'] is List &&
      root['supportCardIds'] is List) {
    return _projectOto(root, personal: false);
  }
  return null;
}

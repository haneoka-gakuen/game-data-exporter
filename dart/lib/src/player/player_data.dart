import 'dart:typed_data';

/// Thrown when a GetPlayerDataResponse does not have the expected shape.
class PlayerDataFormatException implements Exception {
  const PlayerDataFormatException(this.code);
  final String code;
  @override
  String toString() => code;
}

const playerDataResponseLimit = 16 * 1024 * 1024;
const _maxRecords = 10000;

/// Wire field numbers inside `entity.PlayerData`, each mapped to the key the
/// game's own LocalCacheData `_player` uses for the same value.
const _collections = <int, (String, Map<int, String>)>{
  2: (
    '_memberCards',
    {
      2: '_masterId',
      3: '_exp',
      4: '_awakeCount',
      5: '_rank',
      7: '_liveSkillLevel',
      8: '_performanceSkillLevel',
    },
  ),
  3: (
    '_supportCards',
    {2: '_masterId', 3: '_exp', 5: '_rank', 7: '_duplicateCount'},
  ),
  8: ('_bandItems', {1: '_masterId', 2: '_level'}),
  12: ('_characters', {1: '_masterId', 2: '_exp'}),
};

Iterable<(int, int, Object)> _fields(Uint8List data) sync* {
  var pos = 0;
  int varint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (pos >= data.length) {
        throw const PlayerDataFormatException('player_data_truncated');
      }
      final byte = data[pos++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
    }
    throw const PlayerDataFormatException('player_data_varint');
  }

  while (pos < data.length) {
    final tag = varint();
    final number = tag >> 3, wire = tag & 7;
    if (number <= 0) {
      throw const PlayerDataFormatException('player_data_field');
    }
    switch (wire) {
      case 0:
        yield (number, wire, varint());
      case 1 || 5:
        final size = wire == 1 ? 8 : 4;
        if (pos + size > data.length) {
          throw const PlayerDataFormatException('player_data_truncated');
        }
        pos += size;
      case 2:
        final size = varint();
        if (size < 0 || pos + size > data.length) {
          throw const PlayerDataFormatException('player_data_truncated');
        }
        yield (number, wire, Uint8List.sublistView(data, pos, pos + size));
        pos += size;
      default:
        throw const PlayerDataFormatException('player_data_wire_type');
    }
  }
}

/// The card, character and band item progress in a GetPlayerDataResponse,
/// keyed as LocalCacheData's `_player` so save readers accept it unchanged.
Map<String, List<Map<String, Object?>>> decodePlayerData(Uint8List response) {
  if (response.length > playerDataResponseLimit) {
    throw const PlayerDataFormatException('player_data_size');
  }
  final players = [
    for (final (number, wire, value) in _fields(response))
      if (number == 1 && wire == 2) value as Uint8List,
  ];
  if (players.length != 1) {
    throw const PlayerDataFormatException('player_data_missing');
  }
  final out = {
    for (final (key, _) in _collections.values) key: <Map<String, Object?>>[],
  };
  var records = 0;
  for (final (number, wire, value) in _fields(players.single)) {
    final collection = _collections[number];
    if (collection == null || wire != 2) continue;
    if (++records > _maxRecords) {
      throw const PlayerDataFormatException('player_data_size');
    }
    final (key, spec) = collection;
    final row = <String, Object?>{for (final name in spec.values) name: 0};
    for (final (field, fieldWire, fieldValue) in _fields(value as Uint8List)) {
      final name = spec[field];
      if (name != null && fieldWire == 0) row[name] = fieldValue;
    }
    if ((row['_masterId'] as int) <= 0) {
      throw const PlayerDataFormatException('player_data_identity');
    }
    out[key]!.add(row);
  }
  return out;
}

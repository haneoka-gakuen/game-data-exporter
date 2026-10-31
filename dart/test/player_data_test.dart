import 'dart:typed_data';

import 'package:game_data_exporter/gacha_history.dart';
import 'package:test/test.dart';

List<int> _varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add((value & 0x7f) | 0x80);
    value >>= 7;
  }
  return out..add(value);
}

List<int> _int(int field, int value) => [
  ..._varint(field << 3),
  ..._varint(value),
];
List<int> _message(int field, List<int> body) => [
  ..._varint(field << 3 | 2),
  ..._varint(body.length),
  ...body,
];

void main() {
  test('maps GetPlayerData collections onto save keys', () {
    final player = [
      ..._message(2, [
        ..._int(2, 1012),
        ..._int(3, 123456),
        ..._int(4, 1),
        ..._int(5, 3),
        ..._int(7, 5),
        ..._int(8, 2),
        ..._int(11, 9),
      ]),
      ..._message(3, [
        ..._int(2, 2005),
        ..._int(3, 777),
        ..._int(5, 2),
        ..._int(7, 1),
      ]),
      ..._message(8, [..._int(1, 31), ..._int(2, 4)]),
      ..._message(12, [..._int(1, 7), ..._int(2, 4200)]),
      ..._message(99, [..._int(1, 1)]),
      ..._int(4, 42),
    ];
    final decoded = decodePlayerData(Uint8List.fromList(_message(1, player)));
    expect(decoded['_memberCards'], [
      {
        '_masterId': 1012,
        '_exp': 123456,
        '_awakeCount': 1,
        '_rank': 3,
        '_liveSkillLevel': 5,
        '_performanceSkillLevel': 2,
      },
    ]);
    expect(decoded['_supportCards'], [
      {'_masterId': 2005, '_exp': 777, '_rank': 2, '_duplicateCount': 1},
    ]);
    expect(decoded['_bandItems'], [
      {'_masterId': 31, '_level': 4},
    ]);
    expect(decoded['_characters'], [
      {'_masterId': 7, '_exp': 4200},
    ]);
  });

  test('omitted proto3 scalars read as zero', () {
    final decoded = decodePlayerData(
      Uint8List.fromList(_message(1, _message(2, _int(2, 1001)))),
    );
    expect(decoded['_memberCards']!.single['_awakeCount'], 0);
  });

  test('rejects responses without exactly one player', () {
    expect(
      () => decodePlayerData(Uint8List(0)),
      throwsA(isA<PlayerDataFormatException>()),
    );
    expect(
      () => decodePlayerData(
        Uint8List.fromList([..._message(1, []), ..._message(1, [])]),
      ),
      throwsA(isA<PlayerDataFormatException>()),
    );
  });

  test('rejects truncated data and cards without an ID', () {
    expect(
      () => decodePlayerData(Uint8List.fromList([0x0a, 0x05, 0x10])),
      throwsA(isA<PlayerDataFormatException>()),
    );
    expect(
      () => decodePlayerData(
        Uint8List.fromList(_message(1, _message(2, _int(3, 5)))),
      ),
      throwsA(isA<PlayerDataFormatException>()),
    );
  });
}

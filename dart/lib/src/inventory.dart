part of '../game_data_exporter.dart';

class InventoryImportError implements Exception {
  const InventoryImportError(this.code);
  final String code;
  @override
  String toString() => code;
}

class InventoryMember {
  const InventoryMember(
    this.cardId, {
    this.level,
    this.rank,
    this.awakeCount,
    this.liveSkillLevel,
    this.performanceSkillLevel,
  });
  final int cardId;
  final int? level, rank, awakeCount, liveSkillLevel, performanceSkillLevel;
  Map<String, Object?> toJson() => {
    'cardId': cardId,
    'exp': null,
    'level': level,
    'rank': rank,
    'awakeCount': awakeCount,
    'liveSkillLevel': liveSkillLevel,
    'performanceSkillLevel': performanceSkillLevel,
  };
}

class InventorySnapshot {
  const InventorySnapshot(this.cardId, {this.level, this.rank});
  final int cardId;
  final int? level, rank;
  Map<String, Object?> toJson() => {
    'cardId': cardId,
    'exp': null,
    'level': level,
    'rank': rank,
  };
}

class InventoryNotice {
  const InventoryNotice(this.code, this.path);
  final String code, path;
  Map<String, Object?> toJson() => {'code': code, 'path': path};
}

class InventoryCandidate {
  InventoryCandidate({this.declaredServer});
  final String? declaredServer;
  final List<InventoryMember> members = [];
  final List<InventorySnapshot> snapshots = [];
  final List<(int, int)> characters = [];
  final List<(int, int)> bandItems = [];
  final List<InventoryNotice> notices = [];
  int? vipRank;

  /// Uses the TypeScript candidate DTO; the receiving application assigns its ID.
  Map<String, Object?> toJson() => {
    'format': 'inventory-json',
    'members': [for (final row in members) row.toJson()],
    'snapshots': [for (final row in snapshots) row.toJson()],
    'characters': [
      for (final (id, rank) in characters)
        {'id': id, 'exp': null, 'rank': rank},
    ],
    'bandItems': [
      for (final (id, level) in bandItems) {'id': id, 'level': level},
    ],
    'notices': [for (final row in notices) row.toJson()],
    if (declaredServer != null) 'declaredIdentity': {'server': declaredServer},
    if (vipRank != null) 'playerScalars': {'vipRank': vipRank},
  };
}

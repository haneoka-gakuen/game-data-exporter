import 'dart:typed_data';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;

import 'history_snapshot.dart';

enum GameHistoryRegion {
  jp('jp', 'api.bang-dream-on.jp', 'jp'),
  hmt('global-hmt', 'l14-prod-hk-all-gs-sirius.gamerfusiontech.com', 'intl'),
  en('global-en', 'l14-prod-va-all-gs-sirius.bilibiligame.net', 'intl'),
  ko('global-kr', 'l14-prod-kr-all-gs-sirius.bilibiligame.net', 'intl');

  const GameHistoryRegion(this.id, this.host, this.catalogServer);
  final String id, host, catalogServer;
}

class SavedGameSession {
  SavedGameSession._(this._playerId, this._credential, this._deviceId);
  final String _playerId, _credential;
  final String? _deviceId;

  /// Reads the certification in one decrypted LocalPersistData document.
  static SavedGameSession? fromPersist(Object? document) =>
      document is Map ? fromCertification(document['_certification']) : null;

  /// Holds the session in memory for authenticated history reads.
  static SavedGameSession? fromCertification(Object? raw) {
    if (raw is! Map) return null;
    final player = raw['_playerId'], credential = raw['_authorizationKey'];
    if (player is! String ||
        player.isEmpty ||
        credential is! String ||
        credential.isEmpty) {
      return null;
    }
    final device = raw['_deviceId'];
    return SavedGameSession._(
      player,
      credential,
      device is String && device.isNotEmpty ? device : null,
    );
  }

  Map<String, String> _metadata() => {
    'x-player-id': _playerId,
    'x-player-credential': _credential,
    'x-device-id': ?_deviceId,
  };
}

class GameHistoryException implements Exception {
  const GameHistoryException(this.code);
  final String code;
  @override
  String toString() => code;
}

class _HistoryRpc extends Client {
  _HistoryRpc(super.channel);
  ResponseFuture<Uint8List> call(String method, CallOptions options) =>
      $createUnaryCall(
        ClientMethod<Uint8List, Uint8List>('/$method', (value) => value, (
          value,
        ) {
          if (value.length > historyResponseLimit) {
            throw const FormatException('history_size');
          }
          return Uint8List.fromList(value);
        }),
        Uint8List(0),
        options: options,
      );
}

class GameHistoryClient {
  static final _versions = <GameHistoryRegion, String>{};
  static final _versionPattern = RegExp(r'^\d+(?:\.\d+){1,4}$');

  Future<HistorySnapshot> read(
    SavedGameSession session,
    GameHistoryRegion region,
  ) async {
    final channel = ClientChannel(
      region.host,
      options: const ChannelOptions(connectTimeout: Duration(seconds: 15)),
    );
    final rpc = _HistoryRpc(channel);
    CallOptions options(String version, {bool authenticated = false}) =>
        CallOptions(
          metadata: {
            if (region == GameHistoryRegion.jp)
              'x-platform': Platform.isIOS ? 'iOS' : 'Android',
            'x-client-version': version,
            if (authenticated) ...session._metadata(),
          },
          timeout: const Duration(seconds: 25),
        );
    Future<String> discover() async {
      final method = region == GameHistoryRegion.jp
          ? 'app.announcement.AnnouncementService/GetList'
          : 'app.masterdata.MasterdataService/Version';
      final call = rpc.call(method, options('0.0.0'));
      final headers = call.headers.catchError((Object _) => <String, String>{});
      Map<String, String> trailers = const {};
      try {
        await call;
        trailers = await call.trailers;
      } on GrpcError catch (error) {
        trailers = error.trailers ?? const {};
        if (error.code == StatusCode.permissionDenied) {
          throw const GameHistoryException('history_service_unavailable');
        }
      }
      final metadata = {...await headers, ...trailers};
      final version = metadata['x-client-recommended-version'];
      if (version == null ||
          version.length > 32 ||
          !_versionPattern.hasMatch(version)) {
        throw const GameHistoryException('history_version_unavailable');
      }
      return _versions[region] = version;
    }

    try {
      var version = _versions[region] ?? await discover();
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final bytes = await rpc.call(
            'app.gacha.GachaService/History',
            options(version, authenticated: true),
          );
          return decodeHistoryResponse(
            bytes,
            server: region.id,
            clientVersion: version,
          );
        } on GrpcError catch (error) {
          if (attempt == 0 && error.message == 'client update required') {
            _versions.remove(region);
            version = await discover();
            continue;
          }
          if (error.code == StatusCode.unauthenticated ||
              error.message == 'authentication failed') {
            throw const GameHistoryException('history_session_expired');
          }
          throw GameHistoryException(
            error.code == StatusCode.permissionDenied
                ? 'history_service_unavailable'
                : error.code == StatusCode.dataLoss
                ? 'history_response_invalid'
                : 'history_network_error',
          );
        }
      }
      throw const GameHistoryException('history_version_unavailable');
    } on FormatException {
      throw const GameHistoryException('history_response_invalid');
    } on InvalidProtocolBufferException {
      throw const GameHistoryException('history_response_invalid');
    } on GrpcError catch (error) {
      throw GameHistoryException(
        error.code == StatusCode.dataLoss
            ? 'history_response_invalid'
            : 'history_network_error',
      );
    } finally {
      await channel.shutdown();
    }
  }
}

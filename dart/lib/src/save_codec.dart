import 'dart:convert';
import 'dart:typed_data';

import 'rijndael.dart';

/// The game's local save format, the same on every build and platform:
///
///     magic[32] ‖ iv[32] ‖ Rijndael-256-CBC(key, iv, PKCS#7(json))
///
/// The key and magic are constants of the game client, not account secrets.
class SaveCodec {
  static final Uint8List _magic = _hex(
    'b50b23a5fd628c3dc386f7488f81d6b0450b8c89671574f55a3ad815f10b8e30',
  );
  static final Uint8List _key = _hex(
    '0532791c510a08eb7ede6b46c6ba71ea9aa2a3cfb678a595f89d67c8a5e493b6',
  );
  static final Rijndael256 _cipher = Rijndael256(_key);

  /// Save files are a few hundred kilobytes; anything far larger is an asset.
  static const maxFileBytes = 16 << 20;

  /// Cheap check on the first bytes, before decrypting anything.
  static bool looksLikeSave(Uint8List bytes) {
    if (bytes.length < 96 ||
        bytes.length > maxFileBytes ||
        (bytes.length - 64) % 32 != 0) {
      return false;
    }
    for (var i = 0; i < 32; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Reads an original encrypted save or its decrypted UTF-8 JSON object.
  static Map<String, Object?>? decode(Uint8List bytes) {
    if (bytes.length > maxFileBytes) return null;
    if (!looksLikeSave(bytes)) return _json(bytes);
    final plain = _cipher.decryptCbc(
      Uint8List.sublistView(bytes, 64),
      Uint8List.sublistView(bytes, 32, 64),
    );
    try {
      final pad = plain.isEmpty ? 0 : plain.last;
      if (pad < 1 || pad > 32 || pad > plain.length) return null;
      for (var i = plain.length - pad; i < plain.length; i++) {
        if (plain[i] != pad) return null;
      }
      return _json(Uint8List.sublistView(plain, 0, plain.length - pad));
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Map<String, Object?>? _json(Uint8List bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List _hex(String s) => Uint8List.fromList([
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
}

import 'dart:typed_data';

/// Rijndael with a 256-bit block and a 256-bit key (14 rounds), the cipher
/// the game uses for its saves. This is not AES: AES fixes the block at 128
/// bits. Only decryption is needed here.
class Rijndael256 {
  Rijndael256(Uint8List key) : _roundKeys = _expand(key) {
    if (key.length != 32) throw ArgumentError('key must be 32 bytes');
  }

  static const _nb = 8; // 32-bit columns per block
  static const _nk = 8; // 32-bit columns per key
  static const _rounds = 14;
  // Row shifts for an eight-column block.
  static const _shift = [0, 1, 3, 4];

  final Uint8List _roundKeys;

  /// Decrypts one 32-byte block in place.
  void decryptBlock(Uint8List block) {
    final state = Uint8List.fromList(block);
    _addRoundKey(state, _rounds);
    for (var round = _rounds - 1; round >= 1; round--) {
      _invShiftRows(state);
      _invSubBytes(state);
      _addRoundKey(state, round);
      _invMixColumns(state);
    }
    _invShiftRows(state);
    _invSubBytes(state);
    _addRoundKey(state, 0);
    block.setAll(0, state);
  }

  /// CBC decryption of whole blocks; [iv] is one block.
  Uint8List decryptCbc(Uint8List data, Uint8List iv) {
    if (data.length % 32 != 0) throw ArgumentError('data is not whole blocks');
    final out = Uint8List(data.length);
    var previous = Uint8List.fromList(iv);
    final block = Uint8List(32);
    for (var offset = 0; offset < data.length; offset += 32) {
      final cipher = Uint8List.sublistView(data, offset, offset + 32);
      block.setAll(0, cipher);
      decryptBlock(block);
      for (var i = 0; i < 32; i++) {
        out[offset + i] = block[i] ^ previous[i];
      }
      previous = Uint8List.fromList(cipher);
    }
    return out;
  }

  // State byte index: column c, row r -> c * 4 + r.
  static void _invShiftRows(Uint8List s) {
    final copy = Uint8List.fromList(s);
    for (var r = 1; r < 4; r++) {
      for (var c = 0; c < _nb; c++) {
        s[((c + _shift[r]) % _nb) * 4 + r] = copy[c * 4 + r];
      }
    }
  }

  static void _invSubBytes(Uint8List s) {
    for (var i = 0; i < s.length; i++) {
      s[i] = _invSbox[s[i]];
    }
  }

  void _addRoundKey(Uint8List s, int round) {
    final base = round * _nb * 4;
    for (var i = 0; i < _nb * 4; i++) {
      s[i] ^= _roundKeys[base + i];
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < _nb; c++) {
      final a0 = s[c * 4],
          a1 = s[c * 4 + 1],
          a2 = s[c * 4 + 2],
          a3 = s[c * 4 + 3];
      s[c * 4] = _mul(a0, 14) ^ _mul(a1, 11) ^ _mul(a2, 13) ^ _mul(a3, 9);
      s[c * 4 + 1] = _mul(a0, 9) ^ _mul(a1, 14) ^ _mul(a2, 11) ^ _mul(a3, 13);
      s[c * 4 + 2] = _mul(a0, 13) ^ _mul(a1, 9) ^ _mul(a2, 14) ^ _mul(a3, 11);
      s[c * 4 + 3] = _mul(a0, 11) ^ _mul(a1, 13) ^ _mul(a2, 9) ^ _mul(a3, 14);
    }
  }

  static int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x1b : 0)) & 0xff;

  static int _mul(int a, int b) {
    var result = 0;
    while (b > 0) {
      if (b & 1 != 0) result ^= a;
      a = _xtime(a);
      b >>= 1;
    }
    return result;
  }

  static Uint8List _expand(Uint8List key) {
    final words = (_rounds + 1) * _nb;
    final w = Uint8List(words * 4);
    w.setAll(0, key);
    var rcon = 1;
    final temp = Uint8List(4);
    for (var i = _nk; i < words; i++) {
      temp.setAll(0, Uint8List.sublistView(w, (i - 1) * 4, i * 4));
      if (i % _nk == 0) {
        final t0 = temp[0];
        temp[0] = _sbox[temp[1]] ^ rcon;
        temp[1] = _sbox[temp[2]];
        temp[2] = _sbox[temp[3]];
        temp[3] = _sbox[t0];
        rcon = _xtime(rcon);
      } else if (i % _nk == 4) {
        for (var j = 0; j < 4; j++) {
          temp[j] = _sbox[temp[j]];
        }
      }
      for (var j = 0; j < 4; j++) {
        w[i * 4 + j] = w[(i - _nk) * 4 + j] ^ temp[j];
      }
    }
    return w;
  }

  static final Uint8List _sbox = _buildSbox();
  static final Uint8List _invSbox = () {
    final inverse = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      inverse[_sbox[i]] = i;
    }
    return inverse;
  }();

  static int _rot(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xff;

  static Uint8List _buildSbox() {
    final box = Uint8List(256);
    var p = 1, q = 1;
    do {
      p = p ^ ((p << 1) & 0xff) ^ ((p & 0x80) != 0 ? 0x1b : 0);
      q ^= (q << 1) & 0xff;
      q ^= (q << 2) & 0xff;
      q ^= (q << 4) & 0xff;
      if (q & 0x80 != 0) q ^= 0x09;
      box[p] =
          (q ^ _rot(q, 1) ^ _rot(q, 2) ^ _rot(q, 3) ^ _rot(q, 4) ^ 0x63) & 0xff;
    } while (p != 1);
    box[0] = 0x63;
    return box;
  }
}

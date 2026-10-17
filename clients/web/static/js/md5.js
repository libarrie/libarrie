// MD5 (RFC 1321) for upload integrity with object stores that verify only
// Content-MD5 (Cloudflare R2). WebCrypto has no MD5. Not used for security.
(function (global) {
  "use strict";
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  var K = new Uint32Array(64);
  for (var i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0;

  function md5(bytes) {
    var length = bytes.length;
    var padded = new Uint8Array(((length + 8) >> 6) * 64 + 64);
    padded.set(bytes);
    padded[length] = 0x80;
    var bitLength = length * 8;
    var view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, bitLength >>> 0, true);
    view.setUint32(padded.length - 4, Math.floor(bitLength / 4294967296), true);
    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    var M = new Uint32Array(16);
    for (var offset = 0; offset < padded.length; offset += 64) {
      for (var j = 0; j < 16; j++) M[j] = view.getUint32(offset + j * 4, true);
      var A = a0, B = b0, C = c0, D = d0;
      for (var n = 0; n < 64; n++) {
        var F, g;
        if (n < 16) { F = (B & C) | (~B & D); g = n; }
        else if (n < 32) { F = (D & B) | (~D & C); g = (5 * n + 1) % 16; }
        else if (n < 48) { F = B ^ C ^ D; g = (3 * n + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * n) % 16; }
        F = (F + A + K[n] + M[g]) >>> 0;
        A = D; D = C; C = B;
        B = (B + ((F << S[n]) | (F >>> (32 - S[n])))) >>> 0;
      }
      a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
    }
    var out = new DataView(new ArrayBuffer(16));
    out.setUint32(0, a0, true); out.setUint32(4, b0, true);
    out.setUint32(8, c0, true); out.setUint32(12, d0, true);
    var hex = "";
    for (var b = 0; b < 16; b++) hex += ("0" + out.getUint8(b).toString(16)).slice(-2);
    return hex;
  }

  global.LibarrieMd5 = md5;
})(window);

// QR codes for pairing: as text for the console (two modules per character with half
// blocks; light modules are drawn, so it reads on a dark console) and as a PNG.
import 'dart:io';
import 'dart:typed_data';

import 'package:qr/qr.dart';

QrImage _image(String data) =>
    QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.low));

/// The QR code as lines of `█`, `▀`, `▄` and spaces, with a 2-module quiet zone.
String qrText(String data, {int border = 2}) {
  final img = _image(data);
  final n = img.moduleCount + 2 * border;
  bool light(int r, int c) {
    final rr = r - border, cc = c - border;
    if (rr < 0 || cc < 0 || rr >= img.moduleCount || cc >= img.moduleCount) return true;
    return !img.isDark(rr, cc);
  }

  final lines = <String>[];
  for (var r = 0; r < n; r += 2) {
    final b = StringBuffer();
    for (var c = 0; c < n; c++) {
      final top = light(r, c);
      final bottom = r + 1 < n ? light(r + 1, c) : true;
      b.write(top && bottom
          ? '█'
          : top
              ? '▀'
              : bottom
                  ? '▄'
                  : ' ');
    }
    lines.add(b.toString());
  }
  return lines.join('\n');
}

/// The QR code as an 8-bit greyscale PNG ([scale] pixels per module, [border] modules of
/// quiet zone).
Uint8List qrPng(String data, {int scale = 8, int border = 4}) {
  final img = _image(data);
  final modules = img.moduleCount + 2 * border;
  final size = modules * scale;
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < size; y++) {
    final row = Uint8List(size + 1); // filter byte 0, then pixels
    final r = y ~/ scale - border;
    for (var x = 0; x < size; x++) {
      final c = x ~/ scale - border;
      final dark = r >= 0 && c >= 0 && r < img.moduleCount && c < img.moduleCount && img.isDark(r, c);
      row[x + 1] = dark ? 0 : 255;
    }
    raw.add(row);
  }
  final ihdr = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 0) // greyscale
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_chunk('IHDR', ihdr.buffer.asUint8List()))
    ..add(_chunk('IDAT', Uint8List.fromList(ZLibCodec(level: 9).encode(raw.takeBytes()))))
    ..add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = type.codeUnits;
  final b = ByteData(12 + data.length)..setUint32(0, data.length);
  final bytes = b.buffer.asUint8List()
    ..setRange(4, 8, typeBytes)
    ..setRange(8, 8 + data.length, data);
  b.setUint32(8 + data.length, crc32([...typeBytes, ...data]));
  return bytes;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  }
  return c ^ 0xFFFFFFFF;
}

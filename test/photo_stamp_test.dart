import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rutestrip/screens/photo_stamp_screen.dart';

Future<Uint8List> _photo(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF3B7A57));
  final img = await recorder.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the stamp keeps the photo size (up to 1600 px wide) and draws the info band at the bottom', () async {
    final out = await stampPhoto(await _photo(800, 600), 'Merbabu via Selo', ['2.840 mdpl · -7.45010, 110.43010', '22/11/2026 21.53 · 3,2 km · +540 m']);
    final img = await (await ui.instantiateImageCodec(out)).getNextFrame();
    expect(img.image.width, 800); // small photos are not enlarged
    expect(img.image.height, 600);
    final px = (await img.image.toByteData())!;
    // Top left keeps the photo colour; the bottom band is darker (dark emerald overlay).
    final top = px.getUint8(0) + px.getUint8(1) + px.getUint8(2);
    final o = ((img.image.height - 4) * img.image.width + 10) * 4;
    final bottom = px.getUint8(o) + px.getUint8(o + 1) + px.getUint8(o + 2);
    expect(bottom, lessThan(top));
  });
}

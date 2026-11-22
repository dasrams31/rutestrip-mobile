import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n.dart';
import '../theme.dart';

/// What goes on the photo: where and when it was taken and how far the hike has come.
class StampInfo {
  const StampInfo({required this.title, this.lat, this.lng, this.ele, this.distanceKm, this.gainM});

  final String title;
  final double? lat, lng, ele, distanceKm, gainM;
}

/// Takes a photo with the camera and opens it with the hike info drawn on it.
Future<void> takeStampedPhoto(BuildContext context, StampInfo info) async {
  final messenger = ScaffoldMessenger.of(context);
  final status = await Permission.camera.request();
  if (!context.mounted) return;
  if (!status.isGranted) {
    messenger.showSnackBar(SnackBar(content: Text(tr(context, 'stamp.camera'))));
    return;
  }
  final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 88);
  if (shot == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PhotoStampScreen(photo: shot, info: info),
    ),
  );
}

class PhotoStampScreen extends StatefulWidget {
  const PhotoStampScreen({super.key, required this.photo, required this.info});

  final XFile photo;
  final StampInfo info;

  @override
  State<PhotoStampScreen> createState() => _PhotoStampScreenState();
}

class _PhotoStampScreenState extends State<PhotoStampScreen> {
  Uint8List? _png;
  File? _file;
  bool _busy = false, _saved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_png == null && !_busy) _render();
  }

  Future<void> _render() async {
    _busy = true;
    final lines = _lines(context);
    try {
      final png = await stampPhoto(await widget.photo.readAsBytes(), widget.info.title, lines);
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/photos');
      await dir.create(recursive: true);
      final file = File('${dir.path}/rutestrip_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(png);
      if (mounted) {
        setState(() {
          _png = png;
          _file = file;
        });
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'stamp.failed'))));
    } finally {
      _busy = false;
    }
  }

  List<String> _lines(BuildContext context) {
    final i = widget.info;
    final t = DateTime.now();
    final clock = '${t.day}/${t.month}/${t.year} ${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
    return [
      [
        if (i.ele != null && i.ele != 0) '${fmtNum(context, i.ele)} mdpl',
        if (i.lat != null && i.lng != null) '${i.lat!.toStringAsFixed(5)}, ${i.lng!.toStringAsFixed(5)}',
      ].join(' · '),
      [
        clock,
        if (i.distanceKm != null && i.distanceKm! > 0) '${fmtNum(context, i.distanceKm, 1)} km',
        if (i.gainM != null && i.gainM! > 0) '+${fmtNum(context, i.gainM)} m',
      ].join(' · '),
    ].where((l) => l.isNotEmpty).toList();
  }

  Future<void> _save() async {
    final png = _png;
    if (png == null) return;
    try {
      if (!await Gal.hasPermission(toAlbum: true)) await Gal.requestPermission(toAlbum: true);
      await Gal.putImageBytes(png, album: 'RuteStrip', name: 'rutestrip_${DateTime.now().millisecondsSinceEpoch}');
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'stamp.saved'))));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'stamp.save_failed'))));
    }
  }

  Future<void> _share() async {
    final f = _file;
    if (f == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, mimeType: 'image/png')],
        text: widget.info.title,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: RS.z9, foregroundColor: Colors.white, title: Text(tr(context, 'stamp.title'))),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _png == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : InteractiveViewer(child: Image.memory(_png!, semanticLabel: tr(context, 'stamp.title'))),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                      ),
                      onPressed: _png == null ? null : _share,
                      icon: const Icon(Icons.share),
                      label: Text(tr(context, 'stamp.share')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SignButton(label: tr(context, _saved ? 'stamp.saved.short' : 'stamp.save'), onPressed: _png == null || _saved ? null : _save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws a dark band with the hike info and the RuteStrip mark at the bottom of the photo.
Future<Uint8List> stampPhoto(Uint8List photo, String title, List<String> lines) async {
  // At most 1600 px wide (light on memory for standard phones); smaller photos keep their size.
  final desc = await ui.ImageDescriptor.encoded(await ui.ImmutableBuffer.fromUint8List(photo));
  final codec = await desc.instantiateCodec(targetWidth: desc.width > 1600 ? 1600 : null);
  final img = (await codec.getNextFrame()).image;
  final w = img.width.toDouble(), h = img.height.toDouble();
  final s = w / 1080; // sizes are designed for a 1080 px wide photo

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(img, Offset.zero, Paint());

  final band = 70 * s + 56 * s * lines.length;
  final top = h - band - 40 * s;
  canvas.drawRect(
    Rect.fromLTWH(0, top, w, h - top),
    Paint()
      ..shader = ui.Gradient.linear(Offset(0, top), Offset(0, h), [const Color(0x00053B30), const Color(0xCC053B30), const Color(0xF2053B30)], [0, 0.35, 1]),
  );

  TextPainter paint(String text, double size, {String family = RS.body, FontWeight weight = FontWeight.w600, Color color = Colors.white}) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: family, fontSize: size, fontWeight: weight, color: color, height: 1.15),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: w - 220 * s);

  var y = h - band;
  final titleTp = paint(title.toUpperCase(), 64 * s, family: RS.display, weight: FontWeight.w700);
  titleTp.paint(canvas, Offset(44 * s, y));
  y += titleTp.height + 10 * s;
  for (final l in lines) {
    final tp = paint(l, 36 * s, color: const Color(0xFFD1FAE5));
    tp.paint(canvas, Offset(44 * s, y));
    y += tp.height + 8 * s;
  }

  // The RuteStrip mark bottom right.
  try {
    final logoData = await rootBundle.load('assets/images/logo.png');
    final logo = (await (await ui.instantiateImageCodec(logoData.buffer.asUint8List(), targetWidth: (120 * s).round())).getNextFrame()).image;
    final size = 120 * s;
    final dst = Rect.fromLTWH(w - size - 40 * s, h - size - 70 * s, size, size);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(dst, Radius.circular(26 * s)));
    canvas.drawImageRect(logo, Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()), dst, Paint()..filterQuality = FilterQuality.medium);
    canvas.restore();
    final name = paint('RuteStrip', 30 * s, family: RS.display, weight: FontWeight.w700);
    name.paint(canvas, Offset(dst.center.dx - name.width / 2, dst.bottom + 6 * s));
  } catch (_) {}

  final out = await recorder.endRecording().toImage(img.width, img.height);
  final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

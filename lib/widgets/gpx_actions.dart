import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../gpx_import.dart';
import '../i18n.dart';
import '../screens/record_screen.dart';
import '../screens/shell.dart';
import '../storage.dart';
import '../theme.dart';
import 'common.dart';

/// Pick a GPX file on the phone, keep it with the recordings (works offline) and return it.
Future<Recording?> importGpx(BuildContext context) async {
  final file = await FilePicker.pickFile(type: FileType.any);
  if (file?.path == null || !context.mounted) return null;
  final messenger = ScaffoldMessenger.of(context);
  final bad = tr(context, 'gpx.import.bad');
  final fallback = file!.name.replaceAll(RegExp(r'\.(gpx|xml)$', caseSensitive: false), '').replaceAll(RegExp(r'[_-]+'), ' ').trim();
  try {
    final f = File(file.path!);
    if (await f.length() > 20 * 1024 * 1024) throw const FormatException('too big');
    final r = GpxImport.parse(await f.readAsString()).toRecording(fallback.isEmpty ? 'GPX' : fallback);
    await RecordingStore.save(r);
    return r;
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(bad)));
    return null;
  }
}

/// Follow a recording or imported GPX in the Rekam tab.
void followInRecord(BuildContext context, Recording r) {
  followRoute.value = RouteDetail.fromJson({
    'id': -1,
    'name': r.name,
    'coordinates': [
      for (final p in r.points) [p.lat, p.lng],
    ],
  });
  Navigator.of(context).popUntil((route) => route.isFirst);
  Shell.globalKey.currentState?.open(Tabs.record);
}

/// Emergency sheet: the hiker's coordinates, calls to 112 / Basarnas 115, and sharing the
/// position through any app on the phone (needs a phone signal; nothing is sent by RuteStrip).
Future<void> showEmergency(BuildContext context, {double? lat, double? lng, double? accuracy}) {
  final has = lat != null && lng != null;
  final coords = has ? '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}' : null;
  final link = has ? 'https://www.google.com/maps?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}' : null;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(context, 'sos.title').toUpperCase(), style: RS.head(30, color: RS.err)),
            const SizedBox(height: 6),
            Text(tr(context, 'sos.lead'), style: const TextStyle(height: 1.4)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: RS.line),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'sos.position'),
                    style: const TextStyle(fontSize: 13, color: RS.muted, fontWeight: FontWeight.w600),
                  ),
                  SelectableText(
                    coords ?? tr(context, 'record.waiting'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                  if (accuracy != null) Text(tr(context, 'record.accuracy', {'m': accuracy.round()}), style: const TextStyle(fontSize: 13, color: RS.muted)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (has)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: coords!));
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'sos.copied'))));
                      },
                      icon: const Icon(Icons.copy),
                      label: Text(tr(context, 'sos.copy')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => SharePlus.instance.share(ShareParams(text: tr(context, 'sos.message', {'coords': coords, 'link': link}))),
                      icon: const Icon(Icons.share_location),
                      label: Text(tr(context, 'sos.share')),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: RS.err, minimumSize: const Size(48, 52)),
              onPressed: () => openExternal('tel:112'),
              icon: const Icon(Icons.call),
              label: Text(tr(context, 'sos.call112')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: RS.err,
                side: const BorderSide(color: RS.err),
              ),
              onPressed: () => openExternal('tel:115'),
              icon: const Icon(Icons.call),
              label: Text(tr(context, 'sos.call115')),
            ),
            const SizedBox(height: 10),
            Text(tr(context, 'sos.note'), style: const TextStyle(fontSize: 12.5, color: RS.muted, height: 1.4)),
          ],
        ),
      ),
    ),
  );
}

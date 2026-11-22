import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n.dart';
import '../recording_math.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/elevation_chart.dart';
import '../widgets/gpx_actions.dart';
import '../widgets/trail_map.dart';
import 'record_screen.dart';
import 'replay_screen.dart';
import 'upload_screen.dart';

/// One saved GPS recording: map, numbers, elevation profile, marked points, and
/// what can be done with it (share the GPX file, upload, rename, delete).
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.recording});

  final Recording recording;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late final Recording r = widget.recording;
  late final List<List<double>> _profile = recordingProfile([for (final p in r.points) (lat: p.lat, lng: p.lng, ele: p.ele)]);

  List<LatLng> get _track => r.points.map((p) => LatLng(p.lat, p.lng)).toList();

  Future<void> _share() async {
    final path = await RecordingStore.gpxPath(r);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'application/gpx+xml')],
        subject: r.name,
      ),
    );
  }

  Future<void> _rename() async {
    final name = TextEditingController(text: r.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'rec.rename')),
        content: TextField(
          controller: name,
          maxLength: 120,
          decoration: InputDecoration(labelText: tr(context, 'record.name')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(context, 'set.save'))),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    r.name = name.text.trim();
    await RecordingStore.save(r);
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'me.recording.delete.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RS.err),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'me.recording.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await RecordingStore.remove(r.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = r.startedAt.toLocal();
    final when = '${t.day}/${t.month}/${t.year} ${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ContourHeader(
            seed: 61,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                const SizedBox(height: 10),
                Text(
                  when,
                  style: const TextStyle(color: RS.onDarkSoft, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Semantics(
                  header: true,
                  child: Text(r.name.toUpperCase(), style: RS.head(36, color: Colors.white)),
                ),
              ],
            ),
          ),
          Padding(
            padding: pageGutter(context, top: 16, bottom: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_track.length >= 2)
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 240,
                          child: IgnorePointer(child: _RecordingMap(recording: r)),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => Scaffold(
                                  appBar: AppBar(
                                    backgroundColor: RS.z9,
                                    foregroundColor: Colors.white,
                                    title: Text(
                                      r.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: RS.head(24, color: Colors.white),
                                    ),
                                  ),
                                  body: _RecordingMap(recording: r, interactive: true),
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.fullscreen),
                            label: Text(tr(context, 'detail.map.open')),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: StatItem(label: tr(context, 'record.distance'), value: '${fmtNum(context, r.distanceKm, 2)} km'),
                            ),
                            Expanded(
                              child: r.imported
                                  ? StatItem(label: tr(context, 'gpx.naismith'), value: fmtHours(context, r.distanceKm / 5 + r.gainM / 600))
                                  : StatItem(label: tr(context, 'rec.moving'), value: fmtHours(context, r.movingSeconds / 3600)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: StatItem(label: tr(context, 'record.gain'), value: '${fmtNum(context, r.gainM)} m'),
                            ),
                            if (!r.imported)
                              Expanded(
                                child: StatItem(label: tr(context, 'rec.speed'), value: '${fmtNum(context, r.speedKmh, 1)} ${tr(context, 'cond.kmh')}'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(tr(context, r.imported ? 'gpx.note' : 'rec.note'), style: const TextStyle(fontSize: 12.5, color: RS.muted, height: 1.4)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr(context, 'detail.profile').toUpperCase(), style: RS.head(24, color: RS.z9)),
                        const SizedBox(height: 12),
                        _profile.length >= 2
                            ? ElevationChart(profile: _profile)
                            : Text(tr(context, 'rec.no_profile'), style: const TextStyle(color: RS.muted, height: 1.4)),
                      ],
                    ),
                  ),
                ),
                if (r.waypoints.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr(context, 'wpt.list').toUpperCase(), style: RS.head(24, color: RS.z9)),
                          for (final w in r.waypoints)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(waypointKinds[w.kind] ?? Icons.place_outlined, color: RS.z7),
                              title: Text(tr(context, 'wpt.${w.kind}')),
                              subtitle: Text(
                                '${w.time.toLocal().hour.toString().padLeft(2, '0')}.${w.time.toLocal().minute.toString().padLeft(2, '0')}${w.ele != null ? ' · ${fmtNum(context, w.ele)} m' : ''}',
                                style: const TextStyle(color: RS.muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => followInRecord(context, r),
                      icon: const Icon(Icons.radio_button_checked),
                      label: Text(tr(context, 'gpx.follow')),
                    ),
                    FilledButton.icon(onPressed: _share, icon: const Icon(Icons.share), label: Text(tr(context, 'rec.share'))),
                    if (r.points.length >= 2)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReplayScreen(recording: r))),
                        style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                        icon: const Icon(Icons.landscape_outlined, color: RS.z7),
                        label: Text(tr(context, 'replay.open')),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => UploadScreen(recording: r))),
                      style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                      icon: const Icon(Icons.upload_file, color: RS.z7),
                      label: Text(tr(context, r.imported ? 'me.recording.upload' : 'rec.submit')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _rename,
                      style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                      icon: const Icon(Icons.edit_outlined, color: RS.z7),
                      label: Text(tr(context, 'rec.rename')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _delete,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: RS.err,
                        side: const BorderSide(color: RS.err),
                        backgroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(tr(context, 'me.recording.delete')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordingMap extends StatelessWidget {
  const _RecordingMap({required this.recording, this.interactive = false});

  final Recording recording;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final pts = recording.points.map((p) => LatLng(p.lat, p.lng)).toList();
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(32), maxZoom: 17),
        interactionOptions: InteractionOptions(flags: interactive ? InteractiveFlag.all : InteractiveFlag.none),
        backgroundColor: RS.mist,
      ),
      children: [
        const BaseTiles(),
        PolylineLayer(
          polylines: [
            Polyline(points: pts, strokeWidth: 6, color: Colors.white),
            Polyline(points: pts, strokeWidth: 3.5, color: RS.z7),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: pts.first,
              width: 20,
              height: 20,
              child: Container(
                decoration: BoxDecoration(
                  color: RS.z9,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
            for (final w in recording.waypoints)
              Marker(
                point: LatLng(w.lat, w.lng),
                width: 28,
                height: 28,
                rotate: true,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: RS.z9, width: 2),
                  ),
                  child: Icon(waypointKinds[w.kind] ?? Icons.place_outlined, size: 15, color: RS.z9),
                ),
              ),
          ],
        ),
        const OsmAttribution(),
      ],
    );
  }
}

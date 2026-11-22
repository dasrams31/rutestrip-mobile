import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';

/// Routes saved for offline use: the detail JSON from the API in app storage.
/// Map tiles are not downloaded in bulk (OpenStreetMap tile policy); tiles already
/// seen stay in flutter_map's own cache, and the track is drawn either way.
class OfflineStore {
  static Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/offline');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<File> _file(int id) async => File('${(await _dir()).path}/route_$id.json');

  static Future<void> save(Map<String, dynamic> detailJson) async {
    final copy = {...detailJson, '_saved_at': DateTime.now().toIso8601String()};
    await (await _file((detailJson['id'] as num).toInt())).writeAsString(jsonEncode(copy));
  }

  static Future<bool> has(int id) async => (await _file(id)).exists();

  static Future<void> remove(int id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
  }

  static Future<SavedRoute?> load(int id) async {
    final f = await _file(id);
    if (!await f.exists()) return null;
    return SavedRoute.fromJson(jsonDecode(await f.readAsString()) as Map);
  }

  static Future<List<SavedRoute>> all() async {
    final files = (await _dir()).listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final out = <SavedRoute>[];
    for (final f in files) {
      try {
        out.add(SavedRoute.fromJson(jsonDecode(await f.readAsString()) as Map));
      } catch (_) {
        // A broken file is skipped, not shown.
      }
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }
}

class SavedRoute {
  SavedRoute.fromJson(Map j)
    : detail = RouteDetail.fromJson(j),
      savedAt = DateTime.tryParse('${j['_saved_at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0);

  final RouteDetail detail;
  final DateTime savedAt;
}

/// One GPS point of a recording.
class TrackPoint {
  TrackPoint(this.lat, this.lng, this.ele, this.time);

  TrackPoint.fromJson(List j)
    : lat = (j[0] as num).toDouble(),
      lng = (j[1] as num).toDouble(),
      ele = (j[2] as num?)?.toDouble(),
      time = DateTime.fromMillisecondsSinceEpoch((j[3] as num).toInt(), isUtc: true);

  final double lat, lng;
  final double? ele;
  final DateTime time;

  List<Object?> toJson() => [lat, lng, ele, time.millisecondsSinceEpoch];
}

/// A point the hiker marked while recording (pos, water, camp...), saved as a GPX `wpt` element.
class Waypoint {
  Waypoint({required this.lat, required this.lng, required this.ele, required this.time, required this.kind});

  Waypoint.fromJson(Map j)
    : lat = (j['lat'] as num).toDouble(),
      lng = (j['lng'] as num).toDouble(),
      ele = (j['ele'] as num?)?.toDouble(),
      time = DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt(), isUtc: true),
      kind = '${j['kind']}';

  final double lat, lng;
  final double? ele;
  final DateTime time;

  /// pos, water, camp, summit, danger or other (shown translated).
  final String kind;

  Map<String, Object?> toJson() => {'lat': lat, 'lng': lng, 'ele': ele, 't': time.millisecondsSinceEpoch, 'kind': kind};
}

/// A finished GPS recording: points plus a GPX file ready to upload.
class Recording {
  Recording({
    required this.id,
    required this.name,
    required this.startedAt,
    required this.points,
    required this.distanceKm,
    required this.gainM,
    required this.movingSeconds,
    this.waypoints = const [],
    this.imported = false,
    this.segmentStarts = const [0],
  });

  Recording.fromJson(Map j)
    : id = '${j['id']}',
      name = '${j['name']}',
      startedAt = DateTime.parse('${j['started_at']}'),
      points = (j['points'] as List).map((p) => TrackPoint.fromJson(p as List)).toList(),
      distanceKm = (j['distance_km'] as num).toDouble(),
      gainM = (j['gain_m'] as num).toDouble(),
      movingSeconds = (j['seconds'] as num).toInt(),
      waypoints = (j['waypoints'] as List? ?? const []).map((w) => Waypoint.fromJson(w as Map)).toList(),
      imported = j['imported'] == true,
      segmentStarts = (j['segments'] as List? ?? const [0]).map((e) => (e as num).toInt()).toList();

  final String id;
  String name;
  final DateTime startedAt;
  final List<TrackPoint> points;
  final double distanceKm, gainM;
  final int movingSeconds;
  final List<Waypoint> waypoints;

  /// Opened from a GPX file on the phone, not recorded here (no moving time).
  final bool imported;

  /// Index of the first point of each part (a new part starts after a pause or a restored draft).
  final List<int> segmentStarts;

  /// Average speed while moving, km/h.
  double get speedKmh => movingSeconds <= 0 ? 0 : distanceKm / (movingSeconds / 3600);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'started_at': startedAt.toIso8601String(),
    'distance_km': distanceKm,
    'gain_m': gainM,
    'seconds': movingSeconds,
    'points': points.map((p) => p.toJson()).toList(),
    'waypoints': waypoints.map((w) => w.toJson()).toList(),
    'imported': imported,
    'segments': segmentStarts,
  };

  String toGpx() {
    String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="RuteStrip Android" xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata><name>${esc(name)}</name><time>${startedAt.toUtc().toIso8601String()}</time></metadata>');
    for (final w in waypoints) {
      b.write('  <wpt lat="${w.lat.toStringAsFixed(7)}" lon="${w.lng.toStringAsFixed(7)}">');
      if (w.ele != null) b.write('<ele>${w.ele!.toStringAsFixed(1)}</ele>');
      b.writeln('<time>${w.time.toUtc().toIso8601String()}</time><name>${esc(waypointNames[w.kind] ?? w.kind)}</name><type>${esc(w.kind)}</type></wpt>');
    }
    b.writeln('  <trk><name>${esc(name)}</name><trkseg>');
    final breaks = segmentStarts.where((i) => i > 0 && i < points.length).toSet();
    for (final (i, p) in points.indexed) {
      if (breaks.contains(i)) b.writeln('  </trkseg><trkseg>');
      b.write('    <trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lng.toStringAsFixed(7)}">');
      if (p.ele != null) b.write('<ele>${p.ele!.toStringAsFixed(1)}</ele>');
      b.writeln('<time>${p.time.toUtc().toIso8601String()}</time></trkpt>');
    }
    b
      ..writeln('  </trkseg></trk>')
      ..writeln('</gpx>');
    return b.toString();
  }
}

/// Waypoint names written into GPX files (Indonesian, like the website's data).
const waypointNames = {'pos': 'Pos', 'water': 'Sumber air', 'camp': 'Tempat camp', 'summit': 'Puncak', 'danger': 'Bahaya', 'other': 'Penanda'};

class RecordingStore {
  static Future<File> _draftFile() async => File('${(await _dir()).path}/_draft.json');

  /// Draft writes and deletes run one after another, never at the same time.
  static Future<void> _draftQueue = Future.value();

  static Future<void> _queued(Future<void> Function() job) {
    final next = _draftQueue.then((_) => job()).catchError((_) {});
    _draftQueue = next;
    return next;
  }

  /// The recording in progress, written often so a closed or killed app loses at most a few points.
  static Future<void> saveDraft(Map<String, Object?> draft) => _queued(() async {
    final f = await _draftFile();
    final tmp = File('${f.path}.tmp');
    // Long hikes: encode off the UI thread so the map stays smooth on standard phones.
    final long = (draft['points'] as List?)?.length ?? 0;
    final text = long > 1000 ? await compute(jsonEncode, draft) : jsonEncode(draft);
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  });

  static Future<Map<String, dynamic>?> loadDraft() async {
    try {
      final f = await _draftFile();
      if (!await f.exists()) return null;
      return Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearDraft() => _queued(() async {
    final f = await _draftFile();
    if (await f.exists()) await f.delete();
  });

  static Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/recordings');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> save(Recording r) async {
    final d = (await _dir()).path;
    await File('$d/${r.id}.json').writeAsString(jsonEncode(r.toJson()));
    await File('$d/${r.id}.gpx').writeAsString(r.toGpx());
  }

  /// GPX file named after the recording ("merbabu-via-selo-2026-11-22.gpx") for sharing and
  /// upload; written again each time so a renamed recording carries its new name.
  static Future<String> gpxPath(Recording r) async {
    final out = Directory('${(await _dir()).path}/out');
    if (!await out.exists()) await out.create(recursive: true);
    final t = r.startedAt.toLocal();
    final date = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    var slug = r.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.length > 60) slug = slug.substring(0, 60);
    final f = File('${out.path}/${slug.isEmpty ? 'rekaman' : slug}-$date.gpx');
    await f.writeAsString(r.toGpx());
    return f.path;
  }

  static Future<void> remove(String id) async {
    final d = (await _dir()).path;
    for (final ext in ['json', 'gpx']) {
      final f = File('$d/$id.$ext');
      if (await f.exists()) await f.delete();
    }
  }

  static Future<List<Recording>> all() async {
    final files = (await _dir()).listSync().whereType<File>().where((f) => f.path.endsWith('.json') && !f.uri.pathSegments.last.startsWith('_'));
    final out = <Recording>[];
    for (final f in files) {
      try {
        out.add(Recording.fromJson(jsonDecode(await f.readAsString()) as Map));
      } catch (_) {}
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }
}

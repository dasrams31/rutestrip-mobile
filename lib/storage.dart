import 'dart:convert';
import 'dart:io';

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
  });

  Recording.fromJson(Map j)
    : id = '${j['id']}',
      name = '${j['name']}',
      startedAt = DateTime.parse('${j['started_at']}'),
      points = (j['points'] as List).map((p) => TrackPoint.fromJson(p as List)).toList(),
      distanceKm = (j['distance_km'] as num).toDouble(),
      gainM = (j['gain_m'] as num).toDouble(),
      movingSeconds = (j['seconds'] as num).toInt();

  final String id;
  String name;
  final DateTime startedAt;
  final List<TrackPoint> points;
  final double distanceKm, gainM;
  final int movingSeconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'started_at': startedAt.toIso8601String(),
    'distance_km': distanceKm,
    'gain_m': gainM,
    'seconds': movingSeconds,
    'points': points.map((p) => p.toJson()).toList(),
  };

  String toGpx() {
    String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="RuteStrip Android" xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata><name>${esc(name)}</name><time>${startedAt.toUtc().toIso8601String()}</time></metadata>')
      ..writeln('  <trk><name>${esc(name)}</name><trkseg>');
    for (final p in points) {
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

class RecordingStore {
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

  /// Path of the GPX file (written again so a renamed recording carries its new name).
  static Future<String> gpxPath(Recording r) async {
    final f = File('${(await _dir()).path}/${r.id}.gpx');
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
    final files = (await _dir()).listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
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

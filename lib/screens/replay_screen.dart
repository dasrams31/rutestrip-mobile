import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gal/gal.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../i18n.dart';
import '../recording_math.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _page = 'assets/replay/index.html';

/// Opt-in 3D fly-through of a saved recording: MapLibre GL JS (vendored in
/// assets/replay) in a WebView, OSM tiles draped over open Terrarium elevation tiles.
/// Needs internet and WebGL; shows a message and a way back when either is missing.
class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key, required this.recording});

  final Recording recording;

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

enum _Phase { intro, loading, ready, error }

/// Steps of "Simpan video": waiting for the first tiles, recording the fly-through,
/// copying the file out of the page, writing it to the gallery.
enum _Export { prep, rec, transfer, gallery }

/// File name prefix of exported videos in the temp folder (old ones are cleared).
const _videoPrefix = 'RuteStrip_replay_';

class _ReplayScreenState extends State<ReplayScreen> with WidgetsBindingObserver {
  _Phase _phase = _Phase.intro;
  String _error = 'tiles';
  bool _playing = false, _sent = false;
  int _speed = 1;
  WebViewController? _web;
  Timer? _timeout;

  _Export? _export;
  double _exportProgress = 0;
  int _exportRun = 0, _exportChunks = 0;
  File? _exportFile;
  RandomAccessFile? _exportSink;
  String _exportMime = 'video/webm';
  File? _video;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    _dropExportFile();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A hidden WebView stops drawing, so a recording would come out broken.
    if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) && (_export == _Export.prep || _export == _Export.rec)) {
      _cancelExport('background');
    }
  }

  /// Only the bundled replay page may load; links (attribution and so on) open nothing.
  static bool _isLocal(String url) {
    final u = Uri.tryParse(url);
    return u != null && u.scheme == 'file' && u.path.endsWith('/$_page');
  }

  void _start() {
    _timeout?.cancel();
    _sent = false;
    final web = WebViewController()
      // MapLibre GL JS is JavaScript; the page itself is a local asset.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(RS.mist)
      ..addJavaScriptChannel('RS', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) => _isLocal(req.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageFinished: (url) {
            if (_isLocal(url)) _send();
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? false) _fail('data');
          },
        ),
      );
    if (kDebugMode) web.setOnConsoleMessage((m) => debugPrint('replay: ${m.message}'));
    web.loadFlutterAsset(_page);
    _timeout = Timer(const Duration(seconds: 30), () {
      if (_phase == _Phase.loading) _fail('tiles');
    });
    setState(() {
      _web = web;
      _phase = _Phase.loading;
      _playing = false;
    });
  }

  void _send() {
    final web = _web;
    if (_sent || web == null || !mounted) return;
    _sent = true;
    final payload = replayPayload(
      widget.recording,
      lang: AppScope.of(context).lang,
      labels: {'time': tr(context, 'replay.time'), 'dist': tr(context, 'replay.dist'), 'gain': tr(context, 'replay.gain')},
      waypointName: (kind) => tr(context, 'wpt.$kind'),
    );
    // One call with one JSON string argument: recording text never becomes code.
    web.runJavaScript('replayStart(${jsonEncode(jsonEncode(payload))})');
    web.runJavaScript('replayControl("speed", $_speed)');
  }

  void _onMessage(String msg) {
    if (!mounted) return;
    if (msg.startsWith('export:')) {
      _onExport(msg.substring(7));
      return;
    }
    if (msg.startsWith('error:')) return _fail(msg.substring(6));
    setState(() {
      switch (msg) {
        case 'ready':
          _phase = _Phase.ready;
          _timeout?.cancel();
        case 'playing':
          _playing = true;
        case 'paused' || 'ended':
          _playing = false;
      }
    });
  }

  void _fail(String kind) {
    if (!mounted) return;
    _timeout?.cancel();
    _exportRun++;
    _dropExportFile();
    setState(() {
      _export = null;
      _phase = _Phase.error;
      _error = kind == 'webgl' ? 'webgl' : 'tiles';
      _web = null;
    });
  }

  void _control(String cmd, [int? arg]) => _web?.runJavaScript('replayControl(${jsonEncode(cmd)}, ${arg ?? 'null'})');

  // ---- Simpan video: the page records, the app writes the file and saves it ----

  Future<void> _startExport() async {
    final web = _web;
    if (web == null || _export != null || _phase != _Phase.ready) return;
    final run = ++_exportRun;
    final end = tr(context, 'replay.save.endcard');
    setState(() {
      _export = _Export.prep;
      _exportProgress = 0;
    });
    // Leftovers of earlier exports (the gallery keeps its own copy).
    try {
      final tmp = await getTemporaryDirectory();
      await for (final f in tmp.list()) {
        if (f is File && f.uri.pathSegments.last.startsWith(_videoPrefix)) await f.delete();
      }
      _video = null;
    } catch (_) {}
    final logo = (await rootBundle.load('assets/replay/logo.png')).buffer.asUint8List();
    if (!mounted || run != _exportRun) return;
    final opts = {'title': widget.recording.name, 'end': end, 'logo': 'data:image/png;base64,${base64Encode(logo)}'};
    // One JSON string argument, as in _send: recording text never becomes code.
    await web.runJavaScript('replayExport("start", ${jsonEncode(jsonEncode(opts))})');
  }

  void _next() => _web?.runJavaScript('replayExport("next")');

  Future<void> _onExport(String msg) async {
    final run = _exportRun;
    if (_export == null) return;
    if (msg.startsWith('progress:')) {
      final f = double.tryParse(msg.substring(9)) ?? 0;
      setState(() {
        _export = _Export.rec;
        _exportProgress = f * 0.9;
      });
    } else if (msg.startsWith('error:')) {
      _exportFailed(msg.substring(6));
    } else if (msg == 'encoding') {
      setState(() {
        _export = _Export.transfer;
        _exportProgress = 0.9;
      });
    } else if (msg.startsWith('file:')) {
      try {
        final info = jsonDecode(msg.substring(5)) as Map<String, dynamic>;
        final mp4 = info['ext'] == 'mp4';
        _exportMime = mp4 ? 'video/mp4' : 'video/webm';
        _exportChunks = (info['n'] as num).toInt();
        final file = File('${(await getTemporaryDirectory()).path}/${replayVideoName(DateTime.now(), mp4 ? 'mp4' : 'webm')}');
        final sink = await file.open(mode: FileMode.write);
        if (!mounted || run != _exportRun) {
          await sink.close();
          await file.delete();
          return;
        }
        _exportFile = file;
        _exportSink = sink;
        _next();
      } catch (e) {
        if (run == _exportRun) _exportFailed(replayExportErrorKey(e));
      }
    } else if (msg.startsWith('chunk:')) {
      final sink = _exportSink;
      if (sink == null) return;
      try {
        final rest = msg.substring(6);
        final colon = rest.indexOf(':');
        final i = int.parse(rest.substring(0, colon));
        await sink.writeFrom(base64Decode(rest.substring(colon + 1)));
        if (!mounted || run != _exportRun) return;
        setState(() => _exportProgress = 0.9 + 0.08 * (i + 1) / math.max(1, _exportChunks));
        _next();
      } catch (e) {
        if (run == _exportRun) _exportFailed(replayExportErrorKey(e));
      }
    } else if (msg == 'end') {
      await _saveToGallery(run);
    }
  }

  Future<void> _saveToGallery(int run) async {
    final sink = _exportSink, file = _exportFile;
    if (sink == null || file == null) return;
    _exportSink = null;
    setState(() {
      _export = _Export.gallery;
      _exportProgress = 0.98;
    });
    try {
      await sink.close();
      if (!await Gal.hasPermission(toAlbum: true) && !await Gal.requestPermission(toAlbum: true)) {
        throw const _NoPermission();
      }
      await Gal.putVideo(file.path, album: 'RuteStrip');
    } catch (e) {
      if (run == _exportRun) _exportFailed(replayExportErrorKey(e));
      return;
    }
    if (!mounted || run != _exportRun) return;
    _exportFile = null;
    setState(() {
      _export = null;
      _video = file;
    });
    _showSaved();
  }

  void _showSaved() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: RS.z7),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(tr(ctx, 'replay.save.done'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.35)),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        Gal.open().ignore();
                      },
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(tr(ctx, 'replay.save.open')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _shareVideo();
                      },
                      icon: const Icon(Icons.share),
                      label: Text(tr(ctx, 'replay.save.share')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareVideo() async {
    final file = _video;
    if (file == null || !await file.exists()) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: _exportMime)],
        text: widget.recording.name,
      ),
    );
  }

  /// Closes and deletes a half-written export file.
  void _dropExportFile() {
    final sink = _exportSink, file = _exportFile;
    _exportSink = null;
    _exportFile = null;
    if (sink == null && file == null) return;
    () async {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        await file?.delete();
      } catch (_) {}
    }();
  }

  void _cancelExport([String reason = 'cancelled']) {
    if (_export == null) return;
    _web?.runJavaScript('replayExport("cancel")');
    _exportFailed(reason);
  }

  void _exportFailed(String kind) {
    _exportRun++;
    _dropExportFile();
    if (!mounted) return;
    setState(() => _export = null);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr(context, 'replay.save.err.$kind'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RS.paper,
      appBar: AppBar(
        backgroundColor: RS.z9,
        foregroundColor: Colors.white,
        title: Text(
          widget.recording.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: RS.head(24, color: Colors.white),
        ),
      ),
      body: switch (_phase) {
        _Phase.intro => _intro(context),
        _Phase.error => _errorView(context),
        _ => Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (_web != null) Positioned.fill(child: WebViewWidget(controller: _web!)),
                  if (_phase == _Phase.loading)
                    Positioned.fill(
                      child: ColoredBox(
                        color: RS.paper,
                        child: Center(child: LoadingView(label: tr(context, 'replay.loading'))),
                      ),
                    ),
                ],
              ),
            ),
            if (_export == null) _controls(context) else _exportBar(context),
          ],
        ),
      },
    );
  }

  Widget _intro(BuildContext context) {
    return ListView(
      padding: pageGutter(context, top: 20, bottom: 32),
      children: [
        const Icon(Icons.landscape_outlined, color: RS.z7, size: 36),
        const SizedBox(height: 10),
        Text(tr(context, 'replay.open').toUpperCase(), style: RS.head(32, color: RS.z9)),
        const SizedBox(height: 10),
        Text(tr(context, 'replay.intro'), style: const TextStyle(fontSize: 15.5, height: 1.45)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: RS.warnBg,
            border: Border.all(color: RS.warnLine),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.battery_alert_outlined, color: RS.warnInk),
              const SizedBox(width: 10),
              Expanded(
                child: Text(tr(context, 'replay.note'), style: const TextStyle(color: RS.warnInk, height: 1.4)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _start,
          style: FilledButton.styleFrom(backgroundColor: RS.sun, foregroundColor: RS.ink),
          icon: const Icon(Icons.play_arrow),
          label: Text(tr(context, 'replay.start')),
        ),
      ],
    );
  }

  Widget _errorView(BuildContext context) {
    return ListView(
      children: [
        MessageView(
          title: tr(context, 'replay.open'),
          body: tr(context, _error == 'webgl' ? 'replay.err.webgl' : 'replay.err.tiles'),
          icon: _error == 'webgl' ? Icons.videogame_asset_off_outlined : Icons.wifi_off,
          isError: true,
          action: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back), label: Text(tr(context, 'replay.back'))),
              if (_error != 'webgl') OutlinedButton.icon(onPressed: _start, icon: const Icon(Icons.refresh), label: Text(tr(context, 'replay.retry'))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context) {
    final ready = _phase == _Phase.ready;
    return Material(
      color: RS.z9,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            children: [
              IconButton(
                onPressed: ready ? () => _control('restart') : null,
                tooltip: tr(context, 'replay.restart'),
                color: Colors.white,
                disabledColor: Colors.white38,
                icon: const Icon(Icons.replay),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                onPressed: ready ? () => _control(_playing ? 'pause' : 'play') : null,
                tooltip: tr(context, _playing ? 'replay.pause' : 'replay.play'),
                style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: RS.z9, minimumSize: const Size(52, 52)),
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 30),
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: ready ? _startExport : null,
                tooltip: tr(context, 'replay.save'),
                color: Colors.white,
                disabledColor: Colors.white38,
                icon: const Icon(Icons.video_file_outlined),
              ),
              const Spacer(),
              Semantics(
                label: tr(context, 'replay.speed'),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1x')),
                    ButtonSegment(value: 2, label: Text('2x')),
                    ButtonSegment(value: 4, label: Text('4x')),
                  ],
                  selected: {_speed},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) {
                    setState(() => _speed = s.first);
                    _control('speed', _speed);
                  },
                  style: SegmentedButton.styleFrom(
                    foregroundColor: Colors.white,
                    selectedForegroundColor: RS.z9,
                    selectedBackgroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                    textStyle: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _exportBar(BuildContext context) {
    final step = _export!;
    final label = switch (step) {
      _Export.prep => tr(context, 'replay.save.prep'),
      _Export.rec => tr(context, 'replay.save.rec', {'pct': (_exportProgress / 0.9 * 100).round()}),
      _Export.transfer || _Export.gallery => tr(context, 'replay.save.saving'),
    };
    return Material(
      color: RS.z9,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: step == _Export.prep ? null : _exportProgress,
                      semanticsLabel: label,
                      color: RS.sun,
                      backgroundColor: Colors.white24,
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    const SizedBox(height: 6),
                    Text(tr(context, 'replay.save.hint'), style: const TextStyle(color: RS.onDarkSoft, fontSize: 12.5)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: step == _Export.gallery ? null : _cancelExport,
                style: TextButton.styleFrom(foregroundColor: Colors.white, disabledForegroundColor: Colors.white38),
                child: Text(tr(context, 'replay.save.cancel')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoPermission implements Exception {
  const _NoPermission();
}

/// Name of an exported replay video, also the name it gets in the gallery.
String replayVideoName(DateTime t, String ext) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '$_videoPrefix${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.$ext';
}

/// Which `replay.save.err.*` message fits an error from writing or saving the video.
String replayExportErrorKey(Object e) {
  if (e is _NoPermission) return 'permission';
  if (e is GalException) {
    return switch (e.type) {
      GalExceptionType.notEnoughSpace => 'space',
      GalExceptionType.permissionDenied => 'permission',
      _ => 'failed',
    };
  }
  // ENOSPC (Linux, Android); ERROR_HANDLE_DISK_FULL and ERROR_DISK_FULL (Windows).
  if (e is FileSystemException && const [28, 39, 112].contains(e.osError?.errorCode)) return 'space';
  return 'failed';
}

/// What the replay page needs, as plain JSON: at most [maxPoints] track points
/// [lng, lat, ele, seconds since start or null, metres along, metres climbed so far],
/// and marked points with the distance along the track where the replay reaches them.
/// Distance and climb are scaled to match the recording's own totals.
Map<String, Object?> replayPayload(
  Recording r, {
  required String lang,
  required Map<String, String> labels,
  required String Function(String kind) waypointName,
  int maxPoints = 1500,
}) {
  final p = r.points;
  final n = p.length;
  final dist = List<double>.filled(n, 0), gain = List<double>.filled(n, 0);
  double? ref;
  var g = 0.0;
  for (var i = 0; i < n; i++) {
    if (i > 0) dist[i] = dist[i - 1] + distanceM(p[i - 1].lat, p[i - 1].lng, p[i].lat, p[i].lng);
    final e = p[i].ele;
    if (e != null) {
      // Same 3 m step as the GPX import, so GPS noise does not count as climbing.
      if (ref == null || ref - e >= 3) {
        ref = e;
      } else if (e - ref >= 3) {
        g += e - ref;
        ref = e;
      }
    }
    gain[i] = g;
  }
  final dScale = n > 1 && dist[n - 1] > 0 && r.distanceKm > 0 ? r.distanceKm * 1000 / dist[n - 1] : 1.0;
  final gScale = g > 0 && r.gainM > 0 ? r.gainM / g : 1.0;

  bool realTime(DateTime t) => t.isAfter(DateTime.utc(2000, 1, 2));
  final hasTime = n > 1 && realTime(p.first.time) && p.last.time.isAfter(p.first.time);

  double round(double v, int digits) => double.parse(v.toStringAsFixed(digits));

  final step = n <= maxPoints ? 1 : ((n - 1) / (maxPoints - 1)).ceil();
  final idx = [for (var i = 0; i < n; i += step) i];
  if (n > 0 && idx.last != n - 1) idx.add(n - 1);

  final pts = [
    for (final i in idx)
      [
        round(p[i].lng, 6),
        round(p[i].lat, 6),
        p[i].ele == null ? null : round(p[i].ele!, 1),
        hasTime ? p[i].time.difference(p.first.time).inSeconds : null,
        round(dist[i] * dScale, 1),
        round(gain[i] * gScale, 1),
      ],
  ];

  final wpts = <Map<String, Object?>>[];
  if (n > 0) {
    for (final w in r.waypoints) {
      final k = math.cos(w.lat * math.pi / 180);
      var best = 0, bestD = double.infinity;
      for (var i = 0; i < n; i++) {
        final dy = p[i].lat - w.lat, dx = (p[i].lng - w.lng) * k;
        final d = dx * dx + dy * dy;
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      final t = w.time.toLocal();
      wpts.add({
        'name': waypointName(w.kind),
        'lat': round(w.lat, 6),
        'lng': round(w.lng, 6),
        'ele': (w.ele ?? p[best].ele)?.round(),
        'clock': realTime(w.time) ? '${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}' : null,
        'd': round(dist[best] * dScale, 1),
      });
    }
    wpts.sort((a, b) => (a['d'] as double).compareTo(b['d'] as double));
  }

  return {'lang': lang, 'labels': labels, 'hasTime': hasTime, 'pts': pts, 'wpts': wpts};
}

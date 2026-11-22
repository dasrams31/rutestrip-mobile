import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../screens/route_detail_screen.dart';
import '../theme.dart';
import 'trail_map.dart';

/// Text for a failed request; server messages are already in the right language.
String errorText(BuildContext context, Object error) {
  if (error is ApiException) {
    return switch (error.kind) {
      ApiError.network => tr(context, 'error.network'),
      ApiError.notFound => tr(context, 'error.not_found'),
      ApiError.throttled => error.message ?? tr(context, 'error.throttled'),
      ApiError.validation || ApiError.unauthorized || ApiError.forbidden => error.message ?? tr(context, 'error.server'),
      ApiError.server => error.message ?? tr(context, 'error.server'),
    };
  }
  return tr(context, 'error.server');
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 14),
          Text(
            label ?? tr(context, 'state.loading'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: RS.muted, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.title, this.body, this.action, this.icon = Icons.terrain_outlined, this.isError = false});

  final String title;
  final String? body;
  final Widget? action;
  final IconData icon;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isError ? RS.err : RS.z7, size: 28),
              const SizedBox(height: 10),
              Text(title.toUpperCase(), style: RS.head(26, color: RS.z9)),
              if (body != null) ...[const SizedBox(height: 8), Text(body!, style: const TextStyle(color: RS.muted, fontSize: 15, height: 1.45))],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MessageView(
      title: errorText(context, error),
      icon: Icons.error_outline,
      isError: true,
      action: OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: Text(tr(context, 'state.retry'))),
    );
  }
}

/// Difficulty as 1 to 4 emerald bars plus the word (never color alone).
class DifficultyBars extends StatelessWidget {
  const DifficultyBars({super.key, required this.step, required this.label, this.onDark = false});

  final int step;
  final String label;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final on = onDark ? Colors.white : RS.z7;
    final off = onDark ? Colors.white.withValues(alpha: 0.28) : RS.line;
    return Semantics(
      label: '${tr(context, 'stat.difficulty')}: $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 4; i++)
            Container(
              width: 5,
              height: 6.0 + i * 3,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(color: i <= step ? on : off, borderRadius: BorderRadius.circular(1)),
            ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: onDark ? Colors.white : RS.ink),
          ),
        ],
      ),
    );
  }
}

/// The real GPX track as a line (no map tiles, so lists stay light).
class TrackThumb extends StatelessWidget {
  const TrackThumb({super.key, required this.track, this.height = 120});

  final List<List<double>> track;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: RS.mist,
      child: track.length < 2
          ? const Center(child: Icon(Icons.terrain, color: RS.z7, size: 36))
          : CustomPaint(painter: _TrackPainter(track), size: Size.infinite),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter(this.track);

  final List<List<double>> track;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 16.0;
    final lats = track.map((p) => p[0]);
    final lngs = track.map((p) => p[1]);
    final minLat = lats.reduce((a, b) => a < b ? a : b), maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLng = lngs.reduce((a, b) => a < b ? a : b), maxLng = lngs.reduce((a, b) => a > b ? a : b);
    final kx = _cos((minLat + maxLat) / 2);
    final spanX = ((maxLng - minLng) * kx).clamp(1e-6, double.infinity);
    final spanY = (maxLat - minLat).clamp(1e-6, double.infinity);
    final scale = [(size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY].reduce((a, b) => a < b ? a : b);
    final ox = (size.width - spanX * scale) / 2, oy = (size.height - spanY * scale) / 2;
    Offset at(List<double> p) => Offset(ox + (p[1] - minLng) * kx * scale, oy + (maxLat - p[0]) * scale);

    final path = Path()..moveTo(at(track.first).dx, at(track.first).dy);
    for (final p in track.skip(1)) {
      final o = at(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = RS.z7,
    );
    canvas.drawCircle(at(track.first), 5, Paint()..color = RS.z9);
    canvas.drawCircle(at(track.first), 2.5, Paint()..color = Colors.white);
  }

  static double _cos(double deg) => math.cos(deg * math.pi / 180);

  @override
  bool shouldRepaint(_TrackPainter old) => old.track != track;
}

class StatItem extends StatelessWidget {
  const StatItem({super.key, required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: RS.muted, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: RS.head(26, color: RS.z9, weight: FontWeight.w700),
          ),
          if (note != null) ...[const SizedBox(height: 2), Text(note!, style: const TextStyle(fontSize: 12.5, color: RS.muted, height: 1.35))],
        ],
      ),
    );
  }
}

/// A route in a list: track line, rank, match word, difficulty, name, why, four numbers.
class RouteCard extends StatelessWidget {
  const RouteCard({super.key, required this.route, this.rank, this.map = false});

  final RouteSummary route;
  final int? rank;

  /// Real map tiles under the track (search results); lists use the light line drawing.
  final bool map;

  @override
  Widget build(BuildContext context) {
    final r = route;
    final subtitle = [r.mountain != r.name ? r.mountain : null, r.basecamp, r.province].whereType<String>().join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RouteDetailScreen(id: r.id, name: r.name),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                map ? MiniMap(track: r.track) : TrackThumb(track: r.track),
                if (rank != null)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Semantics(
                      label: '${tr(context, 'results.rank')} $rank',
                      excludeSemantics: true,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 40),
                        height: 40,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: RS.z9, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$rank', style: RS.head(24, color: RS.z9)),
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (r.matchLabel != null) _Chip(text: r.matchLabel!, strong: (r.similarity ?? 0) >= 50),
                      DifficultyBars(step: r.difficultyStep, label: r.difficultyLabel),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(r.name.toUpperCase(), style: RS.head(26, color: RS.z9)),
                  if (subtitle.isNotEmpty) ...[const SizedBox(height: 4), Text(subtitle, style: const TextStyle(color: RS.muted, fontSize: 14))],
                  if (r.why != null) ...[const SizedBox(height: 8), Text(r.why!, style: const TextStyle(fontSize: 14.5, height: 1.4))],
                  const Divider(height: 24, color: RS.line),
                  Row(
                    children: [
                      Expanded(
                        child: _MiniStat(label: tr(context, 'stat.distance'), value: '${fmtNum(context, r.distanceKm, 1)} km'),
                      ),
                      Expanded(
                        child: _MiniStat(label: r.durationLabel, value: fmtHours(context, r.hours)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _MiniStat(label: tr(context, 'stat.gain'), value: '${fmtNum(context, r.gainM)} m'),
                      ),
                      Expanded(
                        child: _MiniStat(label: tr(context, 'stat.grade'), value: '${fmtNum(context, r.gradePct, 1)}%'),
                      ),
                    ],
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

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: RS.muted)),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: RS.ink, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.strong});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: strong ? const Color(0xFFD1FAE5) : Colors.white,
        border: Border.all(color: strong ? RS.z7 : RS.edge),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: strong ? RS.z9 : RS.ink),
      ),
    );
  }
}

/// ID | EN switch: two 48dp buttons, the current one filled.
class LangToggle extends StatelessWidget {
  const LangToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    Widget option(String code, String label, String spoken) {
      final on = state.lang == code;
      return Semantics(
        button: true,
        selected: on,
        label: spoken,
        excludeSemantics: true,
        child: InkWell(
          onTap: () => state.setLang(code),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            alignment: Alignment.center,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(6)),
              child: Text(
                label,
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: on ? RS.z9 : Colors.white),
              ),
            ),
          ),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [option('id', 'ID', 'Bahasa Indonesia'), option('en', 'EN', 'English')]);
  }
}

/// Top row inside a header band: back (when possible) or the brand, an optional
/// title, and the language switch. The account lives in the "Saya" tab.
class HeaderBar extends StatelessWidget {
  const HeaderBar({super.key, this.title});

  final String? title;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Row(
      children: [
        if (canPop)
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Image.asset('assets/images/logo.png', width: 30, height: 30, cacheWidth: 90, excludeFromSemantics: true),
                ),
                const SizedBox(width: 8),
                Text('RuteStrip', style: RS.head(26, color: Colors.white)),
              ],
            ),
          ),
        Expanded(
          child: title == null
              ? const SizedBox(height: 48)
              : Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: RS.onDarkSoft, fontWeight: FontWeight.w600, fontSize: 15),
                ),
        ),
        const LangToggle(),
      ],
    );
  }
}

/// Opens a link in the browser or the matching app. Only https (and tel:) links are
/// opened, so a link from a message or the server cannot start anything else.
Future<void> openExternal(String? url) async {
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'tel')) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Side padding that keeps content to a readable column on tablets and landscape.
EdgeInsets pageGutter(BuildContext context, {double top = 0, double bottom = 0, double min = 16, double max = 760}) {
  final w = MediaQuery.sizeOf(context).width;
  final side = w > max + 2 * min ? (w - max) / 2 : min;
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

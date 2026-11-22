import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../i18n.dart';
import '../theme.dart';

/// Elevation profile [[km, m], ...] as a filled line with four labelled heights
/// and the distance axis. Screen readers get one sentence instead of the drawing.
class ElevationChart extends StatelessWidget {
  const ElevationChart({super.key, required this.profile});

  final List<List<double>> profile;

  @override
  Widget build(BuildContext context) {
    final km = profile.last[0];
    final heights = profile.map((p) => p[1]);
    final top = heights.reduce(math.max);
    final sentence = tr(context, 'detail.profile.sr', {'from': fmtNum(context, profile.first[1]), 'top': fmtNum(context, top), 'km': fmtNum(context, km, 1)});
    return Semantics(
      label: sentence,
      excludeSemantics: true,
      child: SizedBox(
        height: 200,
        child: CustomPaint(painter: _ProfilePainter(profile, (v, [d = 0]) => fmtNum(context, v, d)), size: Size.infinite),
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter(this.profile, this.fmt);

  final List<List<double>> profile;
  final String Function(num, [int]) fmt;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 60.0, bottom = 24.0, topPad = 8.0, right = 8.0;
    final w = size.width - left - right, h = size.height - bottom - topPad;
    final maxKm = math.max(profile.last[0], 0.01);
    final rawLo = profile.map((p) => p[1]).reduce(math.min);
    final rawHi = profile.map((p) => p[1]).reduce(math.max);
    // Round height ticks (every 10, 20, 25, 50, 100... m) so the axis reads like a map legend.
    final step = [10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 250.0, 500.0, 1000.0].firstWhere((s) => (rawHi - rawLo) / s <= 4, orElse: () => 1000.0);
    final lo = (rawLo / step).floor() * step;
    final hi = math.max((rawHi / step).ceil() * step, lo + step);

    Offset at(List<double> p) => Offset(left + p[0] / maxKm * w, topPad + (1 - (p[1] - lo) / (hi - lo)) * h);

    final label = TextStyle(color: RS.muted, fontSize: 11, fontFamily: RS.body, fontFeatures: const [FontFeature.tabularFigures()]);
    final grid = Paint()
      ..color = RS.line
      ..strokeWidth = 1;
    for (var v = lo; v <= hi + 0.01; v += step) {
      final y = topPad + (1 - (v - lo) / (hi - lo)) * h;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      _text(canvas, '${fmt(v.round())} m', Offset(0, y - 7), label, left - 6, TextAlign.right);
    }
    for (var i = 0; i <= 4; i++) {
      final x = left + w * i / 4;
      final align = i == 0 ? TextAlign.left : (i == 4 ? TextAlign.right : TextAlign.center);
      final dx = i == 0 ? x : (i == 4 ? x - 60 : x - 30);
      _text(canvas, '${fmt(maxKm * i / 4, maxKm < 5 ? 1 : 0)} km', Offset(dx, size.height - bottom + 6), label, 60, align);
    }

    final line = Path()..moveTo(at(profile.first).dx, at(profile.first).dy);
    for (final p in profile.skip(1)) {
      line.lineTo(at(p).dx, at(p).dy);
    }
    final fill = Path.from(line)
      ..lineTo(at(profile.last).dx, topPad + h)
      ..lineTo(at(profile.first).dx, topPad + h)
      ..close();
    canvas.drawPath(fill, Paint()..color = RS.z7.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..color = RS.z7,
    );
  }

  void _text(Canvas canvas, String s, Offset o, TextStyle style, double width, TextAlign align) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(canvas, o);
  }

  @override
  bool shouldRepaint(_ProfilePainter old) => old.profile != profile;
}

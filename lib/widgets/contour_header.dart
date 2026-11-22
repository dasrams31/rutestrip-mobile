import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// The header band every screen opens with: dark emerald with topographic
/// contour lines, the one place the motif is drawn (DESIGN.md: "Motif").
class ContourHeader extends StatelessWidget {
  const ContourHeader({super.key, required this.child, this.seed = 1, this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 24)});

  final Widget child;
  final int seed;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: RS.z9,
      child: CustomPaint(
        painter: _ContourPainter(seed),
        child: SafeArea(
          bottom: false,
          // Same readable column as the page body on tablets and landscape.
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 792),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stepped rings around two peaks, every fifth ring heavier like an index
/// contour on a printed map. Deterministic per seed, drawn once, no animation.
class _ContourPainter extends CustomPainter {
  _ContourPainter(this.seed);

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed * 7919);
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.09);
    final index = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Colors.white.withValues(alpha: 0.16);

    final peaks = [
      Offset(size.width * (0.78 + rnd.nextDouble() * 0.12), size.height * (0.15 + rnd.nextDouble() * 0.3)),
      Offset(size.width * (0.05 + rnd.nextDouble() * 0.2), size.height * (0.9 + rnd.nextDouble() * 0.3)),
    ];
    final reach = math.max(size.width, size.height) * 1.1;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final (p, peak) in peaks.indexed) {
      final phase = rnd.nextDouble() * math.pi * 2;
      final wobble = 0.10 + rnd.nextDouble() * 0.08;
      final step = 16.0 + p * 4;
      var ring = 0;
      for (var r = 10.0; r < reach; r += step, ring++) {
        final path = Path();
        const n = 72;
        for (var k = 0; k <= n; k++) {
          final a = k / n * math.pi * 2;
          final rr = r * (1 + wobble * math.sin(a * 3 + phase + r / 90) + 0.05 * math.cos(a * 5 - phase));
          final pt = peak + Offset(math.cos(a) * rr * 1.25, math.sin(a) * rr);
          k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        path.close();
        canvas.drawPath(path, ring % 5 == 4 ? index : thin);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ContourPainter old) => old.seed != seed;
}

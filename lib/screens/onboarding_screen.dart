import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';

/// First launch: welcome and a few swipeable slides about what RuteStrip does.
/// Everything said here is a feature that exists in the app.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.replay = false});

  /// Opened again from "Tentang RuteStrip": closes instead of finishing onboarding.
  final bool replay;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  static const _count = 5;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _done() {
    if (widget.replay) {
      Navigator.of(context).maybePop();
    } else {
      AppScope.read(context).finishOnboarding();
    }
  }

  void _next() {
    if (_page == _count - 1) {
      _done();
    } else {
      _pages.nextPage(duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slides = [
      _Slide(title: tr(context, 'onb.1.title'), body: tr(context, 'onb.1.body'), art: const _LogoArt()),
      _Slide(
        title: tr(context, 'onb.2.title'),
        body: tr(context, 'onb.2.body'),
        art: _SearchArt(query: tr(context, 'search.hint').split(': ').last),
      ),
      _Slide(title: tr(context, 'onb.3.title'), body: tr(context, 'onb.3.body'), art: const _NumbersArt()),
      _Slide(
        title: tr(context, 'onb.4.title'),
        body: tr(context, 'onb.4.body'),
        art: const _IconsArt(icons: [Icons.radio_button_checked, Icons.offline_pin, Icons.upload_file]),
      ),
      _Slide(title: tr(context, 'onb.5.title'), body: tr(context, 'onb.5.body'), art: const _ChatArt()),
    ];
    final last = _page == _count - 1;

    return Scaffold(
      backgroundColor: RS.z9,
      body: ContourHeader(
        seed: 2,
        padding: EdgeInsets.zero,
        child: SizedBox.expand(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(
                  children: [
                    ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.asset('assets/images/logo.png', width: 36, height: 36, cacheWidth: 108)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('RuteStrip', style: RS.head(28, color: Colors.white)),
                    ),
                    const LangToggle(),
                    if (!last)
                      TextButton(
                        onPressed: _done,
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        child: Text(tr(context, 'onb.skip')),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(controller: _pages, onPageChanged: (i) => setState(() => _page = i), children: slides),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.paddingOf(context).bottom),
                child: Row(
                  children: [
                    Semantics(
                      label: tr(context, 'onb.page', {'n': _page + 1, 'total': _count}),
                      excludeSemantics: true,
                      child: Row(
                        children: [
                          for (var i = 0; i < _count; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              margin: const EdgeInsets.only(right: 6),
                              width: i == _page ? 22 : 8,
                              height: 8,
                              decoration: BoxDecoration(color: i == _page ? Colors.white : Colors.white38, borderRadius: BorderRadius.circular(4)),
                            ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 150,
                      child: last
                          ? SignButton(label: tr(context, widget.replay ? 'onb.close' : 'onb.start'), onPressed: _next)
                          : FilledButton(
                              onPressed: _next,
                              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: RS.z9, minimumSize: const Size(48, 52)),
                              child: Text(tr(context, 'onb.next')),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Slide extends StatelessWidget {
  const _Slide({required this.title, required this.body, required this.art});

  final String title, body;
  final Widget art;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth > 640;
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(title.toUpperCase(), style: RS.head(wide ? 52 : 42, color: Colors.white)),
            ),
            const SizedBox(height: 12),
            Text(body, style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 16.5, height: 1.5)),
          ],
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight - 32),
            child: wide
                ? Row(
                    children: [
                      Expanded(child: Center(child: art)),
                      const SizedBox(width: 32),
                      Expanded(child: text),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: art),
                      const SizedBox(height: 32),
                      text,
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// White tile the illustrations sit on.
class _Tile extends StatelessWidget {
  const _Tile({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: 280,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: RS.paper,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white24, width: 2),
    ),
    child: child,
  );
}

class _LogoArt extends StatelessWidget {
  const _LogoArt();

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: Image.asset('assets/images/logo.png', width: 148, height: 148, cacheWidth: 444, semanticLabel: 'RuteStrip'),
  );
}

class _SearchArt extends StatelessWidget {
  const _SearchArt({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: _Tile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: RS.edge),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, color: RS.muted, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: RS.ink, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 1; i <= 3; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: RS.z9, width: 2),
                      borderRadius: BorderRadius.circular(6),
                      color: Colors.white,
                    ),
                    child: Text('$i', style: RS.head(18, color: RS.z9)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(color: i == 1 ? RS.z7 : RS.line, borderRadius: BorderRadius.circular(5)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class _NumbersArt extends StatelessWidget {
  const _NumbersArt();

  @override
  Widget build(BuildContext context) => _Tile(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, 'onb.naismith').toUpperCase(), style: RS.head(22, color: RS.z9)),
        const SizedBox(height: 10),
        Text(
          tr(context, 'onb.naismith.rule'),
          style: const TextStyle(color: RS.ink, fontSize: 15, height: 1.45, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 56,
          child: CustomPaint(painter: _RidgePainter(), size: Size.infinite),
        ),
      ],
    ),
  );
}

/// A drawn ridge with a trail line: decoration only, not data.
class _RidgePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final ridge = Path()
      ..moveTo(0, h)
      ..lineTo(w * 0.18, h * 0.62)
      ..lineTo(w * 0.32, h * 0.72)
      ..lineTo(w * 0.55, h * 0.12)
      ..lineTo(w * 0.72, h * 0.48)
      ..lineTo(w * 0.84, h * 0.36)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(ridge, Paint()..color = const Color(0xFFD1FAE5));
    final trail = Path()
      ..moveTo(w * 0.04, h * 0.95)
      ..quadraticBezierTo(w * 0.25, h * 0.7, w * 0.36, h * 0.66)
      ..quadraticBezierTo(w * 0.48, h * 0.4, w * 0.55, h * 0.14);
    canvas.drawPath(
      trail,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = RS.z7,
    );
  }

  @override
  bool shouldRepaint(_RidgePainter old) => false;
}

class _IconsArt extends StatelessWidget {
  const _IconsArt({required this.icons});

  final List<IconData> icons;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: _Tile(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final icon in icons)
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: RS.line),
              ),
              child: Icon(icon, color: RS.z7, size: 32),
            ),
        ],
      ),
    ),
  );
}

class _ChatArt extends StatelessWidget {
  const _ChatArt();

  @override
  Widget build(BuildContext context) {
    Widget bubble(String text, bool mine) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? RS.z7 : Colors.white,
          border: mine ? null : Border.all(color: RS.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: TextStyle(color: mine ? Colors.white : RS.ink, fontSize: 14)),
      ),
    );
    return ExcludeSemantics(
      child: _Tile(
        child: Column(
          children: [bubble(tr(context, 'chat.community'), false), bubble(tr(context, 'onb.chat.me'), true), bubble(tr(context, 'assistant.name'), false)],
        ),
      ),
    );
  }
}

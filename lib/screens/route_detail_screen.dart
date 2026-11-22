import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/elevation_chart.dart';
import '../widgets/trail_map.dart';
import 'login_screen.dart';

/// Route page: the numbers hikers look for first sit in the header, the map right after.
class RouteDetailScreen extends StatefulWidget {
  const RouteDetailScreen({super.key, required this.id, required this.name});

  final int id;
  final String name;

  @override
  State<RouteDetailScreen> createState() => _RouteDetailScreenState();
}

class _RouteDetailScreenState extends State<RouteDetailScreen> {
  Future<RouteDetail>? _future;
  String? _lang;
  bool? _signedIn;
  bool? _liked;
  int? _likes;
  bool _liking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    // Reload on language change (labels) and on sign-in or sign-out (liked state).
    if (_lang != state.lang || _signedIn != state.signedIn) {
      _lang = state.lang;
      _signedIn = state.signedIn;
      _load();
    }
  }

  void _load() {
    _liked = null;
    _likes = null;
    final future = AppScope.read(context).api.route(widget.id);
    setState(() {
      _future = future;
    });
  }

  Future<void> _toggleLike(RouteDetail route) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!state.signedIn) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr(context, 'like.login')),
          action: SnackBarAction(
            label: tr(context, 'like.login.action'),
            textColor: RS.sun,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
          ),
        ),
      );
      return;
    }
    setState(() => _liking = true);
    try {
      final (liked, count) = await state.api.setLike(route.id, !(_liked ?? route.liked));
      if (mounted) {
        setState(() {
          _liked = liked;
          _likes = count;
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.kind == ApiError.unauthorized) await state.signOut();
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(errorText(context, e))));
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<RouteDetail>(
        future: _future,
        builder: (context, snap) {
          final r = snap.data;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(context, r)),
              if (snap.connectionState != ConnectionState.done)
                const SliverToBoxAdapter(child: LoadingView())
              else if (snap.hasError)
                SliverToBoxAdapter(
                  child: ErrorView(error: snap.error!, onRetry: _load),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  sliver: SliverList.list(children: _body(context, r!)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, RouteDetail? r) {
    final place = r == null ? null : [r.mountain != r.name ? r.mountain : null, r.basecamp, r.place].whereType<String>().join(' · ');
    final liked = _liked ?? r?.liked ?? false;
    return ContourHeader(
      seed: widget.id,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HeaderBar(),
          const SizedBox(height: 12),
          if (place != null && place.isNotEmpty) ...[
            Text(
              place,
              style: const TextStyle(color: RS.onDarkSoft, fontWeight: FontWeight.w600, fontSize: 14.5),
            ),
            const SizedBox(height: 6),
          ],
          Semantics(
            header: true,
            child: Text((r?.name ?? widget.name).toUpperCase(), style: RS.head(38, color: Colors.white)),
          ),
          if (r != null) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 16,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DifficultyBars(step: r.difficultyStep, label: r.difficultyLabel, onDark: true),
                OutlinedButton.icon(
                  onPressed: _liking ? null : () => _toggleLike(r),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white70),
                  ),
                  icon: Icon(liked ? Icons.favorite : Icons.favorite_border, color: liked ? const Color(0xFFFCA5A5) : Colors.white),
                  label: Text('${tr(context, liked ? 'like.remove' : 'like.add')} · ${fmtNum(context, _likes ?? r.likes)}'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context, RouteDetail r) {
    final summitM = r.summitPoint?.elevationM ?? r.maxElevationM;
    return [
      // Map first: it is what people check after the numbers.
      Card(
        clipBehavior: Clip.antiAlias,
        child: r.coordinates.length < 2
            ? Padding(
                padding: const EdgeInsets.all(18),
                child: Text(tr(context, 'detail.no_track'), style: const TextStyle(color: RS.muted)),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 260, child: TrailMap(route: r)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: _PointLine(icon: Icons.circle, label: r.basecampPoint?.name ?? tr(context, 'detail.basecamp'), m: r.basecampPoint?.elevationM),
                        ),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MapScreen(route: r))),
                          icon: const Icon(Icons.fullscreen),
                          label: Text(tr(context, 'detail.map.open')),
                        ),
                      ],
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: StatItem(label: tr(context, 'stat.distance'), value: '${fmtNum(context, r.distanceKm, 1)} km'),
                  ),
                  Expanded(
                    child: StatItem(label: r.durationLabel, value: fmtHours(context, r.hours)),
                  ),
                ],
              ),
              if (r.naismithNote != null) ...[
                const SizedBox(height: 6),
                Text(r.naismithNote!, style: const TextStyle(fontSize: 13, color: RS.muted, height: 1.4)),
              ],
              const Divider(height: 28, color: RS.line),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: StatItem(label: tr(context, 'stat.gain'), value: '${fmtNum(context, r.gainM)} m'),
                  ),
                  Expanded(
                    child: StatItem(label: tr(context, 'stat.grade'), value: '${fmtNum(context, r.gradePct, 1)}%'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: r.steepestPct == null
                        ? const SizedBox()
                        : StatItem(label: tr(context, 'stat.steepest'), value: '${fmtNum(context, r.steepestPct, 1)}%'),
                  ),
                  Expanded(
                    child: summitM == null ? const SizedBox() : StatItem(label: tr(context, 'stat.summit'), value: '${fmtNum(context, summitM)} m'),
                  ),
                ],
              ),
              if (r.difficultyHint != null) ...[
                const Divider(height: 28, color: RS.line),
                Text(
                  tr(context, 'stat.difficulty'),
                  style: const TextStyle(fontSize: 13, color: RS.muted, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                DifficultyBars(step: r.difficultyStep, label: r.difficultyLabel),
                const SizedBox(height: 6),
                Text(r.difficultyHint!, style: const TextStyle(fontSize: 14.5, height: 1.4)),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 14),
      _Section(
        title: tr(context, 'detail.profile'),
        child: r.profile.length >= 2
            ? ElevationChart(profile: r.profile)
            : Text(tr(context, 'detail.profile.none'), style: const TextStyle(color: RS.muted, height: 1.4)),
      ),
      if ((r.description ?? r.narrative ?? '').trim().isNotEmpty) ...[
        const SizedBox(height: 14),
        _Section(
          title: tr(context, 'detail.about'),
          child: Text((r.description?.trim().isNotEmpty ?? false) ? r.description! : r.narrative!, style: const TextStyle(fontSize: 15, height: 1.5)),
        ),
      ],
      const SizedBox(height: 14),
      _Section(
        title: tr(context, 'detail.similar'),
        child: r.similar.isEmpty
            ? Text(tr(context, 'detail.similar.none'), style: const TextStyle(color: RS.muted))
            : Column(children: [for (final s in r.similar) _SimilarTile(route: s)]),
      ),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: () => launchUrl(Uri.parse(r.webUrl), mode: LaunchMode.externalApplication),
        icon: const Icon(Icons.open_in_new),
        label: Text(tr(context, 'detail.web')),
      ),
    ];
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(title.toUpperCase(), style: RS.head(24, color: RS.z9)),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _PointLine extends StatelessWidget {
  const _PointLine({required this.icon, required this.label, required this.m});

  final IconData icon;
  final String label;
  final int? m;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 12, color: RS.z9),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            m == null ? label : '$label · ${fmtNum(context, m)} m',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, color: RS.ink, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _SimilarTile extends StatelessWidget {
  const _SimilarTile({required this.route});

  final RouteSummary route;

  @override
  Widget build(BuildContext context) {
    final r = route;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RouteDetailScreen(id: r.id, name: r.name),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 76, height: 64, child: TrackThumb(track: r.track, height: 64)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 3),
                  Text(
                    '${fmtNum(context, r.distanceKm, 1)} km · ${fmtHours(context, r.hours)} · ${r.difficultyLabel}',
                    style: const TextStyle(color: RS.muted, fontSize: 13.5),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: RS.z7),
          ],
        ),
      ),
    );
  }
}

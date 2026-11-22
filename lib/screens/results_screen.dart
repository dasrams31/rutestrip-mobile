import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import '../widgets/trail_map.dart';
import 'route_detail_screen.dart';
import 'routes_screen.dart';

/// Search results with the same plan sentences the website shows above the cards.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.query, this.allRoutes = false});

  final String query;
  final bool allRoutes;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  Future<SearchResult>? _future;
  String? _lang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_lang != state.lang) {
      _lang = state.lang;
      _load();
    }
  }

  void _load() {
    final future = AppScope.read(context).api.search(widget.query, allRoutes: widget.allRoutes)..ignore();
    setState(() {
      _future = future;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<SearchResult>(
        future: _future,
        builder: (context, snap) {
          final data = snap.data;
          final loading = snap.connectionState != ConnectionState.done;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: ContourHeader(
                  seed: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const HeaderBar(),
                      const SizedBox(height: 14),
                      Text(
                        tr(context, 'results.for'),
                        style: const TextStyle(color: RS.onDarkSoft, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Semantics(
                        header: true,
                        child: Text('"${widget.query}"', style: RS.head(38, color: Colors.white)),
                      ),
                      if (!loading && data != null && data.results.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          data.results.length == 1 ? tr(context, 'results.one') : tr(context, 'results.many', {'n': data.results.length}),
                          style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 15.5, height: 1.4),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (loading)
                SliverToBoxAdapter(child: LoadingView(label: tr(context, 'search.busy')))
              else if (snap.hasError)
                SliverToBoxAdapter(
                  child: ErrorView(error: snap.error!, onRetry: _load),
                )
              else if (data!.results.isEmpty)
                SliverToBoxAdapter(
                  child: MessageView(
                    title: tr(context, 'results.empty.title'),
                    body: data.message ?? tr(context, 'results.empty.body'),
                    action: TextButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RoutesScreen())),
                      child: Text(tr(context, 'browse.cta')),
                    ),
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: _Plan(result: data, query: widget.query),
                ),
                SliverToBoxAdapter(child: _Overview(routes: data.results)),
                SliverPadding(
                  padding: pageGutter(context, top: 0, bottom: 32),
                  sliver: SliverList.separated(
                    itemCount: data.results.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, i) => RouteCard(route: data.results[i], rank: i + 1, map: true),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Plan extends StatelessWidget {
  const _Plan({required this.result, required this.query});

  final SearchResult result;
  final String query;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final sort = [r.sortLine, r.alsoLine].whereType<String>().join(' ');
    if (r.filterLine == null && sort.isEmpty && r.notice == null) return const SizedBox(height: 16);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.filterLine != null) ...[
            Text(r.filterLine!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
            if (r.canSearchAll)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ResultsScreen(query: query, allRoutes: true))),
                  child: Text(r.searchAllLabel ?? ''),
                ),
              ),
          ],
          if (sort.isNotEmpty) Text(sort, style: const TextStyle(fontSize: 15, height: 1.4)),
          if (r.notice != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: const BoxDecoration(
                color: RS.warnBg,
                border: Border(left: BorderSide(color: RS.warnLine, width: 4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFFB45309), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(r.notice!, style: const TextStyle(color: RS.warnInk, fontSize: 14, height: 1.4)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

void _openRoute(BuildContext context, RouteSummary r) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => RouteDetailScreen(id: r.id, name: r.name),
  ),
);

/// All results on one map (numbers = rank); "Buka peta penuh" makes it interactive.
class _Overview extends StatelessWidget {
  const _Overview({required this.routes});

  final List<RouteSummary> routes;

  @override
  Widget build(BuildContext context) {
    if (routes.where((r) => r.track.length >= 2).isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: pageGutter(context, bottom: 16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 210,
              child: RepaintBoundary(
                child: ResultsMap(routes: routes, onOpen: (r) => _openRoute(context, r)),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ResultsMapScreen(routes: routes))),
                icon: const Icon(Icons.fullscreen),
                label: Text(tr(context, 'detail.map.open')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsMapScreen extends StatelessWidget {
  const _ResultsMapScreen({required this.routes});

  final List<RouteSummary> routes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: RS.z9,
        foregroundColor: Colors.white,
        title: Text(tr(context, 'detail.map'), style: RS.head(24, color: Colors.white)),
      ),
      body: ResultsMap(routes: routes, interactive: true, onOpen: (r) => _openRoute(context, r)),
    );
  }
}

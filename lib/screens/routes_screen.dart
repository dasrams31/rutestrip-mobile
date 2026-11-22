import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';

/// Every route, by name, with a mountain or province filter and paging on scroll.
class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key});

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  final _routes = <RouteSummary>[];
  final _scroll = ScrollController();
  Filters? _filters;
  String? _mountain, _province, _lang;
  int _page = 0, _lastPage = 1, _total = 0;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _more();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lang = AppScope.of(context).lang;
    if (_lang != lang) {
      _lang = lang;
      _reload();
      AppScope.read(context).api.filters().then((f) {
        if (mounted) setState(() => _filters = f);
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    _routes.clear();
    _page = 0;
    _lastPage = 1;
    _error = null;
    _more();
  }

  Future<void> _more() async {
    if (_loading || _page >= _lastPage) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await AppScope.read(context).api.routes(page: _page + 1, mountain: _mountain, province: _province);
      if (!mounted) return;
      setState(() {
        _routes.addAll(page.routes);
        _page = page.page;
        _lastPage = page.lastPage;
        _total = page.total;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick({required bool mountain}) async {
    final options = mountain ? _filters?.mountains : _filters?.provinces;
    if (options == null) return;
    final current = mountain ? _mountain : _province;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr(context, mountain ? 'browse.mountain' : 'browse.province').toUpperCase(), style: RS.head(28, color: RS.z9)),
            ),
            ListTile(
              minTileHeight: 52,
              title: Text(tr(context, 'browse.all'), style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: current == null ? const Icon(Icons.check, color: RS.z7) : null,
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final o in options)
              ListTile(
                minTileHeight: 52,
                title: Text(o.name),
                subtitle: Text(trailCount(context, o.count)),
                trailing: current == o.name ? const Icon(Icons.check, color: RS.z7) : null,
                onTap: () => Navigator.pop(context, o.name),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      final value = picked.isEmpty ? null : picked;
      if (mountain) {
        _mountain = value;
      } else {
        _province = value;
      }
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final hasFilter = _mountain != null || _province != null;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(
              child: ContourHeader(
                seed: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HeaderBar(),
                    const SizedBox(height: 12),
                    Semantics(
                      header: true,
                      child: Text(tr(context, 'browse.title').toUpperCase(), style: RS.head(42, color: Colors.white)),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _FilterButton(
                          label: tr(context, 'browse.mountain'),
                          value: _mountain ?? tr(context, 'browse.all'),
                          onPressed: _filters == null ? null : () => _pick(mountain: true),
                        ),
                        _FilterButton(
                          label: tr(context, 'browse.province'),
                          value: _province ?? tr(context, 'browse.all'),
                          onPressed: _filters == null ? null : () => _pick(mountain: false),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_routes.isEmpty && _loading)
              const SliverToBoxAdapter(child: LoadingView())
            else if (_routes.isEmpty && _error != null)
              SliverToBoxAdapter(
                child: ErrorView(error: _error!, onRetry: _reload),
              )
            else if (_routes.isEmpty)
              SliverToBoxAdapter(
                child: MessageView(
                  title: tr(context, 'browse.empty'),
                  action: hasFilter
                      ? OutlinedButton(
                          onPressed: () {
                            setState(() => _mountain = _province = null);
                            _reload();
                          },
                          child: Text(tr(context, 'browse.reset')),
                        )
                      : null,
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(trailCount(context, _total), style: const TextStyle(color: RS.muted, fontSize: 14)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                sliver: SliverList.separated(
                  itemCount: _routes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 14),
                  itemBuilder: (context, i) => RouteCard(route: _routes[i]),
                ),
              ),
              SliverToBoxAdapter(
                child: _error != null
                    ? ErrorView(error: _error!, onRetry: _more)
                    : _loading
                    ? LoadingView(label: tr(context, 'browse.more'))
                    : const SizedBox(height: 24),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.label, required this.value, required this.onPressed});

  final String label, value;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: RS.z9,
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.85),
        side: const BorderSide(color: Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w500, color: RS.muted),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

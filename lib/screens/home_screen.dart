import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'results_screen.dart';
import 'routes_screen.dart';
import 'shell.dart';

/// Search by sentence: the one focal point is the search box and its yellow button.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _query = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  Future<Filters>? _filters;
  Future<Dashboard>? _dash;
  String? _filtersLang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_filtersLang != state.lang) {
      _filtersLang = state.lang;
      _filters = state.api.filters()..ignore();
      _dash = state.api.dashboard()..ignore();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search([String? text]) {
    if (text != null) _query.text = text;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(query: _query.text.trim().replaceAll(RegExp(r'\s+'), ' '))));
  }

  @override
  Widget build(BuildContext context) {
    final lang = AppScope.of(context).lang;
    // Shown when /filters cannot load: the website's own example searches.
    final fallbackExamples = lang == 'en'
        ? ['Gentle trail for beginners', 'Short 2-3 hour hike', 'Steep, challenging trail']
        : ['Jalur landai untuk pemula', 'Pendakian singkat 2-3 jam', 'Jalur curam dan menantang'];

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ContourHeader(
            seed: 3,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HeaderBar(),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Semantics(
                      header: true,
                      child: Text(tr(context, 'home.question').toUpperCase(), style: RS.head(44, color: Colors.white)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(tr(context, 'home.lead'), style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 16, height: 1.45)),
                  ),
                  const SizedBox(height: 22),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _query,
                          // Wraps long sentences, but Enter searches instead of adding a new line.
                          keyboardType: TextInputType.text,
                          textInputAction: TextInputAction.search,
                          onFieldSubmitted: (_) => _search(),
                          minLines: 1,
                          maxLines: 3,
                          maxLength: 500,
                          style: const TextStyle(fontSize: 17),
                          decoration: InputDecoration(
                            labelText: tr(context, 'search.label'),
                            hintText: tr(context, 'search.hint'),
                            prefixIcon: const Icon(Icons.search, color: RS.muted),
                            counterText: '',
                          ),
                          validator: (v) => (v ?? '').trim().length < 3 ? tr(context, 'search.too_short') : null,
                        ),
                        const SizedBox(height: 8),
                        SignButton(label: tr(context, 'search.button'), onPressed: _search),
                      ],
                    ),
                  ),
                  // Example searches right under the box: one tap searches.
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      tr(context, 'search.examples'),
                      style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder<Filters>(
                    future: _filters,
                    builder: (context, snap) {
                      final examples = (snap.data?.examples.isNotEmpty ?? false) ? snap.data!.examples : fallbackExamples;
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        child: Row(
                          children: [
                            for (final e in examples)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: OutlinedButton(
                                  onPressed: () => _search(e),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: const BorderSide(color: Color(0x66FFFFFF)),
                                    minimumSize: const Size(0, 44),
                                    padding: const EdgeInsets.symmetric(horizontal: 14),
                                  ),
                                  child: Text(e, style: const TextStyle(fontWeight: FontWeight.w600)),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          FutureBuilder<Filters>(
            future: _filters,
            builder: (context, snap) {
              return Padding(
                padding: pageGutter(context, top: 8, bottom: 32, min: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _RecentSearches(future: _dash, onSearch: _search),
                    const SizedBox(height: 28),
                    _BrowseCard(filters: snap.data, loading: snap.connectionState == ConnectionState.waiting),
                    if (snap.data != null && snap.data!.mountains.isNotEmpty) _Mountains(filters: snap.data!),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Way into the full list; the count is the database total from /filters, hidden while unknown.
class _BrowseCard extends StatelessWidget {
  const _BrowseCard({required this.filters, required this.loading});

  final Filters? filters;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Shell.globalKey.currentState?.open(Tabs.routes),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'browse.cta').toUpperCase(), style: RS.head(26, color: RS.z9)),
                    if (filters != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        tr(context, 'browse.count', {'n': fmtNum(context, filters!.totalRoutes)}),
                        style: const TextStyle(color: RS.muted, fontSize: 14.5, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: RS.z7, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}

/// The signed-in user's last searches (server history), one tap to run again.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.future, required this.onSearch});

  final Future<Dashboard>? future;
  final void Function(String) onSearch;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Dashboard>(
      future: future,
      builder: (context, snap) {
        final recent = snap.data?.recent ?? const <SearchEntry>[];
        if (recent.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, 'dash.recent'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 8),
              for (final h in recent.take(3))
                InkWell(
                  onTap: () => onSearch(h.query),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        const Icon(Icons.history, color: RS.z7, size: 20),
                        const SizedBox(width: 10),
                        Expanded(child: Text(h.query, style: const TextStyle(fontSize: 15))),
                        const Icon(Icons.north_west, color: RS.muted, size: 18),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Mountains with the most trails (counts from the server); opens Jalur filtered.
class _Mountains extends StatelessWidget {
  const _Mountains({required this.filters});

  final Filters filters;

  @override
  Widget build(BuildContext context) {
    final top = [...filters.mountains]..sort((a, b) => b.count.compareTo(a.count));
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr(context, 'home.mountains'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in top.take(8))
                ActionChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: RS.line),
                  label: Text('${m.name.replaceFirst('Gunung ', '')} · ${m.count}'),
                  onPressed: () {
                    routesFilter.value = m.name;
                    Shell.globalKey.currentState?.open(Tabs.routes);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'results_screen.dart';
import 'routes_screen.dart';

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
  String? _filtersLang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_filtersLang != state.lang) {
      _filtersLang = state.lang;
      _filters = state.api.filters();
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
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(query: _query.text.trim())));
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
                ],
              ),
            ),
          ),
          FutureBuilder<Filters>(
            future: _filters,
            builder: (context, snap) {
              final examples = snap.data?.examples ?? fallbackExamples;
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'search.examples'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: RS.ink),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in examples)
                          OutlinedButton(
                            onPressed: () => _search(e),
                            style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                            child: Text(e),
                          ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    _BrowseCard(filters: snap.data, loading: snap.connectionState == ConnectionState.waiting),
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
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RoutesScreen())),
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

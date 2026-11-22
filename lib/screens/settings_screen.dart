import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'onboarding_screen.dart';
import 'results_screen.dart';

/// Header band shared by the account sub-pages.
class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children, this.seed = 40});

  final String title;
  final List<Widget> children;
  final int seed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ContourHeader(
            seed: seed,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                const SizedBox(height: 10),
                Semantics(
                  header: true,
                  child: Text(title.toUpperCase(), style: RS.head(38, color: Colors.white)),
                ),
              ],
            ),
          ),
          Padding(
            padding: pageGutter(context, top: 18, bottom: 32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pengaturan akun: profile, password, language, log out everywhere.
// ---------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _profile = GlobalKey<FormState>();
  final _pass = GlobalKey<FormState>();
  late final _name = TextEditingController(text: AppScope.read(context).user?.name ?? '');
  late final _email = TextEditingController(text: AppScope.read(context).user?.email ?? '');
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _new2 = TextEditingController();
  bool _savingProfile = false, _savingPass = false;
  Map<String, String> _errors = {};

  @override
  void dispose() {
    for (final c in [_name, _email, _current, _new, _new2]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _saveProfile() async {
    setState(() => _errors = {});
    if (!_profile.currentState!.validate()) return;
    setState(() => _savingProfile = true);
    final state = AppScope.read(context);
    try {
      await state.updateUser(await state.api.updateProfile(_name.text.trim(), _email.text.trim()));
      if (mounted) _toast(tr(context, 'set.profile.saved'));
    } on ApiException catch (e) {
      if (mounted) setState(() => _errors = e.fieldErrors);
      if (mounted && e.fieldErrors.isEmpty) _toast(errorText(context, e));
    } catch (e) {
      if (mounted) _toast(errorText(context, e));
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  Future<void> _savePassword() async {
    setState(() => _errors = {});
    if (!_pass.currentState!.validate()) return;
    setState(() => _savingPass = true);
    final state = AppScope.read(context);
    try {
      // The server ends every older token; keep the new one so this phone stays signed in.
      await state.signIn(await state.api.updatePassword(_current.text, _new.text, _new2.text));
      for (final c in [_current, _new, _new2]) {
        c.clear();
      }
      if (mounted) _toast(tr(context, 'set.password.saved'));
    } on ApiException catch (e) {
      if (mounted) setState(() => _errors = e.fieldErrors);
      if (mounted && e.fieldErrors.isEmpty) _toast(errorText(context, e));
    } catch (e) {
      if (mounted) _toast(errorText(context, e));
    } finally {
      if (mounted) setState(() => _savingPass = false);
    }
  }

  Future<void> _logoutEverywhere() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'set.everywhere.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RS.err),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'set.everywhere')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final state = AppScope.read(context);
    final nav = Navigator.of(context);
    try {
      await state.api.logoutEverywhere();
    } catch (_) {
      // Signing out here still happens below.
    }
    nav.popUntil((r) => r.isFirst);
    await state.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    String? req(String? v) => (v ?? '').trim().isEmpty ? tr(context, 'field.required') : null;
    return _Page(
      title: tr(context, 'set.title'),
      children: [
        _Box(
          title: tr(context, 'set.profile'),
          child: Form(
            key: _profile,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 255,
                  decoration: InputDecoration(labelText: tr(context, 'field.name'), errorText: _errors['name'], counterText: ''),
                  validator: req,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(labelText: tr(context, 'field.email'), errorText: _errors['email']),
                  validator: (v) => req(v) ?? (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim()) ? null : tr(context, 'field.email_bad')),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(onPressed: _savingProfile ? null : _saveProfile, child: Text(tr(context, 'set.save'))),
                ),
              ],
            ),
          ),
        ),
        _Box(
          title: tr(context, 'set.password'),
          child: Form(
            key: _pass,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr(context, 'set.password.lead'), style: const TextStyle(color: RS.muted, height: 1.4)),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _current,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(labelText: tr(context, 'set.password.current'), errorText: _errors['current_password']),
                  validator: req,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _new,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(labelText: tr(context, 'set.password.new'), errorText: _errors['password']),
                  validator: (v) => (v ?? '').length < 8 ? tr(context, 'field.password_short') : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _new2,
                  obscureText: true,
                  decoration: InputDecoration(labelText: tr(context, 'field.password2')),
                  validator: (v) => v != _new.text ? tr(context, 'field.password_mismatch') : null,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(onPressed: _savingPass ? null : _savePassword, child: Text(tr(context, 'set.password.save'))),
                ),
              ],
            ),
          ),
        ),
        _Box(
          title: tr(context, 'set.language'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, 'set.language.lead'), style: const TextStyle(color: RS.muted, height: 1.4)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'id', label: Text('Bahasa Indonesia')),
                  ButtonSegment(value: 'en', label: Text('English')),
                ],
                selected: {state.lang},
                onSelectionChanged: (v) => state.setLang(v.first),
                showSelectedIcon: false,
                // Square-ish like the rest of the app (DESIGN.md: no pill shapes).
                style: SegmentedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  selectedBackgroundColor: RS.z7,
                  selectedForegroundColor: Colors.white,
                  minimumSize: const Size(48, 48),
                ),
              ),
            ],
          ),
        ),
        _Box(
          title: tr(context, 'set.security'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(context, 'set.everywhere.lead'), style: const TextStyle(color: RS.muted, height: 1.4)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _logoutEverywhere,
                style: OutlinedButton.styleFrom(
                  foregroundColor: RS.err,
                  side: const BorderSide(color: RS.err),
                ),
                icon: const Icon(Icons.devices_other),
                label: Text(tr(context, 'set.everywhere')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title.toUpperCase(), style: RS.head(24, color: RS.z9)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Riwayat pencarian
// ---------------------------------------------------------------------------

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _items = <SearchEntry>[];
  int _page = 0, _last = 1;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _more());
  }

  Future<void> _more() async {
    if (_loading || _page >= _last) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (items, last) = await AppScope.read(context).api.history(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(items);
        _page++;
        _last = last;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Page(
      title: tr(context, 'hist.title'),
      seed: 44,
      children: [
        if (_items.isEmpty && _loading) const LoadingView(),
        if (_items.isEmpty && _error != null) ErrorView(error: _error!, onRetry: _more),
        if (_items.isEmpty && !_loading && _error == null) Text(tr(context, 'hist.empty'), style: const TextStyle(color: RS.muted, height: 1.4)),
        if (_items.isNotEmpty)
          Card(
            child: Column(
              children: [
                for (final h in _items)
                  ListTile(
                    minTileHeight: 56,
                    leading: const Icon(Icons.history, color: RS.z7),
                    title: Text(h.query),
                    subtitle: Text(
                      '${trailCount(context, h.results)}${h.createdAt != null ? ' · ${h.createdAt!.day}/${h.createdAt!.month}/${h.createdAt!.year}' : ''}',
                      style: const TextStyle(color: RS.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: RS.z7),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(query: h.query))),
                  ),
              ],
            ),
          ),
        if (_page < _last && _items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Center(
              child: _loading ? const CircularProgressIndicator(strokeWidth: 3) : TextButton(onPressed: _more, child: Text(tr(context, 'hist.more'))),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tentang RuteStrip: the intro again, links to the website's other pages, data sources.
// ---------------------------------------------------------------------------

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final links = [
      (Icons.slideshow, 'about.intro', null),
      (Icons.smart_toy_outlined, 'about.webchat', 'https://chat.rutestrip.ai.id'),
      (Icons.fact_check_outlined, 'about.sus', '${Api.baseUrl}/evaluation/sus'),
      (Icons.account_tree_outlined, 'about.architecture', '${Api.baseUrl}/arsitektur'),
      (Icons.article_outlined, 'about.paper', 'https://doi.org/10.32520/stmsi.v15i4.6087'),
      (Icons.send_outlined, 'about.telegram', 'https://t.me/rutestrip_hikingbot'),
      (Icons.language, 'about.website', Api.baseUrl),
    ];
    return _Page(
      title: tr(context, 'about.title'),
      seed: 48,
      children: [
        Row(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.asset('assets/images/logo.png', width: 64, height: 64, cacheWidth: 192)),
            const SizedBox(width: 14),
            Expanded(child: Text(tr(context, 'about.lead'), style: const TextStyle(fontSize: 15, height: 1.45))),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              for (final (icon, key, url) in links)
                ListTile(
                  minTileHeight: 56,
                  leading: Icon(icon, color: RS.z7),
                  title: Text(tr(context, key)),
                  trailing: Icon(url == null ? Icons.chevron_right : Icons.open_in_new, color: RS.z7, size: 20),
                  onTap: () =>
                      url == null ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OnboardingScreen(replay: true))) : openExternal(url),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(tr(context, 'about.data'), style: const TextStyle(fontSize: 13, color: RS.muted, height: 1.5)),
      ],
    );
  }
}

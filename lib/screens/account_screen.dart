import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'route_detail_screen.dart';
import 'upload_screen.dart';

/// "Saya" tab: the account, GPX upload, trails saved on the phone, GPS recordings and likes.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.active});

  final bool active;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Future<List<RouteSummary>>? _likes;
  Future<List<SavedRoute>>? _offline;
  Future<List<Recording>>? _recordings;
  String? _lang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lang = AppScope.of(context).lang;
    if (_lang != lang) {
      _lang = lang;
      _reload();
    }
  }

  @override
  void didUpdateWidget(covariant AccountScreen old) {
    super.didUpdateWidget(old);
    // Coming back to the tab: saved trails and recordings may have changed elsewhere.
    if (widget.active && !old.active) _reload();
  }

  void _reload() {
    final likes = AppScope.read(context).api.likes()..ignore();
    final offline = OfflineStore.all()..ignore();
    final recordings = RecordingStore.all()..ignore();
    setState(() {
      _likes = likes;
      _offline = offline;
      _recordings = recordings;
    });
  }

  Future<void> _deleteRecording(Recording r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, 'me.recording.delete.confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RS.err),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'me.recording.delete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await RecordingStore.remove(r.id);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final user = state.user;
    if (user == null) return const Scaffold();

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ContourHeader(
              seed: 21,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HeaderBar(),
                  const SizedBox(height: 12),
                  Semantics(
                    header: true,
                    child: Text(tr(context, 'account.welcome', {'name': user.name}).toUpperCase(), style: RS.head(38, color: Colors.white)),
                  ),
                  const SizedBox(height: 6),
                  Text(user.email, style: const TextStyle(color: RS.onDarkSoft, fontSize: 15)),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => state.signOut(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white70),
                    ),
                    icon: const Icon(Icons.logout),
                    label: Text(tr(context, 'account.logout')),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UploadScreen()));
                    _reload();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.upload_file, color: RS.z7, size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(tr(context, 'upload.title').toUpperCase(), style: RS.head(24, color: RS.z9)),
                              Text(tr(context, 'me.upload.lead'), style: const TextStyle(color: RS.muted, fontSize: 14)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: RS.z7),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _title(context, 'me.offline'),
            FutureBuilder<List<SavedRoute>>(
              future: _offline,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const LoadingView();
                final list = snap.data ?? const [];
                if (list.isEmpty) return _empty(tr(context, 'me.offline.empty'));
                return _box([
                  for (final s in list)
                    _RouteRow(
                      route: s.detail,
                      trailing: const Icon(Icons.offline_pin, color: RS.z7),
                      onTap: () => _open(s.detail),
                    ),
                ]);
              },
            ),
            _title(context, 'me.recordings'),
            FutureBuilder<List<Recording>>(
              future: _recordings,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const LoadingView();
                final list = snap.data ?? const [];
                if (list.isEmpty) return _empty(tr(context, 'me.recordings.empty'));
                return _box([
                  for (final r in list)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(width: 64, height: 56, child: TrackThumb(track: r.points.map((p) => [p.lat, p.lng]).toList(), height: 56)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                                    Text(
                                      '${fmtNum(context, r.distanceKm, 2)} km · +${fmtNum(context, r.gainM)} m · ${fmtHours(context, r.movingSeconds / 3600)}',
                                      style: const TextStyle(color: RS.muted, fontSize: 13.5),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => _deleteRecording(r),
                                style: TextButton.styleFrom(foregroundColor: RS.err),
                                child: Text(tr(context, 'me.recording.delete')),
                              ),
                              TextButton(
                                onPressed: () async {
                                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UploadScreen(recording: r)));
                                  _reload();
                                },
                                child: Text(tr(context, 'me.recording.upload')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ]);
              },
            ),
            _title(context, 'account.likes'),
            FutureBuilder<List<RouteSummary>>(
              future: _likes,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const LoadingView();
                if (snap.hasError) {
                  final e = snap.error;
                  if (e is ApiException && e.kind == ApiError.unauthorized) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => state.signOut());
                  }
                  return ErrorView(error: e!, onRetry: _reload);
                }
                final list = snap.data!;
                if (list.isEmpty) return _empty(tr(context, 'account.likes.empty'));
                return _box([for (final r in list) _RouteRow(route: r, onTap: () => _open(r))]);
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _open(RouteSummary r) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RouteDetailScreen(id: r.id, name: r.name),
      ),
    );
    _reload();
  }

  Widget _title(BuildContext context, String key) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Semantics(
      header: true,
      child: Text(tr(context, key).toUpperCase(), style: RS.head(26, color: RS.z9)),
    ),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Text(text, style: const TextStyle(color: RS.muted, fontSize: 14.5, height: 1.4)),
  );

  Widget _box(List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(children: children),
      ),
    ),
  );
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({required this.route, required this.onTap, this.trailing});

  final RouteSummary route;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final r = route;
    final track = r is RouteDetail && r.coordinates.length >= 2 ? r.coordinates : r.track;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 64, height: 56, child: TrackThumb(track: track, height: 56)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  Text(
                    '${fmtNum(context, r.distanceKm, 1)} km · ${fmtHours(context, r.hours)} · ${r.difficultyLabel}',
                    style: const TextStyle(color: RS.muted, fontSize: 13.5),
                  ),
                ],
              ),
            ),
            trailing ?? const Icon(Icons.chevron_right, color: RS.z7),
          ],
        ),
      ),
    );
  }
}

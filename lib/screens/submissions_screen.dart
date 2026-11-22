import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'route_detail_screen.dart';

/// Everything this account sent to RuteStrip, with the admin's decision on recordings.
class SubmissionsScreen extends StatefulWidget {
  const SubmissionsScreen({super.key});

  @override
  State<SubmissionsScreen> createState() => _SubmissionsScreenState();
}

class _SubmissionsScreenState extends State<SubmissionsScreen> {
  late Future<List<Submission>> _items = AppScope.read(context).api.submissions();

  Future<void> _reload() async {
    setState(() => _items = AppScope.read(context).api.submissions());
    await _items.catchError((_) => <Submission>[]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            ContourHeader(
              seed: 83,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HeaderBar(),
                  const SizedBox(height: 12),
                  Semantics(
                    header: true,
                    child: Text(tr(context, 'sub.title').toUpperCase(), style: RS.head(40, color: Colors.white)),
                  ),
                  const SizedBox(height: 8),
                  Text(tr(context, 'sub.lead'), style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 15, height: 1.4)),
                ],
              ),
            ),
            FutureBuilder<List<Submission>>(
              future: _items,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const LoadingView();
                if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
                final list = snap.data!;
                if (list.isEmpty) return MessageView(title: tr(context, 'sub.empty'), icon: Icons.inbox_outlined);
                return Padding(
                  padding: pageGutter(context, top: 16, bottom: 32),
                  child: Column(children: [for (final s in list) _SubmissionCard(item: s)]),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SubmissionCard extends StatelessWidget {
  const _SubmissionCard({required this.item});

  final Submission item;

  @override
  Widget build(BuildContext context) {
    final (label, color, bg) = switch (item.status) {
      'pending' => (tr(context, 'sub.pending'), RS.warnInk, const Color(0xFFFFFBEB)),
      'rejected' => (tr(context, 'sub.rejected'), RS.err, const Color(0xFFFEF2F2)),
      _ => (tr(context, 'sub.published'), RS.z7, const Color(0xFFECFDF5)),
    };
    final open = item.status == 'published';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: open
            ? () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RouteDetailScreen(id: item.id, name: item.name),
                ),
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: bg,
                      border: Border.all(color: color),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (item.distanceKm != null) '${fmtNum(context, item.distanceKm, 2)} km',
                  if (item.gainM != null) '+${fmtNum(context, item.gainM)} m',
                  tr(context, item.source == 'recording' ? 'sub.from.recording' : 'sub.from.upload'),
                ].join(' · '),
                style: const TextStyle(color: RS.muted, fontSize: 13.5),
              ),
              if (item.status == 'pending')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(tr(context, 'sub.pending.lead'), style: const TextStyle(fontSize: 13, height: 1.35)),
                ),
              if (item.note != null && item.note!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(tr(context, 'sub.note', {'note': item.note!}), style: const TextStyle(fontSize: 13, height: 1.35, color: RS.err)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

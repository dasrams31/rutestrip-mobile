import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../live_share.dart';
import '../theme.dart';

/// Start, share or stop the live position link.
Future<void> showLiveShareSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => const SafeArea(child: _LiveSheet()),
);

class _LiveSheet extends StatelessWidget {
  const _LiveSheet();

  String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}.${t.minute.toString().padLeft(2, '0')}';

  Future<void> _start(BuildContext context, int hours) async {
    final state = AppScope.read(context);
    try {
      await LiveShare.instance.start(state.api, hours);
      if (context.mounted) await _shareLink(context);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is ApiException && e.message != null ? e.message! : tr(context, 'live.failed'))));
      }
    }
  }

  Future<void> _shareLink(BuildContext context) async {
    final url = LiveShare.instance.url;
    if (url == null) return;
    await SharePlus.instance.share(ShareParams(text: tr(context, 'live.message', {'url': url})));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LiveShare.instance,
      builder: (context, _) {
        final live = LiveShare.instance;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr(context, 'live.title').toUpperCase(), style: RS.head(26, color: RS.z9)),
              const SizedBox(height: 6),
              Text(tr(context, 'live.lead'), style: const TextStyle(height: 1.45, color: RS.ink)),
              const SizedBox(height: 14),
              if (!live.active) ...[
                if (live.busy)
                  const Center(
                    child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final h in const [2, 6, 12, 24])
                        ActionChip(
                          avatar: const Icon(Icons.timer_outlined, size: 18, color: RS.z7),
                          label: Text(tr(context, 'live.hours', {'h': h})),
                          onPressed: () => _start(context, h),
                        ),
                    ],
                  ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, 'live.until', {'t': _clock(live.expiresAt!)}),
                        style: const TextStyle(fontWeight: FontWeight.w700, color: RS.z9),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        live.sentAt == null ? tr(context, 'live.waiting') : tr(context, 'live.sent', {'t': _clock(live.sentAt!)}),
                        style: const TextStyle(color: RS.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(live.url ?? '', style: const TextStyle(fontSize: 13, color: RS.z7)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: live.url ?? ''));
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'live.copied'))));
                        },
                        icon: const Icon(Icons.copy),
                        label: Text(tr(context, 'live.copy')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(onPressed: () => _shareLink(context), icon: const Icon(Icons.share), label: Text(tr(context, 'live.share'))),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: RS.err),
                  onPressed: () => live.stop(),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(tr(context, 'live.stop')),
                ),
              ],
              const SizedBox(height: 6),
              Text(tr(context, 'live.note'), style: const TextStyle(fontSize: 12.5, color: RS.muted)),
            ],
          ),
        );
      },
    );
  }
}

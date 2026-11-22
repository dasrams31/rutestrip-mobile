import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'group_pane.dart';

/// Chat tab: "Obrolan Pendaki" (people) and "Asisten" (AI), switched in the header.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.active});

  /// The tab is on screen (polling only runs then).
  final bool active;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// Set to open a pane from outside (a group notification opens 2).
final chatPane = ValueNotifier<int?>(null);

class _ChatScreenState extends State<ChatScreen> {
  int _pane = 0;

  @override
  void initState() {
    super.initState();
    chatPane.addListener(_onPane);
    _onPane();
  }

  @override
  void dispose() {
    chatPane.removeListener(_onPane);
    super.dispose();
  }

  void _onPane() {
    final p = chatPane.value;
    if (p == null) return;
    chatPane.value = null;
    if (mounted) setState(() => _pane = p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ContourHeader(
            seed: 34,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _PaneButton(label: tr(context, 'chat.community'), selected: _pane == 0, onTap: () => setState(() => _pane = 0)),
                      const SizedBox(width: 8),
                      _PaneButton(label: tr(context, 'chat.assistant'), selected: _pane == 1, onTap: () => setState(() => _pane = 1)),
                      const SizedBox(width: 8),
                      _PaneButton(label: tr(context, 'grp.title'), selected: _pane == 2, onTap: () => setState(() => _pane = 2)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(context, const ['chat.community.lead', 'chat.assistant.lead', 'grp.short'][_pane]),
                  style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 14, height: 1.35),
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _pane,
              children: [
                _CommunityChat(active: widget.active && _pane == 0),
                const _AssistantChat(),
                const GroupPane(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PaneButton extends StatelessWidget {
  const _PaneButton({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            border: Border.all(color: selected ? Colors.white : Colors.white54),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: selected ? RS.z9 : Colors.white),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Obrolan Pendaki
// ---------------------------------------------------------------------------

class _CommunityChat extends StatefulWidget {
  const _CommunityChat({required this.active});

  final bool active;

  @override
  State<_CommunityChat> createState() => _CommunityChatState();
}

class _CommunityChatState extends State<_CommunityChat> with WidgetsBindingObserver {
  static const _poll = Duration(seconds: 5);

  /// The server lists deletions of the last 90 s; after a longer gap the list is loaded again.
  static const _staleAfter = Duration(seconds: 80);

  final _input = TextEditingController();
  final _messages = <ChatMessage>[];
  final _gone = <int>{};
  Timer? _timer;
  int _cursor = 0; // newest id seen from the server (not from our own sends)
  DateTime _polledAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _appVisible = true;
  bool _loading = false, _loadingOlder = false, _sending = false, _hasMore = false, _loaded = false;
  Object? _error;

  @override
  void didUpdateWidget(covariant _CommunityChat old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible = state == AppLifecycleState.resumed;
    _sync();
  }

  /// Load when first shown or after being away long enough to miss deletions;
  /// poll for new messages only while the chat is on screen.
  void _sync() {
    final onScreen = widget.active && _appVisible;
    if (onScreen && !_loading && (!_loaded || DateTime.now().difference(_polledAt) > _staleAfter)) _load();
    if (onScreen && _timer == null) {
      _timer = Timer.periodic(_poll, (_) => _newer());
    } else if (!onScreen) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _seen(Iterable<ChatMessage> ms) {
    for (final m in ms) {
      if (m.id > _cursor) _cursor = m.id;
    }
    _polledAt = DateTime.now();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _input.dispose();
    super.dispose();
  }

  Api get _api => AppScope.read(context).api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.messages();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(page.messages);
        _gone.clear();
        _hasMore = page.hasMore;
        _loaded = true;
      });
      _seen(page.messages);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newer() async {
    if (!_loaded || _loading || !mounted) return;
    try {
      final page = await _api.messages(after: _cursor);
      if (!mounted) return;
      final known = _messages.map((m) => m.id).toSet();
      setState(() {
        _messages
          ..addAll(page.messages.where((m) => !known.contains(m.id)))
          ..sort((a, b) => a.id.compareTo(b.id));
        _gone.addAll(page.deleted);
      });
      _seen(page.messages);
    } catch (_) {
      // Polling stays quiet; the next tick tries again.
    }
  }

  Future<void> _older() async {
    if (_messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final page = await _api.messages(before: _messages.first.id);
      if (!mounted) return;
      setState(() {
        _messages.insertAll(0, page.messages);
        _hasMore = page.hasMore;
      });
    } catch (e) {
      if (mounted) _toast(errorText(context, e));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await _api.sendMessage(text);
      if (!mounted) return;
      setState(() {
        if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
        _input.clear();
      });
    } catch (e) {
      if (mounted) _toast(errorText(context, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _replace(ChatMessage m) {
    final i = _messages.indexWhere((x) => x.id == m.id);
    if (i >= 0) setState(() => _messages[i] = m);
  }

  Future<void> _actions(ChatMessage m) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(minTileHeight: 52, leading: const Icon(Icons.copy), title: Text(tr(context, 'chat.copy')), onTap: () => Navigator.pop(context, 'copy')),
            if (m.canDelete)
              ListTile(
                minTileHeight: 52,
                leading: const Icon(Icons.delete_outline, color: RS.err),
                title: Text(tr(context, 'chat.delete'), style: const TextStyle(color: RS.err)),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            if (m.canReport && !m.reported)
              ListTile(
                minTileHeight: 52,
                leading: const Icon(Icons.flag_outlined),
                title: Text(tr(context, 'chat.report')),
                onTap: () => Navigator.pop(context, 'report'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    try {
      switch (action) {
        case 'copy':
          await Clipboard.setData(ClipboardData(text: m.body ?? ''));
          if (mounted) _toast(tr(context, 'chat.copied'));
        case 'delete':
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              content: Text(tr(context, 'chat.delete.confirm')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr(context, 'chat.cancel'))),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: RS.err),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(tr(context, 'chat.delete')),
                ),
              ],
            ),
          );
          if (ok == true) _replace(await _api.deleteMessage(m.id));
        case 'report':
          _replace(await _api.reportMessage(m.id));
          if (mounted) _toast(tr(context, 'chat.report.done'));
      }
    } catch (e) {
      if (mounted) _toast(errorText(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded && _loading) return const Center(child: LoadingView());
    if (!_loaded && _error != null) {
      return SingleChildScrollView(
        child: ErrorView(error: _error!, onRetry: _load),
      );
    }

    final shown = _messages.reversed.toList();
    return Column(
      children: [
        Expanded(
          child: shown.isEmpty
              ? SingleChildScrollView(
                  child: MessageView(title: tr(context, 'chat.empty'), icon: Icons.forum_outlined),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: shown.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == shown.length) {
                      return Center(
                        child: _loadingOlder
                            ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 3))
                            : TextButton(onPressed: _older, child: Text(tr(context, 'chat.older'))),
                      );
                    }
                    final m = shown[i];
                    final older = i + 1 < shown.length ? shown[i + 1] : null;
                    final newDay = older == null || !_sameDay(older.createdAt, m.createdAt);
                    final sameAuthor = older != null && !newDay && older.name == m.name && older.mine == m.mine;
                    return Column(
                      children: [
                        if (newDay && m.createdAt != null) _DayLabel(date: m.createdAt!),
                        _Bubble(
                          message: m,
                          gone: _gone.contains(m.id) || m.deleted,
                          showName: !m.mine && !sameAuthor,
                          onLongPress: (_gone.contains(m.id) || m.deleted) ? null : () => _actions(m),
                        ),
                      ],
                    );
                  },
                ),
        ),
        _Composer(controller: _input, busy: _sending, onSend: _send, maxLength: 500),
      ],
    );
  }

  static bool _sameDay(DateTime? a, DateTime? b) => a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _DayLabel extends StatelessWidget {
  const _DayLabel({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final en = AppScope.of(context).lang == 'en';
    const id = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
    const eng = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final m = (en ? eng : id)[date.month - 1];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: RS.line.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(6)),
          child: Text(
            en ? '$m ${date.day}, ${date.year}' : '${date.day} $m ${date.year}',
            style: const TextStyle(fontSize: 12.5, color: RS.ink, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.gone, required this.showName, this.onLongPress});

  final ChatMessage message;
  final bool gone, showName;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final mine = m.mine;
    final fg = mine ? Colors.white : RS.ink;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Padding(
          padding: EdgeInsets.only(top: showName ? 10 : 3),
          child: Material(
            color: mine ? RS.z7 : Colors.white,
            shape: RoundedRectangleBorder(
              side: mine ? BorderSide.none : const BorderSide(color: RS.line),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(12),
                topRight: const Radius.circular(12),
                bottomLeft: Radius.circular(mine ? 12 : 4),
                bottomRight: Radius.circular(mine ? 4 : 12),
              ),
            ),
            child: InkWell(
              onLongPress: onLongPress,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showName)
                      Text(
                        m.name,
                        style: const TextStyle(color: RS.z7, fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                    if (gone)
                      Text(
                        tr(context, 'chat.deleted'),
                        style: TextStyle(color: fg.withValues(alpha: 0.85), fontStyle: FontStyle.italic),
                      )
                    else
                      _LinkText(
                        text: m.body ?? '',
                        style: TextStyle(color: fg, fontSize: 15, height: 1.35),
                        linkColor: mine ? Colors.white : RS.z7,
                      ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.reported) ...[
                          Icon(Icons.flag, size: 13, color: mine ? Colors.white : RS.muted),
                          const SizedBox(width: 3),
                          Text(tr(context, 'chat.reported'), style: TextStyle(fontSize: 11.5, color: mine ? Colors.white : RS.muted)),
                          const SizedBox(width: 6),
                        ],
                        if (m.createdAt != null) Text(_clock(m.createdAt!), style: TextStyle(fontSize: 11.5, color: mine ? const Color(0xFFD1FAE5) : RS.muted)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain text with https:// links that open in the browser (same rule as the website).
class _LinkText extends StatelessWidget {
  const _LinkText({required this.text, required this.style, required this.linkColor});

  final String text;
  final TextStyle style;
  final Color linkColor;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in RegExp(r'https://[^\s<>"`]+').allMatches(text)) {
      var url = m.group(0)!;
      final tail = RegExp(r'[.,;:!?)\]]+$').firstMatch(url)?.group(0) ?? '';
      url = url.substring(0, url.length - tail.length);
      spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(color: linkColor, decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
          recognizer: TapGestureRecognizer()..onTap = () => openExternal(url),
        ),
      );
      last = m.end - tail.length;
    }
    spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.busy, required this.onSend, required this.maxLength, this.note});

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;
  final int maxLength;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: RS.line)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 2),
                child: Text(note!, style: const TextStyle(fontSize: 12, color: RS.muted, height: 1.3)),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: maxLength,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: tr(context, 'chat.input'),
                      counterText: '',
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 52,
                  height: 52,
                  child: IconButton.filled(
                    tooltip: tr(context, 'chat.send'),
                    style: IconButton.styleFrom(
                      backgroundColor: RS.z7,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: busy ? null : onSend,
                    icon: busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Icon(Icons.send),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Asisten RuteStrip
// ---------------------------------------------------------------------------

class _AssistantChat extends StatefulWidget {
  const _AssistantChat();

  @override
  State<_AssistantChat> createState() => _AssistantChatState();
}

class _AssistantChatState extends State<_AssistantChat> {
  final _input = TextEditingController();
  final _turns = <({bool user, String text})>[];
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _ask([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    final history = [
      for (final t in _turns) {'role': t.user ? 'user' : 'assistant', 'text': t.text},
    ];
    setState(() {
      _turns.add((user: true, text: text));
      _input.clear();
      _busy = true;
    });
    try {
      final reply = await AppScope.read(context).api.ask(text, history.length > 12 ? history.sublist(history.length - 12) : history);
      if (mounted) setState(() => _turns.add((user: false, text: reply)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _turns.removeLast());
      _input.text = text;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context, e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      _AiBubble(text: tr(context, 'assistant.intro')),
      if (_turns.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final q in [tr(context, 'assistant.q1'), tr(context, 'assistant.q2')])
                OutlinedButton(
                  onPressed: () => _ask(q),
                  style: OutlinedButton.styleFrom(backgroundColor: Colors.white),
                  child: Text(q),
                ),
            ],
          ),
        ),
      for (final t in _turns) t.user ? _UserBubble(text: t.text) : _AiBubble(text: t.text),
      if (_busy)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Semantics(
            liveRegion: true,
            child: Text(
              tr(context, 'assistant.typing'),
              style: const TextStyle(color: RS.muted, fontStyle: FontStyle.italic),
            ),
          ),
        ),
    ];
    return Column(
      children: [
        Expanded(
          child: ListView(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items)],
          ),
        ),
        _Composer(controller: _input, busy: _busy, onSend: _ask, maxLength: 800, note: tr(context, 'assistant.note')),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 10, left: 48),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: const BoxDecoration(
          color: RS.z7,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.35)),
      ),
    );
  }
}

/// Assistant reply: the small markdown the assistant is told to use (**bold**, "- " lists, [text](https://...)).
class _AiBubble extends StatelessWidget {
  const _AiBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 10, right: 32),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: RS.line),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, 'assistant.name'),
              style: const TextStyle(color: RS.z7, fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 2),
            for (final line in text.split('\n'))
              if (line.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: line.trimLeft().startsWith('- ') || line.trimLeft().startsWith('* ')
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('•  ', style: TextStyle(fontSize: 15, height: 1.4, color: RS.z7)),
                            Expanded(child: _md(line.trimLeft().substring(2))),
                          ],
                        )
                      : _md(line),
                ),
          ],
        ),
      ),
    );
  }

  Widget _md(String line) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|\[([^\]]+)\]\((https://[^)\s]+)\)');
    var last = 0;
    for (final m in pattern.allMatches(line)) {
      spans.add(TextSpan(text: line.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else {
        final url = m.group(3)!;
        spans.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(color: RS.z7, decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
            recognizer: TapGestureRecognizer()..onTap = () => openExternal(url),
          ),
        );
      }
      last = m.end;
    }
    spans.add(TextSpan(text: line.substring(last)));
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: RS.ink, fontSize: 15, height: 1.4),
        children: spans,
      ),
    );
  }
}

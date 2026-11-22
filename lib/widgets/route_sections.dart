import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import 'common.dart';

/// A titled card on the route page.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(title.toUpperCase(), style: RS.head(24, color: RS.z9)),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Kondisi terkini: weather at basecamp and summit, sunrise/sunset, safety notes.
// ---------------------------------------------------------------------------

class ConditionsSection extends StatefulWidget {
  const ConditionsSection({super.key, required this.routeId});

  final int routeId;

  @override
  State<ConditionsSection> createState() => _ConditionsSectionState();
}

class _ConditionsSectionState extends State<ConditionsSection> {
  Future<Conditions>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= AppScope.read(context).api.conditions(widget.routeId)..ignore();
  }

  void _retry() => setState(() => _future = AppScope.read(context).api.conditions(widget.routeId)..ignore());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Conditions>(
      future: _future,
      builder: (context, snap) {
        final c = snap.data;
        return Section(
          title: tr(context, 'cond.title'),
          trailing: c?.updated == null ? null : Text(tr(context, 'cond.updated', {'t': c!.updated}), style: const TextStyle(fontSize: 12.5, color: RS.muted)),
          child: switch (snap.connectionState) {
            ConnectionState.done when snap.hasError => Row(
              children: [
                Expanded(
                  child: Text(errorText(context, snap.error!), style: const TextStyle(color: RS.muted)),
                ),
                TextButton(onPressed: _retry, child: Text(tr(context, 'state.retry'))),
              ],
            ),
            ConnectionState.done => _body(context, c!),
            _ => const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
            ),
          },
        );
      },
    );
  }

  Widget _body(BuildContext context, Conditions c) {
    if (c.basecampWeather == null && c.summitWeather == null) {
      return Text(tr(context, 'cond.none'), style: const TextStyle(color: RS.muted, height: 1.4));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final cards = [
              if (c.basecampWeather != null) _WeatherCard(label: tr(context, 'detail.basecamp'), w: c.basecampWeather!),
              if (c.summitWeather != null) _WeatherCard(label: tr(context, 'detail.summit'), w: c.summitWeather!),
            ];
            return box.maxWidth > 420
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final w in cards)
                        Expanded(
                          child: Padding(padding: const EdgeInsets.only(right: 8), child: w),
                        ),
                    ],
                  )
                : Column(
                    children: [for (final w in cards) Padding(padding: const EdgeInsets.only(bottom: 8), child: w)],
                  );
          },
        ),
        if (c.hourlySummit.isNotEmpty || c.hourlyBasecamp.isNotEmpty) ForecastPanel(conditions: c),
        if (c.sunrise != null || c.sunset != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(tr(context, 'cond.sun', {'rise': c.sunrise ?? '-', 'set': c.sunset ?? '-'}), style: const TextStyle(fontSize: 14, color: RS.ink)),
          ),
        if (c.safety.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.caution ? RS.warnBg : const Color(0xFFECFDF5),
              border: Border(left: BorderSide(color: c.caution ? RS.warnLine : RS.z7, width: 4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, c.caution ? 'cond.caution' : 'cond.safety'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: c.caution ? RS.warnInk : RS.z9),
                ),
                for (final m in c.safety)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(m, style: TextStyle(color: c.caution ? RS.warnInk : RS.z9, height: 1.4, fontSize: 14)),
                  ),
              ],
            ),
          ),
        if (c.location != null) ...[
          const SizedBox(height: 10),
          Text('${tr(context, 'cond.location')}: ${c.location}', style: const TextStyle(fontSize: 14, height: 1.4)),
        ],
        if (c.directionsUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => openExternal(c.directionsUrl),
              icon: const Icon(Icons.directions),
              label: Text(tr(context, 'cond.directions')),
            ),
          ),
        Text(tr(context, 'cond.sources'), style: const TextStyle(fontSize: 12, color: RS.muted)),
      ],
    );
  }
}

/// Weather icon and short text from the WMO code, in the app language.
(IconData, String) weatherLook(BuildContext context, int? code, {bool day = true}) {
  final c = code ?? -1;
  if (c == 0 || c == 1) return (day ? Icons.wb_sunny_outlined : Icons.nightlight_outlined, tr(context, c == 0 ? 'wx.clear' : 'wx.mostly_clear'));
  if (c == 2) return (day ? Icons.wb_cloudy_outlined : Icons.nights_stay_outlined, tr(context, 'wx.partly'));
  if (c == 3) return (Icons.cloud_outlined, tr(context, 'wx.overcast'));
  if (c == 45 || c == 48) return (Icons.foggy, tr(context, 'wx.fog'));
  if (c >= 51 && c <= 57) return (Icons.grain, tr(context, 'wx.drizzle'));
  if ((c >= 61 && c <= 67) || (c >= 80 && c <= 82)) return (Icons.water_drop_outlined, tr(context, c >= 65 || c == 82 ? 'wx.heavy_rain' : 'wx.rain'));
  if (c >= 95) return (Icons.thunderstorm_outlined, tr(context, 'wx.storm'));
  if (c >= 71 && c <= 86) return (Icons.ac_unit, tr(context, 'wx.cold'));
  return (Icons.cloud_outlined, '-');
}

const _rainBlue = Color(0xFF1D4ED8);

/// Forecast every few hours (rain chance, temperature, wind) and the daily cycle for
/// the next days, at the basecamp or the summit.
class ForecastPanel extends StatefulWidget {
  const ForecastPanel({super.key, required this.conditions});

  final Conditions conditions;

  @override
  State<ForecastPanel> createState() => _ForecastPanelState();
}

class _ForecastPanelState extends State<ForecastPanel> {
  bool _summit = true;

  String _day(BuildContext context, int offset) => tr(context, offset == 0 ? 'wx.today' : (offset == 1 ? 'wx.tomorrow' : 'wx.after'));

  Widget _slot(BuildContext context, List<ForecastSlot> slots, int i) {
    final s = slots[i];
    final (icon, text) = weatherLook(context, s.code, day: s.isDay);
    final newDay = i > 0 && s.dayOffset != slots[i - 1].dayOffset;
    final wet = (s.rainChance ?? 0) >= 50;
    final label =
        '${_day(context, s.dayOffset)} ${s.hour}, $text, ${s.temperature?.round() ?? '-'}°, '
        '${tr(context, 'wx.rain_chance', {'p': s.rainChance?.round() ?? '-'})}, ${tr(context, 'cond.wind')} ${s.wind?.round() ?? '-'} ${tr(context, 'cond.kmh')}';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        width: 66,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: wet ? const Color(0xFFEFF6FF) : RS.paper,
          border: Border.all(color: newDay ? RS.z7 : (wet ? const Color(0xFFBFDBFE) : RS.line)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              i == 0 ? tr(context, 'wx.now') : (newDay ? _day(context, s.dayOffset) : s.hour),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: newDay ? RS.z7 : RS.muted),
            ),
            if (newDay) Text(s.hour, style: const TextStyle(fontSize: 11, color: RS.muted)),
            const SizedBox(height: 4),
            Icon(icon, size: 22, color: wet ? _rainBlue : RS.z9),
            const SizedBox(height: 2),
            Text(s.temperature == null ? '-' : '${s.temperature!.round()}°', style: RS.head(20, color: RS.z9)),
            const Spacer(),
            Text(
              '${s.rainChance?.round() ?? '-'}%',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: wet ? _rainBlue : RS.muted),
            ),
            Text('${s.wind?.round() ?? '-'} ${tr(context, 'cond.kmh')}', style: const TextStyle(fontSize: 11, color: RS.muted)),
          ],
        ),
      ),
    );
  }

  Widget _dayRow(BuildContext context, ForecastDay d) {
    final (icon, text) = weatherLook(context, d.code);
    final wet = (d.rainChance ?? 0) >= 50;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: RS.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(_day(context, d.dayOffset), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Icon(icon, size: 20, color: wet ? _rainBlue : RS.z9),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                Text(
                  [
                    tr(context, 'wx.rain_chance', {'p': d.rainChance?.round() ?? '-'}),
                    '${tr(context, 'cond.wind')} ${d.wind?.round() ?? '-'} ${tr(context, 'cond.kmh')}',
                    if (d.sunrise != null && d.sunset != null) '${d.sunrise}-${d.sunset}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: wet ? _rainBlue : RS.muted),
                ),
              ],
            ),
          ),
          Text(
            '${d.low?.round() ?? '-'}° / ${d.high?.round() ?? '-'}°',
            style: const TextStyle(fontWeight: FontWeight.w700, color: RS.z9),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conditions;
    final slots = _summit && c.hourlySummit.isNotEmpty ? c.hourlySummit : c.hourlyBasecamp;
    final days = _summit && c.daysSummit.isNotEmpty ? c.daysSummit : c.daysBasecamp;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(tr(context, 'wx.title').toUpperCase(), style: RS.head(22, color: RS.z9)),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: false, label: Text(tr(context, 'detail.basecamp'))),
                  ButtonSegment(value: true, label: Text(tr(context, 'detail.summit'))),
                ],
                selected: {_summit},
                onSelectionChanged: (v) => setState(() => _summit = v.first),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 136,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: slots.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) => _slot(context, slots, i),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr(context, 'wx.legend'), style: const TextStyle(fontSize: 12, color: RS.muted)),
          ),
          if (days.isNotEmpty) ...[const SizedBox(height: 6), for (final d in days) _dayRow(context, d)],
        ],
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard({required this.label, required this.w});

  final String label;
  final Weather w;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      if (w.feels != null) (tr(context, 'cond.feels'), '${fmtNum(context, w.feels)} °C'),
      if (w.wind != null) (tr(context, 'cond.wind'), '${fmtNum(context, w.wind)} ${tr(context, 'cond.kmh')}${w.windFrom != null ? ' · ${w.windFrom}' : ''}'),
      if (w.humidity != null) (tr(context, 'cond.humidity'), '${fmtNum(context, w.humidity)}%'),
      if (w.rain != null) (tr(context, 'cond.rain'), '${fmtNum(context, w.rain, 1)} mm'),
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: RS.paper, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label${w.elevation != null ? ' · ${fmtNum(context, w.elevation)} m' : ''}',
            style: const TextStyle(fontSize: 13, color: RS.muted, fontWeight: FontWeight.w600),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(w.temperature == null ? '-' : '${fmtNum(context, w.temperature)}°', style: RS.head(38, color: RS.z9)),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(w.text ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(k, style: const TextStyle(fontSize: 13, color: RS.muted)),
                  ),
                  Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Info praktis: only the fields the route has.
// ---------------------------------------------------------------------------

class PracticalSection extends StatelessWidget {
  const PracticalSection({super.key, required this.info});

  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    if (info.isEmpty) return const SizedBox.shrink();
    final lat = info['basecamp_lat'], lng = info['basecamp_lng'];
    final fee = info['entry_fee'];
    Widget item(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: RS.muted, fontWeight: FontWeight.w600),
          ),
          Text(value, style: const TextStyle(fontSize: 15, height: 1.4)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Section(
        title: tr(context, 'prac.title'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (info['basecamp_name'] != null)
              item(tr(context, 'detail.basecamp'), [info['basecamp_name'], info['basecamp_address']].whereType<String>().join(', ')),
            if (lat is num && lng is num)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => openExternal('https://www.google.com/maps?q=$lat,$lng'),
                  icon: const Icon(Icons.place_outlined),
                  label: Text(tr(context, 'prac.maps')),
                ),
              ),
            if (info['contact_phone'] != null) item(tr(context, 'prac.contact'), '${info['contact_phone']}'),
            if (fee is num) item(tr(context, 'prac.fee'), 'Rp ${fmtNum(context, fee)}'),
            if (info['best_season'] != null) item(tr(context, 'prac.season'), '${info['best_season']}'),
            if (info['facilities'] != null) item(tr(context, 'prac.facilities'), '${info['facilities']}'),
            if (info['tips'] != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: RS.mist, borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'prac.tips'),
                      style: const TextStyle(fontWeight: FontWeight.w700, color: RS.z9),
                    ),
                    const SizedBox(height: 4),
                    Text('${info['tips']}', style: const TextStyle(height: 1.45)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ulasan pendaki: rating summary, latest reviews, and the form.
// ---------------------------------------------------------------------------

class ReviewsSection extends StatefulWidget {
  const ReviewsSection({super.key, required this.routeId, this.offline = false});

  final int routeId;
  final bool offline;

  @override
  State<ReviewsSection> createState() => _ReviewsSectionState();
}

class _ReviewsSectionState extends State<ReviewsSection> {
  Future<Reviews>? _future;
  final _comment = TextEditingController();
  int _rating = 0;
  bool _sending = false, _showAll = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.offline) _future ??= AppScope.read(context).api.reviews(widget.routeId)..ignore();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_rating == 0) {
      setState(() => _error = tr(context, 'rev.need_rating'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final r = await AppScope.read(context).api.writeReview(widget.routeId, _rating, _comment.text);
      if (!mounted) return;
      _comment.clear();
      setState(() {
        _future = Future.value(r);
        _rating = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'rev.sent'))));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(context, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.offline) return const SizedBox.shrink();
    return FutureBuilder<Reviews>(
      future: _future,
      builder: (context, snap) {
        final r = snap.data;
        return Section(
          title: tr(context, 'rev.title'),
          trailing: r == null || r.count == 0
              ? null
              : Text(
                  '${fmtNum(context, r.average, 1)} / 5 · ${tr(context, r.count == 1 ? 'rev.one' : 'rev.many', {'n': r.count})}',
                  style: const TextStyle(fontSize: 13.5, color: RS.muted),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (snap.connectionState != ConnectionState.done)
                const Center(child: CircularProgressIndicator(strokeWidth: 3))
              else if (snap.hasError)
                Text(errorText(context, snap.error!), style: const TextStyle(color: RS.muted))
              else if (r!.items.isEmpty)
                Text(tr(context, 'rev.empty'), style: const TextStyle(color: RS.muted, height: 1.4))
              else ...[
                for (final item in _showAll ? r.items : r.items.take(3)) _ReviewTile(review: item),
                if (r.items.length > 3 && !_showAll)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: () => setState(() => _showAll = true), child: Text(tr(context, 'rev.more', {'n': r.items.length - 3}))),
                  ),
              ],
              const Divider(height: 28, color: RS.line),
              Text(tr(context, r?.mine != null ? 'rev.yours' : 'rev.your_rating'), style: const TextStyle(fontWeight: FontWeight.w700)),
              if (r?.mine != null) Text(tr(context, 'rev.current', {'n': r!.mine}), style: const TextStyle(color: RS.muted, fontSize: 13)),
              Row(
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      tooltip: tr(context, 'rev.stars', {'n': i}),
                      onPressed: _sending ? null : () => setState(() => _rating = i),
                      icon: Icon(i <= _rating ? Icons.star : Icons.star_border, color: i <= _rating ? const Color(0xFFB45309) : RS.edge, size: 30),
                    ),
                ],
              ),
              TextField(
                controller: _comment,
                maxLength: 1000,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(hintText: tr(context, 'rev.hint'), counterText: ''),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!, style: const TextStyle(color: RS.err)),
                ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: _sending ? null : _send, child: Text(tr(context, _sending ? 'rev.sending' : 'rev.send'))),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.review});

  final Review review;

  @override
  Widget build(BuildContext context) {
    final r = review;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: RS.paper, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (r.rating != null)
                Semantics(
                  label: tr(context, 'rev.stars', {'n': r.rating}),
                  excludeSemantics: true,
                  child: Row(
                    children: [for (var i = 1; i <= 5; i++) Icon(i <= r.rating! ? Icons.star : Icons.star_border, size: 16, color: const Color(0xFFB45309))],
                  ),
                ),
            ],
          ),
          if (r.createdAt != null)
            Text('${r.createdAt!.day}/${r.createdAt!.month}/${r.createdAt!.year}', style: const TextStyle(fontSize: 12, color: RS.muted)),
          if (r.comment != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(r.comment!, style: const TextStyle(height: 1.4)),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data file GPX: versions with fingerprints, folded like the website's <details>.
// ---------------------------------------------------------------------------

class VersionsSection extends StatefulWidget {
  const VersionsSection({super.key, required this.routeId});

  final int routeId;

  @override
  State<VersionsSection> createState() => _VersionsSectionState();
}

class _VersionsSectionState extends State<VersionsSection> {
  bool _open = false, _loading = false;
  List<GpxVersionInfo>? _list;
  Object? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await AppScope.read(context).api.versions(widget.routeId);
      if (mounted) setState(() => _list = list);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open && _list == null && !_loading) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr(context, 'gpx.title').toUpperCase(), style: RS.head(22, color: RS.z9)),
                          Text(tr(context, 'gpx.lead'), style: const TextStyle(fontSize: 13, color: RS.muted)),
                        ],
                      ),
                    ),
                    Icon(_open ? Icons.expand_less : Icons.expand_more, color: RS.z9),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: _loading
                  ? const Center(
                      child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 3)),
                    )
                  : _error != null
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(errorText(context, _error!), style: const TextStyle(color: RS.muted)),
                        ),
                        TextButton(onPressed: _load, child: Text(tr(context, 'state.retry'))),
                      ],
                    )
                  : (_list ?? const []).isEmpty
                  ? Text(tr(context, 'gpx.none'), style: const TextStyle(color: RS.muted))
                  : Column(children: [for (final v in _list!) _VersionTile(v: v)]),
            ),
        ],
      ),
    );
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({required this.v});

  final GpxVersionInfo v;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RS.paper,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: v.active ? RS.z9 : RS.line, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('v${v.version}', style: RS.head(22, color: RS.z9)),
              if (v.active) _Chip(tr(context, 'gpx.active'), ok: true),
              _Chip(tr(context, 'gpx.status.${v.status ?? 'unknown'}'), ok: v.status == 'verified'),
            ],
          ),
          Text(
            '${v.uploader}${v.createdAt != null ? ' · ${v.createdAt!.day}/${v.createdAt!.month}/${v.createdAt!.year}' : ''}',
            style: const TextStyle(fontSize: 13, color: RS.muted),
          ),
          if (v.changeLog != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(v.changeLog!, style: const TextStyle(fontSize: 14)),
            ),
          const SizedBox(height: 4),
          Text(
            '${tr(context, 'gpx.hash')}: ${v.hash.length > 16 ? '${v.hash.substring(0, 16)}...' : v.hash}',
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace', color: RS.ink),
          ),
          if (v.downloadUrl != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => openExternal(v.downloadUrl),
              icon: const Icon(Icons.download),
              label: Text(tr(context, 'gpx.download')),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {required this.ok});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: ok ? const Color(0xFFD1FAE5) : RS.warnBg,
      border: Border.all(color: ok ? RS.z7 : RS.warnLine),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ok ? RS.z9 : RS.warnInk),
    ),
  );
}

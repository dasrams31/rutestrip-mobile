import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../storage.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';
import 'route_detail_screen.dart';

/// Upload one GPX (picked from the phone or from a GPS recording) to RuteStrip.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key, this.recording});

  final Recording? recording;

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.recording?.name ?? '');
  final _notes = TextEditingController();
  String? _path, _fileName, _error, _fileError;
  bool _clean = true, _busy = false;
  RouteSummary? _done;
  String? _doneMessage;

  @override
  void initState() {
    super.initState();
    if (widget.recording != null) {
      RecordingStore.gpxPath(widget.recording!).then((p) {
        if (mounted) {
          setState(() {
            _path = p;
            _fileName = '${widget.recording!.name}.gpx';
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    final file = files.isEmpty ? null : files.single;
    if (file == null || file.path == null) return;
    final ok = RegExp(r'\.(gpx|xml)$', caseSensitive: false).hasMatch(file.name);
    setState(() {
      _fileError = ok ? null : tr(context, 'upload.file_bad');
      if (ok) {
        _path = file.path;
        _fileName = file.name;
        if (_name.text.trim().isEmpty) {
          // Same as the website: the trail name starts from the file name.
          _name.text = file.name.replaceAll(RegExp(r'\.(gpx|xml)$', caseSensitive: false), '').replaceAll(RegExp(r'[_-]+'), ' ').trim();
        }
      }
    });
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _fileError = _path == null ? tr(context, 'upload.file_needed') : null;
    });
    if (!_form.currentState!.validate() || _path == null) return;
    setState(() => _busy = true);
    try {
      final (route, message) = await AppScope.read(context).api.upload(name: _name.text.trim(), description: _notes.text, path: _path!, cleanTrack: _clean);
      if (mounted) {
        setState(() {
          _done = route;
          _doneMessage = message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(context, e);
          if (e is ApiException && e.fieldErrors['gpx_file'] != null) _fileError = e.fieldErrors['gpx_file'];
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ContourHeader(
            seed: 77,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                const SizedBox(height: 12),
                Semantics(
                  header: true,
                  child: Text(tr(context, 'upload.title').toUpperCase(), style: RS.head(40, color: Colors.white)),
                ),
                const SizedBox(height: 8),
                Text(tr(context, 'upload.lead'), style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 15, height: 1.4)),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 32), child: _done != null ? _success(context) : _formView(context)),
        ],
      ),
    );
  }

  Widget _success(BuildContext context) {
    final r = _done!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MessageView(title: r.name, body: _doneMessage, icon: Icons.check_circle_outline),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: FilledButton(
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => RouteDetailScreen(id: r.id, name: r.name),
              ),
            ),
            child: Text(tr(context, 'upload.open')),
          ),
        ),
      ],
    );
  }

  Widget _formView(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF2F2),
                  border: Border(left: BorderSide(color: RS.err, width: 4)),
                ),
                child: Text(_error!, style: const TextStyle(color: Color(0xFF7F1D1D), height: 1.4)),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(tr(context, 'upload.file'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          // Dashed-route feel of the website's drop box is kept simple here: a bordered row.
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _fileError != null ? RS.err : RS.edge),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.route, color: RS.z7),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.recording != null && _path != null
                        ? tr(context, 'upload.from_recording', {'name': widget.recording!.name})
                        : (_fileName ?? tr(context, 'upload.none')),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _fileName == null ? RS.muted : RS.ink, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.recording == null)
                  TextButton(onPressed: _busy ? null : _pick, child: Text(tr(context, _path == null ? 'upload.pick' : 'upload.change'))),
              ],
            ),
          ),
          if (_fileError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12),
              child: Text(_fileError!, style: const TextStyle(color: RS.err, fontSize: 12.5)),
            ),
          const SizedBox(height: 18),
          TextFormField(
            controller: _name,
            maxLength: 255,
            decoration: InputDecoration(labelText: tr(context, 'upload.name'), hintText: tr(context, 'upload.name.hint'), counterText: ''),
            validator: (v) => (v ?? '').trim().isEmpty ? tr(context, 'field.required') : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            decoration: InputDecoration(labelText: tr(context, 'upload.description'), counterText: ''),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _clean,
            onChanged: _busy ? null : (v) => setState(() => _clean = v),
            activeThumbColor: RS.z7,
            title: Text(tr(context, 'upload.clean'), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr(context, 'upload.clean.hint'), style: const TextStyle(color: RS.muted)),
          ),
          const SizedBox(height: 14),
          SignButton(label: tr(context, 'upload.button'), busy: _busy, busyLabel: tr(context, 'upload.busy'), onPressed: _submit),
        ],
      ),
    );
  }
}

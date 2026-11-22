import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../i18n.dart';
import '../mesh/mesh_protocol.dart';
import '../theme.dart';

/// What a group QR carries: the code and the group's name.
class GroupInvite {
  const GroupInvite(this.code, this.name);

  final String code, name;

  static const prefix = 'rutestrip-group:';

  String encode() => '$prefix$code:$name';

  /// Accepts only our own format with a valid code; anything else is ignored.
  static GroupInvite? parse(String? raw) {
    if (raw == null || !raw.startsWith(prefix)) return null;
    final rest = raw.substring(prefix.length);
    final cut = rest.indexOf(':');
    final code = MeshProtocol.normalizeCode(cut < 0 ? rest : rest.substring(0, cut));
    if (code == null) return null;
    var name = cut < 0 ? '' : rest.substring(cut + 1).trim();
    if (name.length > 40) name = name.substring(0, 40);
    return GroupInvite(code, name);
  }
}

/// Camera view that returns the first RuteStrip group QR it sees.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _camera = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false, _wrong = false;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final invite = GroupInvite.parse(b.rawValue);
      if (invite != null) {
        _done = true;
        Navigator.pop(context, invite);
        return;
      }
    }
    if (!_wrong) setState(() => _wrong = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(tr(context, 'grp.qr.scan'))),
      body: Stack(
        children: [
          MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr(context, 'grp.qr.camera'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          if (_wrong)
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: RS.err, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  tr(context, 'grp.qr.bad'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

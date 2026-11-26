import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gal/gal.dart';
import 'package:rutestrip/i18n.dart';
import 'package:rutestrip/screens/replay_screen.dart';

GalException _gal(GalExceptionType t) => GalException(
  type: t,
  platformException: PlatformException(code: t.code),
  stackTrace: StackTrace.empty,
);

void main() {
  test('video names sort by time and keep the extension', () {
    expect(replayVideoName(DateTime(2026, 3, 4, 5, 6, 7), 'webm'), 'RuteStrip_replay_20260304_050607.webm');
    expect(replayVideoName(DateTime(2026, 11, 26, 14, 30, 59), 'mp4'), 'RuteStrip_replay_20261126_143059.mp4');
  });

  test('storage, permission and other errors get their own message', () {
    expect(replayExportErrorKey(_gal(GalExceptionType.notEnoughSpace)), 'space');
    expect(replayExportErrorKey(_gal(GalExceptionType.permissionDenied)), 'permission');
    expect(replayExportErrorKey(_gal(GalExceptionType.notSupportedFormat)), 'failed');
    expect(replayExportErrorKey(const FileSystemException('write', 'x', OSError('No space left on device', 28))), 'space');
    expect(replayExportErrorKey(const FileSystemException('write', 'x', OSError('Permission denied', 13))), 'failed');
    expect(replayExportErrorKey(const FormatException('bad base64')), 'failed');
  });

  test('every export message exists in both languages', () {
    final keys = [
      'replay.save',
      'replay.save.prep',
      'replay.save.rec',
      'replay.save.saving',
      'replay.save.hint',
      'replay.save.cancel',
      'replay.save.endcard',
      'replay.save.done',
      'replay.save.share',
      'replay.save.open',
      for (final k in ['cancelled', 'background', 'unsupported', 'space', 'permission', 'failed']) 'replay.save.err.$k',
    ];
    for (final k in keys) {
      for (final lang in ['id', 'en']) {
        expect(trLang(lang, k), isNot(k), reason: '$k ($lang)');
      }
    }
    expect(trLang('id', 'replay.save.rec', {'pct': 42}), contains('42%'));
  });
}

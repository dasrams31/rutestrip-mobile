import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'i18n.dart';

/// Phone notifications for the offline group (messages, team call, SOS) and the SOS siren.
/// The recording and group "running" notifications come from the location service.
class Notify {
  Notify._();

  static final instance = Notify._();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _siren = AudioPlayer();
  bool _ready = false, sirenOn = false;
  String lang = 'id';
  int _id = 100;

  /// Called when the hiker taps one of our notifications.
  void Function(String payload)? onTap;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => onTap?.call(r.payload ?? ''),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(AndroidNotificationChannel('group', trLang(lang, 'notif.ch.group'), importance: Importance.high));
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          'sos',
          trLang(lang, 'notif.ch.sos'),
          importance: Importance.max,
          sound: const RawResourceAndroidNotificationSound('siren'),
          vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]),
          enableVibration: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
        ),
      );
    } catch (_) {
      // Notifications are a convenience: the app works without them.
    }
  }

  bool get _background => WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  /// Group chat or a marked spot: only when the app is not on screen.
  Future<void> groupMessage(String title, String body) async {
    if (!_background) return;
    await _show('group', title, body, 'group');
  }

  /// Team call: always, with a short siren.
  Future<void> ping(String title, String body) async {
    await _show('group', title, body, 'group');
    await playSiren(loop: false);
  }

  /// SOS: always, with the siren looping until someone silences it.
  Future<void> sos(String title, String body) async {
    await _show('sos', title, body, 'sos');
    await playSiren(loop: true);
  }

  Future<void> _show(String channel, String title, String body, String payload) async {
    if (!_ready) await init();
    try {
      await _plugin.show(
        id: _id++,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel,
            trLang(lang, channel == 'sos' ? 'notif.ch.sos' : 'notif.ch.group'),
            importance: channel == 'sos' ? Importance.max : Importance.high,
            priority: channel == 'sos' ? Priority.max : Priority.high,
            category: channel == 'sos' ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.message,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
        payload: payload,
      );
    } catch (_) {}
  }

  /// The siren plays as an alarm sound, so it is heard with media volume down.
  Future<void> playSiren({required bool loop}) async {
    try {
      await _siren.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.alarm,
            contentType: AndroidContentType.sonification,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
      await _siren.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
      sirenOn = loop;
      await _siren.play(AssetSource('sounds/siren.wav'));
    } catch (_) {}
  }

  Future<void> stopSiren() async {
    sirenOn = false;
    try {
      await _siren.stop();
    } catch (_) {}
  }
}

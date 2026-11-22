import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// App-wide state: language, onboarding, the signed-in user and the API client.
class AppState extends ChangeNotifier {
  AppState(this.api) {
    api.onUnauthorized = () {
      if (user == null) return;
      if (recording) {
        // Never end a hike's recording: drop the token, say so, sign out once it is finished.
        api.token = null;
        sessionExpired = true;
        notifyListeners();
      } else {
        signOut();
      }
    };
  }

  /// A GPS recording is running (set by the Rekam tab). Signing out waits for it.
  bool recording = false;

  /// The server rejected the token while recording; the user signs in again afterwards.
  bool sessionExpired = false;

  /// Closes screens opened over the tabs when the user is signed out (set in main).
  void Function()? onSignedOut;

  void setRecording(bool value) {
    if (recording == value) return;
    recording = value;
    if (!value && sessionExpired) signOut();
  }

  final Api api;
  final _secure = const FlutterSecureStorage();

  String lang = 'id';
  AppUser? user;
  bool ready = false;
  bool onboarded = true;

  bool get signedIn => user != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    lang = prefs.getString('lang') ?? 'id';
    onboarded = prefs.getBool('onboarded') ?? false;
    api.lang = lang;
    try {
      final token = await _secure.read(key: 'sso_token');
      final cached = await _secure.read(key: 'sso_user');
      if (token != null) {
        api.token = token;
        // Start signed in with the saved profile, so the app also opens without signal.
        if (cached != null) user = AppUser.fromJson(jsonDecode(cached) as Map);
        try {
          user = await api.me();
          await _secure.write(key: 'sso_user', value: jsonEncode(user!.toJson()));
        } on ApiException catch (e) {
          if (e.kind == ApiError.unauthorized) {
            user = null;
            await _clear();
          }
          // Network or server trouble: keep the saved profile and token.
        }
      }
    } catch (_) {
      // Secure storage can fail after a backup restore; start signed out.
      user = null;
      await _clear();
    }
    ready = true;
    notifyListeners();
  }

  Future<void> finishOnboarding() async {
    onboarded = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarded', true);
  }

  Future<void> setLang(String value) async {
    if (value == lang) return;
    lang = value;
    api.lang = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', value);
    // Same account language on the website and the chat; failure here is harmless.
    if (signedIn) api.updateLocale(value).catchError((_) {});
  }

  Future<void> signIn(AuthResult result) async {
    sessionExpired = false;
    api.token = result.token;
    user = result.user;
    await _secure.write(key: 'sso_token', value: result.token);
    await _secure.write(key: 'sso_user', value: jsonEncode(result.user.toJson()));
    notifyListeners();
  }

  Future<void> updateUser(AppUser value) async {
    user = value;
    await _secure.write(key: 'sso_user', value: jsonEncode(value.toJson()));
    notifyListeners();
  }

  Future<void> signOut() async {
    user = null;
    sessionExpired = false;
    await _clear();
    onSignedOut?.call();
    notifyListeners();
  }

  Future<void> _clear() async {
    api.token = null;
    try {
      await _secure.delete(key: 'sso_token');
      await _secure.delete(key: 'sso_user');
    } catch (_) {}
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Without listening (for callbacks).
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

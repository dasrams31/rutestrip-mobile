import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// App-wide state: language, the signed-in user and the API client.
class AppState extends ChangeNotifier {
  AppState(this.api);

  final Api api;
  final _secure = const FlutterSecureStorage();

  String lang = 'id';
  AppUser? user;
  bool ready = false;

  bool get signedIn => user != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    lang = prefs.getString('lang') ?? 'id';
    api.lang = lang;
    try {
      final token = await _secure.read(key: 'sso_token');
      if (token != null) {
        api.token = token;
        user = await api.me();
      }
    } on ApiException catch (e) {
      // An expired or revoked token signs the user out; a network error keeps the token for later.
      if (e.status == 401) await _clearToken();
    } catch (_) {
      // Secure storage can fail after a backup restore; start signed out.
      await _clearToken();
    }
    ready = true;
    notifyListeners();
  }

  Future<void> setLang(String value) async {
    if (value == lang) return;
    lang = value;
    api.lang = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', value);
  }

  Future<void> signIn(AuthResult result) async {
    api.token = result.token;
    user = result.user;
    await _secure.write(key: 'sso_token', value: result.token);
    notifyListeners();
  }

  Future<void> signOut() async {
    user = null;
    await _clearToken();
    notifyListeners();
  }

  Future<void> _clearToken() async {
    api.token = null;
    try {
      await _secure.delete(key: 'sso_token');
    } catch (_) {}
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Without listening (for callbacks).
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

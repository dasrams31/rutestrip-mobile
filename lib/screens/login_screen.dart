import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';

/// Log in or sign up with the RuteStrip account (same SSO as the site and the chat).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.register = false, this.gate = false});

  final bool register;

  /// Shown as the app's first screen while signed out (no back button, a short intro).
  final bool gate;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  var _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  late bool _register = widget.register;
  bool _busy = false, _checking = false, _hide = true;
  String? _error;
  Map<String, String> _fieldErrors = {};

  @override
  void dispose() {
    for (final c in [_name, _email, _password, _password2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _fieldErrors = {};
    });
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _checking = _register;
    });
    try {
      final result = _register
          ? await state.api.register(name: _name.text.trim(), email: _email.text.trim(), password: _password.text, confirmation: _password2.text)
          : await state.api.login(_email.text.trim(), _password.text);
      await state.signIn(result);
      if (mounted && !widget.gate) Navigator.of(context).maybePop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _fieldErrors = e.fieldErrors;
        _error = errorText(context, e);
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = _checking = false);
    }
  }

  String? _required(String? v) => (v ?? '').trim().isEmpty ? tr(context, 'field.required') : null;

  @override
  Widget build(BuildContext context) {
    final title = tr(context, _register ? 'register.title' : 'login.title');
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ContourHeader(
            seed: _register ? 13 : 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HeaderBar(),
                const SizedBox(height: 14),
                Semantics(
                  header: true,
                  child: Text(title.toUpperCase(), style: RS.head(40, color: Colors.white)),
                ),
                const SizedBox(height: 8),
                Text(tr(context, widget.gate ? 'login.gate' : 'login.lead'), style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 15, height: 1.4)),
              ],
            ),
          ),
          Padding(
            padding: pageGutter(context, top: 22, bottom: 32, min: 20),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            border: const Border(left: BorderSide(color: RS.err, width: 4)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.error_outline, color: RS.err, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(_error!, style: const TextStyle(color: Color(0xFF7F1D1D), height: 1.4)),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_register) ...[
                      TextFormField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        decoration: InputDecoration(labelText: tr(context, 'field.name'), errorText: _fieldErrors['name']),
                        validator: _required,
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: tr(context, 'field.email'), errorText: _fieldErrors['email']),
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty) return tr(context, 'field.required');
                        return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s) ? null : tr(context, 'field.email_bad');
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _hide,
                      textInputAction: _register ? TextInputAction.next : TextInputAction.done,
                      onFieldSubmitted: _register ? null : (_) => _submit(),
                      autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: tr(context, 'field.password'),
                        errorText: _fieldErrors['password'],
                        suffixIcon: IconButton(
                          tooltip: tr(context, _hide ? 'field.show' : 'field.hide'),
                          onPressed: () => setState(() => _hide = !_hide),
                          icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        ),
                      ),
                      validator: (v) {
                        if ((v ?? '').isEmpty) return tr(context, 'field.required');
                        return _register && v!.length < 8 ? tr(context, 'field.password_short') : null;
                      },
                    ),
                    if (_register) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password2,
                        obscureText: _hide,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(labelText: tr(context, 'field.password2')),
                        validator: (v) => v != _password.text ? tr(context, 'field.password_mismatch') : null,
                      ),
                    ],
                    const SizedBox(height: 22),
                    SignButton(
                      label: tr(context, _register ? 'register.button' : 'login.button'),
                      busy: _busy,
                      busyLabel: tr(context, _checking ? 'register.check' : (_register ? 'register.busy' : 'login.busy')),
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _register = !_register;
                              // New form state: errors from the other mode do not carry over.
                              _form = GlobalKey<FormState>();
                              _error = null;
                              _fieldErrors = {};
                            }),
                      child: Text(tr(context, _register ? 'register.to_login' : 'login.to_register')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

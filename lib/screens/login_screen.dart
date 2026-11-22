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

  void _switch(bool register) {
    if (_busy || register == _register) return;
    setState(() {
      _register = register;
      // New form state: errors from the other mode do not carry over.
      _form = GlobalKey<FormState>();
      _error = null;
      _fieldErrors = {};
    });
  }

  InputDecoration _field(String label, IconData icon, {String? error, String? helper, Widget? suffix}) => InputDecoration(
    labelText: label,
    errorText: error,
    helperText: helper,
    prefixIcon: Icon(icon),
    suffixIcon: suffix,
    filled: true,
    fillColor: Colors.white,
  );

  @override
  Widget build(BuildContext context) {
    final title = tr(context, _register ? 'register.title' : 'login.title');
    return Scaffold(
      backgroundColor: RS.z9,
      body: ContourBackground(
        seed: _register ? 13 : 11,
        child: SafeArea(
          child: Column(
            children: [
              const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 0), child: HeaderBar(brand: false)),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    child: ConstrainedBox(
                      // Centred on tall screens; scrolls when the keyboard is up.
                      constraints: BoxConstraints(minHeight: (box.maxHeight - 28).clamp(0, double.infinity)),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: RS.sun, width: 2),
                                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 18, offset: Offset(0, 6))],
                                  ),
                                  child: ClipOval(
                                    child: Image.asset('assets/images/logo.png', width: 68, height: 68, cacheWidth: 204, semanticLabel: 'RuteStrip'),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'RUTESTRIP',
                                textAlign: TextAlign.center,
                                style: RS.head(15, color: RS.onDarkSoft).copyWith(letterSpacing: 5),
                              ),
                              const SizedBox(height: 4),
                              Semantics(
                                header: true,
                                child: Text(
                                  title.toUpperCase(),
                                  textAlign: TextAlign.center,
                                  style: RS.head(40, color: Colors.white).copyWith(height: 1.05),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                tr(context, widget.gate ? 'login.gate' : 'login.lead'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Color(0xFFD1FAE5), fontSize: 15, height: 1.45),
                              ),
                              const SizedBox(height: 22),
                              _card(context),
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.lock_outline, size: 15, color: RS.onDarkSoft),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      tr(context, 'login.same'),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: RS.onDarkSoft, fontSize: 13, height: 1.35),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: RS.paper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x99FFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 14))],
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Form(
        key: _form,
        child: AutofillGroup(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ModeSwitch(register: _register, onChanged: _switch),
                const SizedBox(height: 18),
                if (_error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        border: const Border(left: BorderSide(color: RS.err, width: 4)),
                        borderRadius: BorderRadius.circular(6),
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
                    decoration: _field(tr(context, 'field.name'), Icons.person_outline, error: _fieldErrors['name']),
                    validator: _required,
                  ),
                  const SizedBox(height: 14),
                ],
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: _field(tr(context, 'field.email'), Icons.mail_outline, error: _fieldErrors['email']),
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
                  decoration: _field(
                    tr(context, 'field.password'),
                    Icons.key_outlined,
                    error: _fieldErrors['password'],
                    helper: _register ? tr(context, 'field.password_hint') : null,
                    suffix: IconButton(
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
                    decoration: _field(tr(context, 'field.password2'), Icons.key_outlined),
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
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : () => _switch(!_register),
                  child: Text(tr(context, _register ? 'register.to_login' : 'login.to_register')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Masuk | Daftar" switch with a sliding pill.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.register, required this.onChanged});

  final bool register;
  final ValueChanged<bool> onChanged;

  Widget _tab(BuildContext context, bool value, String key) => Expanded(
    child: Semantics(
      button: true,
      selected: register == value,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(value),
        child: SizedBox(
          height: 44,
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(fontFamily: RS.body, fontWeight: FontWeight.w700, fontSize: 15, color: register == value ? Colors.white : RS.z9),
              child: Text(tr(context, key)),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: RS.mist, borderRadius: BorderRadius.circular(14)),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: register ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: RS.z9,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
              ),
            ),
          ),
          Row(children: [_tab(context, false, 'login.tab'), _tab(context, true, 'register.tab')]),
        ],
      ),
    );
  }
}

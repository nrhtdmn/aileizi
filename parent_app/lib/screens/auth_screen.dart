import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../brand.dart';
import '../l10n/app_locale.dart';
import '../services/firebase_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _loading = false;
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  void _showOk(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _submit() async {
    final l10n = context.read<AppLocale>();
    if (_emailCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      _showError(l10n.t('fill_email_password'));
      return;
    }
    setState(() => _loading = true);

    try {
      final svc = context.read<FirebaseService>();
      if (_isLogin) {
        await svc.signIn(_emailCtrl.text.trim(), _passCtrl.text);
      } else {
        await svc.register(
          _emailCtrl.text.trim(),
          _passCtrl.text,
          _nameCtrl.text.trim(),
        );
      }
    } catch (e) {
      final msg = context.read<AppLocale>().authError(e);
      // Pigeon uyarısı aslında başarı — kırmızı gösterme
      if (msg.contains('plugin') ||
          msg.contains('eklenti') ||
          msg.contains('completed') ||
          msg.contains('tamamlandı')) {
        _showOk(msg);
      } else {
        _showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _loading = true);
    final l10n = context.read<AppLocale>();
    try {
      await context.read<FirebaseService>().signInWithGoogle();
    } catch (e) {
      final msg = l10n.authError(e);
      if (msg == l10n.t('err_google_canceled')) {
        // sessiz
      } else {
        _showError('${l10n.t('err_google_failed')}: $msg');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final l10n = context.read<AppLocale>();
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      _showError(l10n.t('enter_email_first'));
      return;
    }
    setState(() => _loading = true);
    try {
      await context.read<FirebaseService>().sendPasswordResetEmail(email);
      _showOk(l10n.t('reset_sent'));
    } catch (e) {
      _showError(l10n.authError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.watch<AppLocale>();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1B4332),
              Color(0xFF2D6A4F),
              Color(0xFFD8F3DC),
            ],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _LangChip(
                            label: 'TR',
                            selected: l10n.isTr,
                            onTap: () => l10n.setLanguageCode('tr'),
                          ),
                          _LangChip(
                            label: 'EN',
                            selected: !l10n.isTr,
                            onTap: () => l10n.setLanguageCode('en'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  BrandHero(
                    logoAsset: 'assets/brand/launcher.png',
                    subtitle: Brand.parentSubtitle,
                  ),
                  const SizedBox(height: 36),
                  Card(
                    elevation: 8,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _isLogin ? l10n.t('login') : l10n.t('register'),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 20),
                          OutlinedButton.icon(
                            onPressed: _loading ? null : _signInWithGoogle,
                            icon: const Icon(Icons.g_mobiledata, size: 28),
                            label: Text(l10n.t('continue_google')),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Expanded(child: Divider()),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(l10n.t('or')),
                              ),
                              const Expanded(child: Divider()),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (!_isLogin) ...[
                            TextField(
                              controller: _nameCtrl,
                              decoration: InputDecoration(
                                labelText: l10n.t('name'),
                                prefixIcon: const Icon(Icons.person_outline),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextField(
                            controller: _emailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: l10n.t('email'),
                              prefixIcon: const Icon(Icons.email_outlined),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _passCtrl,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: l10n.t('password'),
                              prefixIcon: const Icon(Icons.lock_outline),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          if (_isLogin)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _loading ? null : _forgotPassword,
                                child: Text(l10n.t('forgot_password')),
                              ),
                            )
                          else
                            const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: _loading ? null : _submit,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Brand.parentAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: _loading
                                ? const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(_isLogin
                                    ? l10n.t('login')
                                    : l10n.t('register')),
                          ),
                          TextButton(
                            onPressed: _loading
                                ? null
                                : () => setState(() => _isLogin = !_isLogin),
                            child: Text(_isLogin
                                ? l10n.t('no_account')
                                : l10n.t('have_account')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LangChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LangChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: selected ? const Color(0xFF1B4332) : Colors.white,
          ),
        ),
      ),
    );
  }
}

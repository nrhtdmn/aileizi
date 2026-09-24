import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../l10n/app_locale.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';
import 'supervision_screen.dart';
import 'reports_screen.dart';
import '../widgets/safe_name_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _inviteCode;
  bool _generatingCode = false;

  String _initial(String? displayName, String? email) {
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty) return name[0].toUpperCase();
    final mail = email?.trim() ?? '';
    if (mail.isNotEmpty) return mail[0].toUpperCase();
    return 'E';
  }

  Future<void> _generateInviteCode() async {
    setState(() => _generatingCode = true);
    try {
      final svc = context.read<FirebaseService>();
      final l10n = context.read<AppLocale>();
      final code = await svc.createInviteCode();
      if (!mounted) return;
      setState(() => _inviteCode = code);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('invite_created'))),
      );
    } catch (e) {
      if (!mounted) return;
      final l10n = context.read<AppLocale>();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.t('invite_failed')}: ${FirebaseService.describeError(e)}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _generatingCode = false);
    }
  }

  Future<void> _renameChild(ChildSummary child) async {
    final name = await showSafeNameDialog(
      context: context,
      title: 'Çocuk adını düzenle',
      initialName: child.name,
      label: 'Ad',
    );
    if (name == null || name.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final svc = context.read<FirebaseService>();
    try {
      await svc.renameChild(child.uid, name);
      messenger.showSnackBar(
        SnackBar(content: Text('İsim güncellendi: $name')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Güncellenemedi: ${FirebaseService.describeError(e)}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _removeChild(ChildSummary child) async {
    final l10n = context.read<AppLocale>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.t('delete_child_title')),
        content: Text(
          l10n.t('delete_child_body').replaceAll('{name}', child.name),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.t('cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('delete'),
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<FirebaseService>().removeChild(child.uid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  l10n.t('child_removed').replaceAll('{name}', child.name))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.t('delete_failed')}: $e')),
        );
      }
    }
  }

  Future<void> _changePassword() async {
    final l10n = context.read<AppLocale>();
    final svc = context.read<FirebaseService>();
    if (!svc.hasPasswordProvider) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('google_only_password'))),
      );
      return;
    }

    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.t('change_password')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currentCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.t('current_password'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: newCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.t('new_password'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.t('confirm_password'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.t('save')),
          ),
        ],
      ),
    );

    final current = currentCtrl.text;
    final next = newCtrl.text;
    final confirm = confirmCtrl.text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      currentCtrl.dispose();
      newCtrl.dispose();
      confirmCtrl.dispose();
    });

    if (result != true || !mounted) return;
    if (next.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('password_too_short'))),
      );
      return;
    }
    if (next != confirm) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('password_mismatch'))),
      );
      return;
    }

    try {
      await svc.changePassword(currentPassword: current, newPassword: next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t('password_changed'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.authError(e)),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();
    final user = svc.currentUser;

    return Scaffold(
      appBar: AppBar(title: Text(context.watch<AppLocale>().t('title_settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: const Color(0xFF2D6A4F),
                child: Text(
                  _initial(user?.displayName, user?.email),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              title: Text(
                (user?.displayName?.trim().isNotEmpty ?? false)
                    ? user!.displayName!
                    : context.watch<AppLocale>().t('parent'),
              ),
              subtitle: Text(user?.email ?? ''),
            ),
          ),

          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(context.watch<AppLocale>().t('change_password')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _changePassword(),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(context.watch<AppLocale>().t('language')),
                  subtitle: Text(context.watch<AppLocale>().isTr
                      ? context.watch<AppLocale>().t('turkish')
                      : context.watch<AppLocale>().t('english')),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => context
                              .read<AppLocale>()
                              .setLanguageCode('tr'),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: context.watch<AppLocale>().isTr
                                ? const Color(0xFF2D6A4F)
                                : null,
                            foregroundColor: context.watch<AppLocale>().isTr
                                ? Colors.white
                                : null,
                          ),
                          child: const Text('TR'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => context
                              .read<AppLocale>()
                              .setLanguageCode('en'),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: !context.watch<AppLocale>().isTr
                                ? const Color(0xFF2D6A4F)
                                : null,
                            foregroundColor: !context.watch<AppLocale>().isTr
                                ? Colors.white
                                : null,
                          ),
                          child: const Text('EN'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          Text(
            context.watch<AppLocale>().t('connected_children'),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            context.watch<AppLocale>().t('tap_child_edit'),
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          Card(
            child: StreamBuilder<List<ChildSummary>>(
              stream: svc.watchChildren(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ListTile(
                    leading: const Icon(Icons.error, color: Colors.red),
                    title: const Text('Çocuk listesi okunamadı'),
                    subtitle: Text('${snapshot.error}'),
                  );
                }
                final children = snapshot.data ?? [];
                if (children.isEmpty) {
                  return const ListTile(
                    leading: Icon(Icons.child_care, color: Colors.grey),
                    title: Text('Henüz bağlı çocuk yok'),
                    subtitle: Text(
                      'Aşağıdan davet kodu oluşturup çocuk uygulamasına girin.',
                    ),
                  );
                }
                return Column(
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF2D6A4F),
                          child: Text(
                            children[i].name.isNotEmpty
                                ? children[i].name[0].toUpperCase()
                                : 'C',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(children[i].name),
                        subtitle: Text(
                            'ID: ${children[i].uid.substring(0, 8)}…'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') _renameChild(children[i]);
                            if (v == 'delete') _removeChild(children[i]);
                          },
                          itemBuilder: (ctx) {
                            final l10n = ctx.read<AppLocale>();
                            return [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text(l10n.t('edit_name')),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(l10n.t('delete'),
                                    style: const TextStyle(color: Colors.red)),
                              ),
                            ];
                          },
                        ),
                        onTap: () => _renameChild(children[i]),
                        onLongPress: () => _removeChild(children[i]),
                      ),
                      if (i < children.length - 1) const Divider(height: 1),
                    ],
                  ],
                );
              },
            ),
          ),

          const SizedBox(height: 8),
          Text(
            'Aile ID: ${user?.uid ?? '-'}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
          ),

          const SizedBox(height: 24),

          const Text(
            'Çocuk Cihazı Ekle',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Çocuğunun telefonundaki "Çocuk Uygulaması"na '
                    'bu kodu girin:',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  StreamBuilder<List<InviteCode>>(
                    stream: svc.watchActiveInvites(),
                    builder: (context, snap) {
                      final invites = snap.data ?? [];
                      if (invites.isEmpty && _inviteCode == null) {
                        return const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Aktif davet kodu yok. Aşağıdan oluştur.',
                            style: TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                        );
                      }
                      final codes = <InviteCode>[
                        ...invites,
                        if (_inviteCode != null &&
                            !invites.any((i) => i.code == _inviteCode))
                          InviteCode(
                            code: _inviteCode!,
                            familyId: user?.uid ?? '',
                          ),
                      ];
                      return Column(
                        children: [
                          for (final inv in codes)
                            Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 16),
                              decoration: BoxDecoration(
                                color:
                                    const Color(0xFF2D6A4F).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: const Color(0xFF2D6A4F)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          inv.code,
                                          style: const TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 6,
                                            color: Color(0xFF2D6A4F),
                                          ),
                                        ),
                                        if (inv.expiresAt != null)
                                          Text(
                                            'Son: ${DateFormat('dd.MM.yyyy HH:mm').format(inv.expiresAt!)}',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.black54),
                                          )
                                        else
                                          const Text(
                                            '24 saat geçerli',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.black54),
                                          ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Kopyala',
                                    icon: const Icon(Icons.copy),
                                    onPressed: () {
                                      Clipboard.setData(
                                          ClipboardData(text: inv.code));
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content: Text('Kod kopyalandı')),
                                      );
                                    },
                                  ),
                                  IconButton(
                                    tooltip: 'Kodu sil',
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.red),
                                    onPressed: () async {
                                      try {
                                        await svc.deleteInvite(inv.code);
                                        if (_inviteCode == inv.code &&
                                            mounted) {
                                          setState(() => _inviteCode = null);
                                        }
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(SnackBar(
                                                  content: Text(
                                                      'Silinemedi: $e')));
                                        }
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: _generatingCode
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.add),
                      label: Text(_generatingCode
                          ? 'Oluşturuluyor…'
                          : 'Yeni Davet Kodu Oluştur'),
                      onPressed: _generatingCode ? null : _generateInviteCode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2D6A4F),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          const Text(
            'İzleme ve raporlar',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Ebeveyn kontrolü'),
                  subtitle: const Text(
                    'Ekran süresi, uyku/ders kilidi, uygulama listesi, içerik bayrakları',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => const SupervisionScreen()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.bar_chart),
                  title: const Text('Raporlar'),
                  subtitle: const Text('Son 7 gün ekran süresi özeti'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => const ReportsScreen()),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: Text(context.watch<AppLocale>().t('logout'),
                  style: const TextStyle(color: Colors.red)),
              onTap: () async {
                final l10n = context.read<AppLocale>();
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(l10n.t('logout')),
                    content: Text(l10n.t('logout_confirm')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(l10n.t('cancel')),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(l10n.t('logout')),
                      ),
                    ],
                  ),
                );
                if (confirm == true) svc.signOut();
              },
            ),
          ),

          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Aileİzi v1.0.0',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

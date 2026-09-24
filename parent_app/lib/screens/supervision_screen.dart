import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';

/// Ekran süresi, uygulama listesi, içerik / iletişim bayrakları (Android’de tam uygulama için yerel katman gerekir).
class SupervisionScreen extends StatefulWidget {
  const SupervisionScreen({super.key});

  @override
  State<SupervisionScreen> createState() => _SupervisionScreenState();
}

class _SupervisionScreenState extends State<SupervisionScreen> {
  String? _selectedChildId;
  final _limitCtrl = TextEditingController();
  final _bedStartCtrl = TextEditingController(text: '21:30');
  final _bedEndCtrl = TextEditingController(text: '07:00');
  final _schoolStartCtrl = TextEditingController(text: '08:00');
  final _schoolEndCtrl = TextEditingController(text: '15:30');
  final _blockedCtrl = TextEditingController();
  bool _blockAdult = false;
  bool _youtubeHint = false;
  bool _logSearch = false;
  bool _monitorComm = false;
  bool _flagUnknown = false;
  bool _socialHint = false;
  bool _loading = false;
  bool _loadingPolicies = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final svc = context.read<FirebaseService>();
      final list = await svc.watchChildren().first;
      if (!mounted || list.isEmpty) return;
      setState(() => _selectedChildId = list.first.uid);
      await _reloadPoliciesForSelected();
    });
  }

  @override
  void dispose() {
    _limitCtrl.dispose();
    _bedStartCtrl.dispose();
    _bedEndCtrl.dispose();
    _schoolStartCtrl.dispose();
    _schoolEndCtrl.dispose();
    _blockedCtrl.dispose();
    super.dispose();
  }

  void _applyPolicies(ChildPolicies? p) {
    if (p == null) {
      _limitCtrl.clear();
      _blockedCtrl.clear();
      _blockAdult = false;
      _youtubeHint = false;
      _logSearch = false;
      _monitorComm = false;
      _flagUnknown = false;
      _socialHint = false;
      return;
    }
    _limitCtrl.text = p.dailyScreenLimitMinutes?.toString() ?? '';
    _bedStartCtrl.text = p.bedTimeStart ?? '21:30';
    _bedEndCtrl.text = p.bedTimeEnd ?? '07:00';
    _schoolStartCtrl.text = p.schoolBlockStart ?? '08:00';
    _schoolEndCtrl.text = p.schoolBlockEnd ?? '15:30';
    _blockedCtrl.text = p.blockedPackages.join(', ');
    _blockAdult = p.blockAdultWebsites;
    _youtubeHint = p.youtubeRestrictedModeHint;
    _logSearch = p.logBrowserSearch;
    _monitorComm = p.monitorCallsAndSms;
    _flagUnknown = p.flagUnknownContacts;
    _socialHint = p.socialActivityHints;
  }

  Future<void> _reloadPoliciesForSelected() async {
    final childId = _selectedChildId;
    if (childId == null) return;
    setState(() => _loadingPolicies = true);
    try {
      final svc = context.read<FirebaseService>();
      final p = await svc.getChildPoliciesOnce(childId);
      if (mounted) {
        setState(() {
          _applyPolicies(p);
          _loadingPolicies = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingPolicies = false);
    }
  }

  Future<void> _save() async {
    final childId = _selectedChildId;
    if (childId == null) return;
    final svc = context.read<FirebaseService>();
    final limitRaw = _limitCtrl.text.trim();
    final policies = ChildPolicies(
      childId: childId,
      dailyScreenLimitMinutes: limitRaw.isEmpty ? null : int.tryParse(limitRaw),
      bedTimeStart:
          _bedStartCtrl.text.trim().isEmpty ? null : _bedStartCtrl.text.trim(),
      bedTimeEnd:
          _bedEndCtrl.text.trim().isEmpty ? null : _bedEndCtrl.text.trim(),
      schoolBlockStart: _schoolStartCtrl.text.trim().isEmpty
          ? null
          : _schoolStartCtrl.text.trim(),
      schoolBlockEnd: _schoolEndCtrl.text.trim().isEmpty
          ? null
          : _schoolEndCtrl.text.trim(),
      blockedPackages: _blockedCtrl.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      blockAdultWebsites: _blockAdult,
      youtubeRestrictedModeHint: _youtubeHint,
      logBrowserSearch: _logSearch,
      monitorCallsAndSms: _monitorComm,
      flagUnknownContacts: _flagUnknown,
      socialActivityHints: _socialHint,
    );
    setState(() => _loading = true);
    try {
      await svc.saveChildPolicies(policies);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Politikalar kaydedildi')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kayıt hatası: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();

    return Scaffold(
      appBar: AppBar(title: const Text('Ebeveyn Kontrolü')),
      body: StreamBuilder<List<ChildSummary>>(
        stream: svc.watchChildren(),
        builder: (context, snap) {
          if (!snap.hasData || snap.data!.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Önce bir çocuk davet koduyla aileye katılmalı.'),
              ),
            );
          }
          final children = snap.data!;
          final ids = children.map((c) => c.uid).toSet();
          final selectedId = (_selectedChildId != null &&
                  ids.contains(_selectedChildId))
              ? _selectedChildId
              : children.first.uid;
          if (_selectedChildId != selectedId) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _selectedChildId = selectedId);
              _reloadPoliciesForSelected();
            });
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Android’de uygulama engeli, web filtresi ve arama/SMS izleme '
                'için ek yerel izinler ve (çoğu durumda) Accessibility / VPN / '
                'Device Admin veya denetimli Google hesabı gerekir; bu ekran kuralları '
                'bulutta saklar ve çocuk uygulaması uyku/ders kilidini uygular.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedId,
                decoration: const InputDecoration(
                  labelText: 'Çocuk',
                  border: OutlineInputBorder(),
                ),
                items: children
                    .map((c) =>
                        DropdownMenuItem(value: c.uid, child: Text(c.name)))
                    .toList(),
                onChanged: (id) async {
                  setState(() => _selectedChildId = id);
                  await _reloadPoliciesForSelected();
                },
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed:
                      _loadingPolicies ? null : _reloadPoliciesForSelected,
                  icon: _loadingPolicies
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined),
                  label: const Text('Sunucudan yükle'),
                ),
              ),
              TextField(
                controller: _limitCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText:
                      'Günlük ekran süresi limiti (dakika), boş = limitsiz',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _bedStartCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Uyku başlangıç (HH:mm)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _bedEndCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Uyku bitiş (HH:mm)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _schoolStartCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Ders başlangıç',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _schoolEndCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Ders bitiş',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Ders saatleri: hafta içi (Pzts–Cum) varsayılan',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _blockedCtrl,
                decoration: const InputDecoration(
                  labelText: 'Engelli paket adları (com.x.y virgülle)',
                  border: OutlineInputBorder(),
                  helperText:
                      'Tam kilitleme için yerel Android katmanı gerekir',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Yetişkin web engeli (hedef)'),
                subtitle: const Text('Yerel VPN/DNS veya tarayıcı API'),
                value: _blockAdult,
                onChanged: (v) => setState(() => _blockAdult = v),
              ),
              SwitchListTile(
                title: const Text('YouTube kısıtlama ipucu'),
                subtitle:
                    const Text('Denetimli hesap / Family Link ile birlikte'),
                value: _youtubeHint,
                onChanged: (v) => setState(() => _youtubeHint = v),
              ),
              SwitchListTile(
                title: const Text('Arama geçmişi kaydı (hedef)'),
                value: _logSearch,
                onChanged: (v) => setState(() => _logSearch = v),
              ),
              SwitchListTile(
                title: const Text('Arama / SMS izleme (hedef)'),
                subtitle:
                    const Text('Android 10+ ve mağaza politikaları kısıtlar'),
                value: _monitorComm,
                onChanged: (v) => setState(() => _monitorComm = v),
              ),
              SwitchListTile(
                title: const Text('Bilinmeyen numara işaretleme (hedef)'),
                value: _flagUnknown,
                onChanged: (v) => setState(() => _flagUnknown = v),
              ),
              SwitchListTile(
                title: const Text('Sosyal medya aktivitesi (hedef)'),
                value: _socialHint,
                onChanged: (v) => setState(() => _socialHint = v),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loading ? null : _save,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Kaydet'),
              ),
            ],
          );
        },
      ),
    );
  }
}

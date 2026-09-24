import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String? _selectedChildId;
  List<MapEntry<DateTime, int>> _series = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final childId = _selectedChildId;
    if (childId == null) return;
    setState(() => _busy = true);
    try {
      final svc = context.read<FirebaseService>();
      final data = await svc.getScreenTimeDailySeries(childId, 7);
      if (mounted) setState(() => _series = data);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();
    final df = DateFormat('EEE d/M');

    return Scaffold(
      appBar: AppBar(title: const Text('Raporlar')),
      body: StreamBuilder<List<ChildSummary>>(
        stream: svc.watchChildren(),
        builder: (context, snap) {
          if (!snap.hasData || snap.data!.isEmpty) {
            return const Center(child: Text('Henüz çocuk yok'));
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
              _load();
            });
          }

          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: selectedId,
                        decoration: const InputDecoration(
                          labelText: 'Çocuk',
                          border: OutlineInputBorder(),
                        ),
                        items: children
                            .map((c) => DropdownMenuItem(
                                value: c.uid, child: Text(c.name)))
                            .toList(),
                        onChanged: (id) {
                          setState(() => _selectedChildId = id);
                          _load();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _busy ? null : _load,
                      icon: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Son 7 gün ekran süresi (UsageStats ile yüklenen günlük toplamlar)',
                  style: TextStyle(color: Colors.black54),
                ),
              ),
              const SizedBox(height: 8),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_series.isEmpty)
                const ListTile(title: Text('Veri yok'))
              else
                ..._series.map((e) => ListTile(
                      title: Text(df.format(e.key)),
                      trailing: Text(
                        '${e.value} dk',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    )),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Şüpheli aktivite ve pil: Harita ve cihaz durumu ekranından takip; '
                  'push için FCM + Cloud Functions önerilir.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

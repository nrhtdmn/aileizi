import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/firebase_service.dart';
import '../models/models.dart';
import '../utils/app_display_names.dart';
import '../l10n/app_locale.dart';

class ScreenStatsScreen extends StatefulWidget {
  const ScreenStatsScreen({super.key});

  @override
  State<ScreenStatsScreen> createState() => _ScreenStatsScreenState();
}

class _ScreenStatsScreenState extends State<ScreenStatsScreen> {
  DateTime _selectedDate = DateTime.now();
  String? _selectedChildId;
  List<AppUsageStat> _stats = [];
  bool _loading = false;
  String? _error;
  bool _loadedOnce = false;

  Future<void> _loadStats() async {
    if (_selectedChildId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final svc = context.read<FirebaseService>();
      final stats = await svc.getScreenStats(_selectedChildId!, _selectedDate);
      stats.sort((a, b) => b.totalTimeMinutes.compareTo(a.totalTimeMinutes));
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loadedOnce = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _stats = [];
        _loading = false;
        _loadedOnce = true;
      });
    }
  }

  int get _totalMinutes => _stats.fold(0, (sum, s) => sum + s.totalTimeMinutes);

  String _formatDuration(int minutes) {
    if (minutes < 60) return '$minutes dk';
    return '${minutes ~/ 60}s ${minutes % 60}dk';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.watch<AppLocale>().t('title_screen')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStats,
          ),
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: _pickDate,
          ),
        ],
      ),
      body: Column(
        children: [
          StreamBuilder<List<ChildSummary>>(
            stream: context.read<FirebaseService>().watchChildren(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Çocuk listesi okunamadı: ${snap.error}',
                    style: const TextStyle(color: Colors.red),
                  ),
                );
              }
              final children = snap.data ?? [];
              if (children.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Henüz aileye katılan bir çocuk yok.',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              final ids = children.map((c) => c.uid).toSet();
              if (_selectedChildId == null ||
                  !ids.contains(_selectedChildId)) {
                _selectedChildId = children.first.uid;
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _loadStats());
              } else if (!_loadedOnce && !_loading) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _loadStats());
              }

              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: DropdownButtonFormField<String>(
                  value: _selectedChildId,
                  decoration: const InputDecoration(
                    labelText: 'Çocuk',
                    border: OutlineInputBorder(),
                  ),
                  items: children
                      .map((c) => DropdownMenuItem(
                            value: c.uid,
                            child: Text(c.name),
                          ))
                      .toList(),
                  onChanged: (id) {
                    setState(() {
                      _selectedChildId = id;
                      _stats = [];
                      _loadedOnce = false;
                    });
                    _loadStats();
                  },
                ),
              );
            },
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () {
                    setState(() {
                      _selectedDate =
                          _selectedDate.subtract(const Duration(days: 1));
                      _loadedOnce = false;
                    });
                    _loadStats();
                  },
                ),
                Text(
                  DateFormat('dd MMMM yyyy',
                          context.watch<AppLocale>().isTr ? 'tr_TR' : 'en_US')
                      .format(_selectedDate),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _selectedDate.isBefore(
                          DateTime.now().subtract(const Duration(days: 1)))
                      ? () {
                          setState(() {
                            _selectedDate =
                                _selectedDate.add(const Duration(days: 1));
                            _loadedOnce = false;
                          });
                          _loadStats();
                        }
                      : null,
                ),
              ],
            ),
          ),
          if (_stats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                color: const Color(0xFF2D6A4F),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Column(
                        children: [
                          Text(
                            _formatDuration(_totalMinutes),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            'Toplam Ekran',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          Text(
                            '${_stats.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            'Uygulama',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Ekran süresi okunamadı:\n$_error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      )
                    : _stats.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.phone_android,
                                      size: 60, color: Colors.grey),
                                  const SizedBox(height: 16),
                                  Text(
                                    'Bu tarih için veri yok',
                                    style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Çocuk telefonunda:\n'
                                    '1) Kullanım erişimi izni ver\n'
                                    '2) Uygulamayı açık tut / yenile\n'
                                    '3) Birkaç dakika sonra burayı yenile',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 13),
                                  ),
                                  const SizedBox(height: 16),
                                  ElevatedButton.icon(
                                    onPressed: _loadStats,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Yenile'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _stats.length,
                            itemBuilder: (context, i) {
                              final stat = _stats[i];
                              final percentage = _totalMinutes > 0
                                  ? stat.totalTimeMinutes / _totalMinutes
                                  : 0.0;
                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.apps, size: 20),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              AppDisplayNames.resolve(
                                                packageName: stat.packageName,
                                                appName: stat.appName,
                                              ),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            _formatDuration(
                                                stat.totalTimeMinutes),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF2D6A4F),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      LinearProgressIndicator(
                                        value: percentage,
                                        backgroundColor: Colors.grey.shade200,
                                        color: const Color(0xFF2D6A4F),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _loadedOnce = false;
      });
      _loadStats();
    }
  }
}

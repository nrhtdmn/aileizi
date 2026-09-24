import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/firebase_service.dart';
import '../services/parent_nav.dart';
import '../models/models.dart';
import '../utils/map_launch.dart';
import '../l10n/app_locale.dart';

class SosScreen extends StatelessWidget {
  const SosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(context.watch<AppLocale>().t('title_sos')),
        backgroundColor: Colors.red.shade50,
      ),
      body: StreamBuilder<List<SosEvent>>(
        stream: svc.watchSosEvents(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'SOS olayları okunamadı:\n${snapshot.error}\n\n'
                  'Firestore Rules yayınlandığından emin ol.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final events = snapshot.data ?? [];

          if (events.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 80, color: Colors.green.shade300),
                  const SizedBox(height: 16),
                  Text(
                    'Aktif SOS olayı yok',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Çocukların güvende',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                ],
              ),
            );
          }

          final unacknowledged = events.where((e) => !e.acknowledged).toList();
          final acknowledged = events.where((e) => e.acknowledged).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (unacknowledged.isNotEmpty) ...[
                const _SectionHeader(title: 'Aktif Uyarılar', isAlert: true),
                ...unacknowledged.map((e) => _SosCard(event: e, svc: svc)),
              ],
              if (acknowledged.isNotEmpty) ...[
                const SizedBox(height: 16),
                const _SectionHeader(title: 'Çözümlendi', isAlert: false),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Uzun basarak sil veya tekrar aktifleştir.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                ...acknowledged.map((e) => _SosCard(event: e, svc: svc)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final bool isAlert;

  const _SectionHeader({required this.title, required this.isAlert});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: isAlert ? Colors.red : Colors.grey.shade600,
        ),
      ),
    );
  }
}

class _SosCard extends StatelessWidget {
  final SosEvent event;
  final FirebaseService svc;

  const _SosCard({required this.event, required this.svc});

  void _goToMap(BuildContext context) {
    final lat = event.latitude;
    final lng = event.longitude;
    if (lat.abs() < 0.00001 && lng.abs() < 0.00001) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bu SOS kaydında konum yok.')),
      );
      return;
    }
    context.read<ParentNav>().openMapAt(
          latitude: lat,
          longitude: lng,
          title: 'SOS • ${event.childName}',
        );
  }

  Future<void> _goToExternalMaps(BuildContext context) async {
    final lat = event.latitude;
    final lng = event.longitude;
    if (lat.abs() < 0.00001 && lng.abs() < 0.00001) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bu SOS kaydında konum yok.')),
      );
      return;
    }
    final ok = await MapLaunch.openDirections(
      lat,
      lng,
      label: event.childName,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harita uygulaması açılamadı.')),
      );
    }
  }

  Future<void> _showResolvedActions(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.replay, color: Colors.orange),
              title: const Text('Tekrar aktif hale getir'),
              onTap: () => Navigator.pop(ctx, 'reactivate'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Sil'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('İptal'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );

    if (action == null || !context.mounted) return;
    try {
      if (action == 'reactivate') {
        await svc.reactivateSos(event.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('SOS tekrar aktifleştirildi.')),
          );
        }
      } else if (action == 'delete') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('SOS silinsin mi?'),
            content: Text('${event.childName} kaydı kalıcı silinecek.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('İptal'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sil', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        if (ok == true) {
          await svc.deleteSos(event.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('SOS silindi.')),
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('İşlem başarısız: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isActive = !event.acknowledged;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isActive ? Colors.red.shade50 : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isActive
            ? BorderSide(color: Colors.red.shade200, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: isActive ? null : () => _showResolvedActions(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.emergency,
                    color: isActive ? Colors.red : Colors.grey,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      event.childName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isActive ? Colors.red.shade800 : Colors.black87,
                      ),
                    ),
                  ),
                  Text(
                    DateFormat('dd.MM HH:mm').format(event.timestamp),
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    '${event.latitude.toStringAsFixed(5)}, ${event.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
              if (isActive) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.map),
                        label: const Text('Haritada Gör'),
                        onPressed: () => _goToMap(context),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.directions),
                        label: const Text('Konuma git'),
                        onPressed: () => _goToExternalMaps(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Çözüldü'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => svc.acknowledgeSos(event.id),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'Uzun bas: sil / tekrar aktifleştir',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

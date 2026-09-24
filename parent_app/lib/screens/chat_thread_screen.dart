import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';
import '../utils/chat_helpers.dart';
import '../utils/map_launch.dart';

class ChatThreadScreen extends StatefulWidget {
  final String childId;
  final String childName;

  const ChatThreadScreen({
    super.key,
    required this.childId,
    required this.childName,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FirebaseService>().markChatReadByParent(widget.childId);
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendQuick(String text) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final svc = context.read<FirebaseService>();
      await svc.sendChatMessage(ChatMessage(
        id: '',
        childId: widget.childId,
        senderId: svc.currentUser!.uid,
        senderRole: 'parent',
        type: 'text',
        text: text,
        createdAt: DateTime.now(),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gönderilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final svc = context.read<FirebaseService>();
      await svc.sendChatMessage(ChatMessage(
        id: '',
        childId: widget.childId,
        senderId: svc.currentUser!.uid,
        senderRole: 'parent',
        type: 'text',
        text: text,
        createdAt: DateTime.now(),
      ));
      _textCtrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gönderilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendLocation() async {
    setState(() => _sending = true);
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw Exception('Konum izni yok');
      }
      final pos = await Geolocator.getCurrentPosition();
      final svc = context.read<FirebaseService>();
      await svc.sendChatMessage(ChatMessage(
        id: '',
        childId: widget.childId,
        senderId: svc.currentUser!.uid,
        senderRole: 'parent',
        type: 'location',
        text: 'Konum paylaşımı',
        latitude: pos.latitude,
        longitude: pos.longitude,
        createdAt: DateTime.now(),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Konum gönderilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 55,
      maxWidth: 1280,
    );
    if (file == null) return;
    setState(() => _sending = true);
    try {
      final bytes = await file.readAsBytes();
      final svc = context.read<FirebaseService>();
      final url = await svc.uploadChatImage(
        childId: widget.childId,
        bytes: bytes,
        contentType: 'image/jpeg',
      );
      await svc.sendChatMessage(ChatMessage(
        id: '',
        childId: widget.childId,
        senderId: svc.currentUser!.uid,
        senderRole: 'parent',
        type: 'image',
        text: 'Fotoğraf',
        imageUrl: url,
        createdAt: DateTime.now(),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fotoğraf gönderilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendRoute() async {
    final svc = context.read<FirebaseService>();
    List<TrackedRoute> routes = [];
    try {
      routes = await svc.watchRoutes().first.timeout(const Duration(seconds: 5));
    } catch (_) {}
    routes = routes.where((r) => r.childId == widget.childId || r.childId.isEmpty).toList();
    if (routes.isEmpty) {
      routes = (await svc.watchRoutes().first).toList();
    }
    if (!mounted) return;
    if (routes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Önce haritadan bir rota kaydet.')),
      );
      return;
    }

    final selected = await showModalBottomSheet<TrackedRoute>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Gönderilecek rota',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...routes.map((r) => ListTile(
                  leading: Icon(Icons.route,
                      color: r.active ? const Color(0xFF2D6A4F) : Colors.grey),
                  title: Text(r.name),
                  subtitle: Text(
                      '${r.points.length} nokta • Sapma ${r.deviationMeters.toInt()} m'),
                  onTap: () => Navigator.pop(ctx, r),
                )),
          ],
        ),
      ),
    );
    if (selected == null) return;

    setState(() => _sending = true);
    try {
      await svc.sendChatMessage(ChatMessage(
        id: '',
        childId: widget.childId,
        senderId: svc.currentUser!.uid,
        senderRole: 'parent',
        type: 'route',
        text: selected.name,
        routeName: selected.name,
        routePoints: selected.points,
        createdAt: DateTime.now(),
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“${selected.name}” rota olarak gönderildi')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rota gönderilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();
    final me = svc.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: Text(widget.childName)),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<ChatMessage>>(
              stream: svc.watchChatMessages(widget.childId),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('Sohbet okunamadı: ${snap.error}'));
                }
                final msgs = snap.data ?? [];
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text('Henüz mesaj yok. İlk mesajı sen yaz.'),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollCtrl.hasClients) {
                    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                  }
                });
                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final mine = m.senderId == me;
                    return _Bubble(message: m, mine: mine);
                  },
                );
              },
            ),
          ),
          if (_sending) const LinearProgressIndicator(minHeight: 2),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final q in parentQuickReplies)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(q),
                      onPressed: _sending ? null : () => _sendQuick(q),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Konum',
                    onPressed: _sending ? null : _sendLocation,
                    icon: const Icon(Icons.place_outlined),
                  ),
                  IconButton(
                    tooltip: 'Fotoğraf',
                    onPressed: _sending ? null : _sendImage,
                    icon: const Icon(Icons.photo_outlined),
                  ),
                  IconButton(
                    tooltip: 'Rota gönder',
                    onPressed: _sending ? null : _sendRoute,
                    icon: const Icon(Icons.route),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Mesaj yaz…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  IconButton(
                    onPressed: _sending ? null : _sendText,
                    icon: const Icon(Icons.send, color: Color(0xFF2D6A4F)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;

  const _Bubble({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final bg = mine ? const Color(0xFF2D6A4F) : Colors.grey.shade200;
    final fg = mine ? Colors.white : Colors.black87;
    final time = DateFormat('HH:mm').format(message.createdAt);

    Widget body;
    switch (message.type) {
      case 'location':
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📍 Konum', style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            Text(
              '${message.latitude?.toStringAsFixed(5)}, ${message.longitude?.toStringAsFixed(5)}',
              style: TextStyle(color: fg, fontSize: 12),
            ),
            TextButton(
              onPressed: message.latitude == null
                  ? null
                  : () => MapLaunch.openLocation(
                        message.latitude!,
                        message.longitude!,
                      ),
              child: Text('Haritada aç', style: TextStyle(color: mine ? Colors.amber : Colors.blue)),
            ),
          ],
        );
      case 'image':
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: message.imageUrl!,
                  width: 200,
                  fit: BoxFit.cover,
                ),
              ),
          ],
        );
      case 'route':
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🗺️ ${message.routeName ?? 'Rota'}',
                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            Text('${message.routePoints.length} nokta',
                style: TextStyle(color: fg, fontSize: 12)),
            TextButton(
              onPressed: message.routePoints.isEmpty
                  ? null
                  : () => MapLaunch.openRoute(message.routePoints,
                      name: message.routeName),
              child: Text('Harita uygulamasında git',
                  style: TextStyle(color: mine ? Colors.amber : Colors.blue)),
            ),
          ],
        );
      default:
        body = Text(message.text, style: TextStyle(color: fg));
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            body,
            const SizedBox(height: 2),
            Text(time,
                style: TextStyle(
                    color: mine ? Colors.white70 : Colors.black45, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

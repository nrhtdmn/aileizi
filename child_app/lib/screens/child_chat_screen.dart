import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../services/child_chat_service.dart';
import '../utils/chat_helpers.dart';
import '../utils/map_launch.dart';

class ChildChatScreen extends StatefulWidget {
  const ChildChatScreen({super.key});

  @override
  State<ChildChatScreen> createState() => _ChildChatScreenState();
}

class _ChildChatScreenState extends State<ChildChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  String? _familyId;
  String? _childId;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await ChildChatService.profile();
      if (p == null) {
        setState(() {
          _error = 'Aile bağlantısı yok.';
          _loading = false;
        });
        return;
      }
      setState(() {
        _familyId = p.familyId;
        _childId = p.childId;
        _loading = false;
      });
      await ChildChatService.markRead(p.familyId, p.childId);
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendQuick(String text) async {
    if (_familyId == null || _childId == null || _sending) return;
    setState(() => _sending = true);
    try {
      await ChildChatService.send(
        familyId: _familyId!,
        childId: _childId!,
        type: 'text',
        text: text,
      );
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
    if (text.isEmpty || _familyId == null || _childId == null || _sending) {
      return;
    }
    setState(() => _sending = true);
    try {
      await ChildChatService.send(
        familyId: _familyId!,
        childId: _childId!,
        type: 'text',
        text: text,
      );
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
    if (_familyId == null || _childId == null) return;
    setState(() => _sending = true);
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw Exception('Konum izni yok');
      }
      final pos = await Geolocator.getCurrentPosition();
      await ChildChatService.send(
        familyId: _familyId!,
        childId: _childId!,
        type: 'location',
        text: 'Konum paylaşımı',
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
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
    if (_familyId == null || _childId == null) return;
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 55,
      maxWidth: 1280,
    );
    if (file == null) return;
    setState(() => _sending = true);
    try {
      final bytes = await file.readAsBytes();
      final url = await ChildChatService.uploadImage(
        familyId: _familyId!,
        childId: _childId!,
        bytes: bytes,
      );
      await ChildChatService.send(
        familyId: _familyId!,
        childId: _childId!,
        type: 'image',
        text: 'Fotoğraf',
        imageUrl: url,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Fotoğraf gönderilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A90D9),
        foregroundColor: Colors.white,
        title: const Text('Ebeveyn mesajları'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : Column(
                  children: [
                    Expanded(
                      child: StreamBuilder<List<ChatMessage>>(
                        stream: ChildChatService.watchMessages(
                            _familyId!, _childId!),
                        builder: (context, snap) {
                          if (snap.hasError) {
                            return Center(
                                child: Text('Okunamadı: ${snap.error}'));
                          }
                          final msgs = snap.data ?? [];
                          if (msgs.isEmpty) {
                            return const Center(
                              child: Text('Henüz mesaj yok.'),
                            );
                          }
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_scrollCtrl.hasClients) {
                              _scrollCtrl.jumpTo(
                                  _scrollCtrl.position.maxScrollExtent);
                            }
                          });
                          return ListView.builder(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.all(12),
                            itemCount: msgs.length,
                            itemBuilder: (context, i) {
                              final m = msgs[i];
                              final mine = m.senderRole == 'child';
                              return _ChildBubble(message: m, mine: mine);
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
                          for (final q in childQuickReplies)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                label: Text(q),
                                onPressed:
                                    _sending ? null : () => _sendQuick(q),
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
                              icon: const Icon(Icons.send,
                                  color: Color(0xFF4A90D9)),
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

class _ChildBubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;

  const _ChildBubble({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final bg = mine ? const Color(0xFF4A90D9) : Colors.grey.shade200;
    final fg = mine ? Colors.white : Colors.black87;
    final time = DateFormat('HH:mm').format(message.createdAt);

    Widget body;
    switch (message.type) {
      case 'location':
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📍 Konum',
                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            TextButton(
              onPressed: message.latitude == null
                  ? null
                  : () => MapLaunch.openLocation(
                        message.latitude!,
                        message.longitude!,
                      ),
              child: Text('Haritada aç',
                  style:
                      TextStyle(color: mine ? Colors.amber : Colors.blue)),
            ),
          ],
        );
      case 'image':
        body = message.imageUrl == null
            ? Text('Fotoğraf', style: TextStyle(color: fg))
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: message.imageUrl!,
                  width: 200,
                  fit: BoxFit.cover,
                ),
              );
      case 'route':
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🗺️ ${message.routeName ?? 'Rota'}',
                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            Text('Bu rotayı harita uygulamasında izle',
                style: TextStyle(color: fg, fontSize: 12)),
            FilledButton.tonal(
              onPressed: message.routePoints.isEmpty
                  ? null
                  : () => MapLaunch.openRoute(message.routePoints,
                      name: message.routeName),
              child: const Text('Haritada git'),
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
            Text(time,
                style: TextStyle(
                    color: mine ? Colors.white70 : Colors.black45,
                    fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

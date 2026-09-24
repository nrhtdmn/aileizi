import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';
import '../services/parent_nav.dart';
import '../utils/chat_helpers.dart';
import '../l10n/app_locale.dart';
import 'chat_thread_screen.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPending());
  }

  void _openPending() {
    if (!mounted) return;
    final pending = context.read<ParentNav>().takePendingChat();
    if (pending == null) return;
    final svc = context.read<FirebaseService>();
    String name = pending.childName ?? 'Çocuk';
    // İsim yoksa listeden bulunur; şimdilik push
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          childId: pending.childId,
          childName: name,
        ),
      ),
    );
    // İsim düzeltmesi için children stream kullanmadan da olur
    svc.watchChildren().first.then((list) {
      final match = list.where((c) => c.uid == pending.childId);
      if (match.isEmpty || !mounted) return;
      // Ekran zaten açık; isim AppBar'da eski kalabilir — kritik değil
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();
    final nav = context.watch<ParentNav>();
    // Bildirimden gelince Mesaj sekmesi seçildiğinde aç
    if (nav.pendingChatChildId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openPending());
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.watch<AppLocale>().t('title_messages'))),
      body: StreamBuilder<List<ChildSummary>>(
        stream: svc.watchChildren(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Hata: ${snap.error}'));
          }
          final children = snap.data ?? [];
          if (children.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Mesajlaşmak için önce bir çocuk aileye katılmalı.\n\n'
                  'Buradan “Nasılsın?” gibi anlık mesaj gönderebilirsin; '
                  'gelen her mesaj bildirimde görünür.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: children.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final c = children[i];
              return StreamBuilder<ChatMessage?>(
                stream: svc.watchLatestChatMessage(c.uid),
                builder: (context, lastSnap) {
                  final last = lastSnap.data;
                  return StreamBuilder<int>(
                    stream: svc.watchUnreadChatCount(c.uid),
                    builder: (context, unreadSnap) {
                      final unread = unreadSnap.data ?? 0;
                      final subtitle = last == null
                          ? 'Sohbete başla — Nasılsın? diye sor'
                          : chatPreviewText(
                              last.type,
                              last.text,
                              routeName: last.routeName,
                            );
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF2D6A4F),
                          child: unread > 0
                              ? Text(
                                  unread > 9 ? '9+' : '$unread',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                )
                              : const Icon(Icons.child_care,
                                  color: Colors.white),
                        ),
                        title: Text(c.name,
                            style: TextStyle(
                              fontWeight: unread > 0
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                            )),
                        subtitle: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ChatThreadScreen(
                                childId: c.uid,
                                childName: c.name,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

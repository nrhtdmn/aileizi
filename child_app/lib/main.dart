import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'brand.dart';
import 'l10n/app_locale.dart';
import 'services/background_service.dart';
import 'services/child_notification_service.dart';
import 'screens/join_screen.dart';
import 'screens/child_home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await _requestPermissions();
  await ChildNotificationService.instance.init();
  await initBackgroundService();

  if (FirebaseAuth.instance.currentUser == null) {
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
  }

  final locale = AppLocale();
  await locale.load();
  runApp(ChildApp(locale: locale));
}

Future<void> _requestPermissions() async {
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return;
  }
  // whileInUse → Always (ekran kapalı konum için)
  if (permission == LocationPermission.whileInUse) {
    await Geolocator.requestPermission();
  }
}

class ChildApp extends StatefulWidget {
  final AppLocale locale;

  const ChildApp({super.key, required this.locale});

  @override
  State<ChildApp> createState() => _ChildAppState();
}

class _ChildAppState extends State<ChildApp> {
  final _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Brand.childAccent,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );
    return ChangeNotifierProvider<AppLocale>.value(
      value: widget.locale,
      child: Consumer<AppLocale>(
        builder: (context, l10n, _) {
          return MaterialApp(
            navigatorKey: _navKey,
            title: Brand.fullName,
            debugShowCheckedModeBanner: false,
            locale: l10n.locale,
            supportedLocales: const [Locale('tr'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: base.copyWith(
              textTheme: GoogleFonts.nunitoTextTheme(base.textTheme),
              appBarTheme: AppBarTheme(
                backgroundColor: Brand.childAccent,
                foregroundColor: Colors.white,
                titleTextStyle: GoogleFonts.nunito(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            home: StreamBuilder<User?>(
              stream: FirebaseAuth.instance.authStateChanges(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Scaffold(
                    body: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF2A6F97), Color(0xFF4A90D9)],
                        ),
                      ),
                      child: const Center(
                        child:
                            CircularProgressIndicator(color: Colors.white),
                      ),
                    ),
                  );
                }
                final user = snapshot.data;
                if (user == null) {
                  return const JoinScreen(key: ValueKey('join-unauth'));
                }
                return _ChildProfileGate(uid: user.uid);
              },
            ),
          );
        },
      ),
    );
  }
}

class _ChildProfileGate extends StatelessWidget {
  const _ChildProfileGate({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snapshot.data?.data();
        final hasFamily = data?['role'] == 'child' &&
            (data?['familyId'] as String?)?.isNotEmpty == true;

        if (hasFamily) {
          return const ChildHomeScreen(key: ValueKey('child-home'));
        }
        return JoinScreen(key: ValueKey('join-$uid'));
      },
    );
  }
}

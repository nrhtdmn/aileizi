import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'brand.dart';
import 'l10n/app_locale.dart';
import 'services/firebase_service.dart';
import 'services/parent_nav.dart';
import 'services/notification_service.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await ParentNotificationService.instance.init();
  if (message.notification == null) {
    await ParentNotificationService.instance.showFromRemote(message);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await initializeDateFormatting('tr_TR', null);
  await initializeDateFormatting('en_US', null);
  await ParentNotificationService.instance.init();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  final locale = AppLocale();
  await locale.load();
  runApp(FamilyTrackerApp(locale: locale));
}

class FamilyTrackerApp extends StatefulWidget {
  final AppLocale locale;

  const FamilyTrackerApp({super.key, required this.locale});

  @override
  State<FamilyTrackerApp> createState() => _FamilyTrackerAppState();
}

class _FamilyTrackerAppState extends State<FamilyTrackerApp> {
  final _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Brand.parentAccent,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );
    return MultiProvider(
      providers: [
        Provider<FirebaseService>(create: (_) => FirebaseService()),
        ChangeNotifierProvider<ParentNav>(create: (_) => ParentNav()),
        ChangeNotifierProvider<AppLocale>.value(value: widget.locale),
      ],
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
                backgroundColor: Brand.parentAccent,
                foregroundColor: Colors.white,
                titleTextStyle: GoogleFonts.nunito(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            home: const AuthWrapper(),
          );
        },
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.read<FirebaseService>();
    return StreamBuilder(
      stream: service.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            body: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1B4332), Color(0xFF2D6A4F)],
                ),
              ),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
          );
        }
        if (snapshot.hasData) {
          return const HomeScreen();
        }
        return const AuthScreen();
      },
    );
  }
}

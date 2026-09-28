import 'package:flutter/material.dart';

import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/app_lock.dart';
import 'services/session.dart';
import 'theme/app_colors.dart';
import 'theme/theme_manager.dart';
import 'utils/loc.dart';

// TODO: once you run `flutterfire configure` (see README), uncomment these
// and call Firebase.initializeApp() in main() before runApp() — mirrors the
// Firebase.initializeApp() call in the Kotlin app's Application class.
// import 'package:firebase_core/firebase_core.dart';
// import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await Loc.load();
  await ThemeManager.load();
  await Session.load();
  // PosApplication.onCreate() mein AppLock.register(this) ke barabar.
  await AppLock.instance.register(loginBuilder: (_) => const LoginScreen());
  runApp(const AhDeveloperApp());
}

class AhDeveloperApp extends StatelessWidget {
  const AhDeveloperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Loc.language, ThemeManager.isDark]),
      builder: (context, _) {
        final lang = Loc.language.value;
        final dark = ThemeManager.isDark.value;
        final p = ThemeManager.palette;
        return MaterialApp(
          navigatorKey: AppLock.navigatorKey,
          // zabaan / theme badalne par saari screens dobara ban jayein
          key: ValueKey('$lang-$dark'),
          title: 'AH Developer — Kiryana Store',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            brightness: dark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: dark ? p.bg : AppColors.bg,
            colorSchemeSeed: AppColors.navy,
            fontFamily: 'Roboto',
          ),
          builder: (context, child) => Directionality(
            textDirection: lang == 'ur' ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          // Session hai to seedha dashboard, warna login/setup.
          home: Session.isLoggedIn ? const DashboardScreen() : const LoginScreen(),
        );
      },
    );
  }
}

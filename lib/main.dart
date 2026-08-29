import 'package:flutter/material.dart';

import 'screens/product_screen.dart';
import 'theme/app_colors.dart';

// TODO: once you run `flutterfire configure` (see README), uncomment these
// and call Firebase.initializeApp() in main() before runApp() — mirrors the
// Firebase.initializeApp() call in the Kotlin app's Application class.
// import 'package:firebase_core/firebase_core.dart';
// import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const AhDeveloperApp());
}

class AhDeveloperApp extends StatelessWidget {
  const AhDeveloperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AH Developer — Kiryana Store',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.bg,
        colorSchemeSeed: AppColors.navy,
        fontFamily: 'Roboto',
      ),
      // Product screen is the first ported screen (see chat history for the
      // rest of the plan: Purchase -> Sale -> Party -> History -> Reports).
      home: const ProductScreen(),
    );
  }
}

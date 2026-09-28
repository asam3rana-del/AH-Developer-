import 'package:flutter/material.dart';

import 'screens/product_screen.dart';
import 'screens/purchase_screen.dart';
import 'screens/sale_screen.dart';
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
      home: const RootNav(),
    );
  }
}

/// Simple bottom navigation between ported screens. As more screens land
/// (Sale, Party, History, Reports...) add them here.
class RootNav extends StatefulWidget {
  const RootNav({super.key});

  @override
  State<RootNav> createState() => _RootNavState();
}

class _RootNavState extends State<RootNav> {
  int _index = 0;

  static const _screens = [
    ProductScreen(),
    PurchaseScreen(),
    SaleScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Products'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Purchase'),
          NavigationDestination(icon: Icon(Icons.point_of_sale_outlined), selectedIcon: Icon(Icons.point_of_sale), label: 'Sale'),
        ],
      ),
    );
  }
}

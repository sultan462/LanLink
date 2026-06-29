import 'package:flutter/material.dart';

import 'src/Core.dart';
import 'src/pages/home_page.dart';
import 'src/pages/widgets/app_colors.dart';

void main() {
  runApp(LanLinkApp());
}

class LanLinkApp extends StatelessWidget {
  LanLinkApp({super.key});

  final Core _core = Core();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LanLink',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primaryBlue,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AppColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          foregroundColor: AppColors.navy,
          elevation: 0,
        ),
      ),
      home: HomePage(core: _core),
    );
  }
}

import 'package:flutter/material.dart';

enum AppLogoVariant { wordmark, mark }

/// Renders one of the LanLink logo PNGs from assets/logos/. Only the
/// "-light" PNG variants are used: they're the ones that read correctly on a
/// white background. The SVG variants would need an extra package to render.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.variant = AppLogoVariant.wordmark, this.height = 96});

  final AppLogoVariant variant;
  final double height;

  @override
  Widget build(BuildContext context) {
    final asset = switch (variant) {
      AppLogoVariant.wordmark => 'assets/logos/lanlink-logo-light.png',
      AppLogoVariant.mark => 'assets/logos/lanlink-icon-light.png',
    };
    return Image.asset(asset, height: height);
  }
}

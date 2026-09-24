import 'package:flutter/material.dart';

/// Aileİzi marka sabitleri
class Brand {
  static const name = 'Aileİzi';
  static const tagline = 'Aile ve Çocuk Takip';
  static const fullName = 'Aileİzi: Aile ve Çocuk Takip';
  static const parentSubtitle = 'Ebeveyn';
  static const childSubtitle = 'Çocuk';

  static const parentPrimary = Color(0xFF1B4332);
  static const parentAccent = Color(0xFF2D6A4F);
  static const childPrimary = Color(0xFF3A7CA5);
  static const childAccent = Color(0xFF4A90D9);
}

/// Giriş / katıl ekranlarında marka başlığı
class BrandHero extends StatelessWidget {
  final String logoAsset;
  final String subtitle;
  final Color titleColor;
  final Color subtitleColor;

  const BrandHero({
    super.key,
    required this.logoAsset,
    required this.subtitle,
    this.titleColor = Colors.white,
    this.subtitleColor = Colors.white70,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Image.asset(
            logoAsset,
            width: 112,
            height: 112,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          Brand.name,
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: titleColor,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          Brand.tagline,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: subtitleColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 13,
            color: subtitleColor.withOpacity(0.85),
          ),
        ),
      ],
    );
  }
}

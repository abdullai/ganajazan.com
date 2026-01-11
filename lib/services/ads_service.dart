import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:aqar_user/models.dart';

class AdsService {
  /// إظهار إعلانات اليمين فقط على الويب + شاشات كبيرة
  static bool shouldShowSideAds(double width) {
    if (!kIsWeb) return false;
    return width >= 900;
  }

  /// الدالة التي يحتاجها LoginScreen (كانت تسبب الخطأ)
  static Future<List<AdItem>> loadAds({String? lang}) async {
    // لاحقًا: اجلب الإعلانات من لوحة الإدارة/API/Firestore...
    // الآن: مصدر تجريبي محلي
    return demoAds();
  }

  /// بيانات تجريبية
  static List<AdItem> demoAds() {
    return [
      AdItem(
        id: 'ad-1',
        titleAr: 'إعلان تجريبي 1',
        titleEn: 'Demo Ad 1',
        subtitleAr: 'هذا نص تجريبي للإعلان',
        subtitleEn: 'This is a demo ad text',
        assetImage: 'assets/logo.png',
        enabled: true,
      ),
      AdItem(
        id: 'ad-2',
        titleAr: 'إعلان تجريبي 2',
        titleEn: 'Demo Ad 2',
        subtitleAr: 'إعلان خاص بالتطبيق',
        subtitleEn: 'App internal announcement',
        assetImage: 'assets/splashscreen.png',
        enabled: true,
      ),
      AdItem(
        id: 'ad-3',
        titleAr: 'إعلان تجريبي 3',
        titleEn: 'Demo Ad 3',
        subtitleAr: 'قريبًا ميزات جديدة',
        subtitleEn: 'New features soon',
        assetImage: 'assets/logo.png',
        enabled: false,
      ),
    ];
  }
}


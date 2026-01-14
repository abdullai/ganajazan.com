// lib/models/ad_item.dart

class AdItem {
  final String id;

  String titleAr;
  String titleEn;

  String subtitleAr;
  String subtitleEn;

  /// ✅ إما صورة من الأصول (assets/...) أو URL من قاعدة البيانات
  /// - إذا كانت URL: ضعها هنا
  /// - إذا كانت Asset: ضعها في assetImage
  String? imageUrl;
  String? linkUrl;

  String assetImage;
  bool enabled;

  AdItem({
    required this.id,
    required this.titleAr,
    required this.titleEn,
    required this.subtitleAr,
    required this.subtitleEn,
    required this.assetImage,
    this.imageUrl,
    this.linkUrl,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'titleAr': titleAr,
        'titleEn': titleEn,
        'subtitleAr': subtitleAr,
        'subtitleEn': subtitleEn,
        'assetImage': assetImage,
        'imageUrl': imageUrl,
        'linkUrl': linkUrl,
        'enabled': enabled,
      };

  factory AdItem.fromJson(Map<String, dynamic> j) => AdItem(
        id: (j['id'] ?? '').toString(),
        titleAr: (j['titleAr'] ?? '').toString(),
        titleEn: (j['titleEn'] ?? '').toString(),
        subtitleAr: (j['subtitleAr'] ?? '').toString(),
        subtitleEn: (j['subtitleEn'] ?? '').toString(),
        assetImage: (j['assetImage'] ?? '').toString(),
        imageUrl: (j['imageUrl'] as String?)?.trim().isEmpty == true ? null : (j['imageUrl'] as String?)?.trim(),
        linkUrl: (j['linkUrl'] as String?)?.trim().isEmpty == true ? null : (j['linkUrl'] as String?)?.trim(),
        enabled: (j['enabled'] ?? true) as bool,
      );
}

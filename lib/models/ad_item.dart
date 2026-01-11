class AdItem {
  final String id;

  String titleAr;
  String titleEn;

  String subtitleAr;
  String subtitleEn;

  String assetImage;
  bool enabled;

  AdItem({
    required this.id,
    required this.titleAr,
    required this.titleEn,
    required this.subtitleAr,
    required this.subtitleEn,
    required this.assetImage,
    required this.enabled,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'titleAr': titleAr,
        'titleEn': titleEn,
        'subtitleAr': subtitleAr,
        'subtitleEn': subtitleEn,
        'assetImage': assetImage,
        'enabled': enabled,
      };

  factory AdItem.fromJson(Map<String, dynamic> j) => AdItem(
        id: j['id'] as String,
        titleAr: j['titleAr'] as String,
        titleEn: j['titleEn'] as String,
        subtitleAr: j['subtitleAr'] as String,
        subtitleEn: j['subtitleEn'] as String,
        assetImage: j['assetImage'] as String,
        enabled: (j['enabled'] ?? true) as bool,
      );
}

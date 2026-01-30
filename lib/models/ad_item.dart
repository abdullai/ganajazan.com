// lib/models/ad_item.dart

/// نموذج إعلان/عقار موحّد لاستخدامه في القائمة (Dashboard) وفي التفاصيل.
///
/// ✅ متوافق مع نسختك الحالية (Backward compatible):
/// - يحافظ على الحقول القديمة كما هي.
/// - يضيف حقول “العقار” المطلوبة في مثال.txt بشكل Optional (لا تكسر بياناتك الحالية).
///
/// 🎯 الهدف:
/// - بطاقة إعلان/عقار تعرض: صورة + عنوان + مدينة/حي + مساحة + سعر + حالة + موثوقية الرخصة.
/// - دعم RTL/LTR يتم في الـ UI، هنا فقط بيانات.
///
/// ملاحظة:
/// - هذا الموديل يُستخدم للإعلانات/العقارات في الواجهة.
/// - يمكن تغذيته من Supabase من جدول ads/properties أو View موحّد لاحقًا.
class AdItem {
  // ===== الأساسي =====
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

  // ===== حقول “العقار” المطلوبة (New / Optional) =====

  /// معرف العقار الحقيقي (إن كان الإعلان يمثل عقارًا)
  String? propertyId;

  /// المدينة
  String? cityAr;
  String? cityEn;

  /// الحي
  String? districtAr;
  String? districtEn;

  /// المساحة بالمتر
  double? areaSqm;

  /// السعر (إن وجد) - تركته num لتفادي اختلاف int/double
  num? price;

  /// العملة (SAR افتراضيًا)
  String currency;

  /// حالة العقار: available | reserved | sold | unknown
  /// - تُستخدم لمنع الحجز وإظهار الشارة.
  String status;

  /// رقم رخصة الإعلان (REGA)
  String? licenseNumber;

  /// هل الرخصة موثوقة/تم التحقق منها
  bool isVerified;

  /// وقت آخر تحقق (اختياري)
  DateTime? verifiedAt;

  /// صور العقار (للواجهة: بطاقة + تفاصيل)
  /// - إن كانت فارغة يستخدم imageUrl/assetImage
  List<String> images;

  /// مصدر حالة العقار (اختياري): internal | external | mixed
  String statusSource;

  /// سبب عدم التوفر/ملاحظة خارجية (اختياري)
  String? statusNote;

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

    // new fields
    this.propertyId,
    this.cityAr,
    this.cityEn,
    this.districtAr,
    this.districtEn,
    this.areaSqm,
    this.price,
    this.currency = 'SAR',
    this.status = 'unknown',
    this.licenseNumber,
    this.isVerified = false,
    this.verifiedAt,
    List<String>? images,
    this.statusSource = 'internal',
    this.statusNote,
  }) : images = images ?? const [];

  /// مساعد: اختيار عنوان مناسب حسب اللغة
  String title(String lang) => (lang == 'ar') ? titleAr : titleEn;

  /// مساعد: اختيار وصف مناسب حسب اللغة
  String subtitle(String lang) => (lang == 'ar') ? subtitleAr : subtitleEn;

  /// مساعد: المدينة/الحي حسب اللغة
  String? city(String lang) => (lang == 'ar') ? cityAr : cityEn;
  String? district(String lang) => (lang == 'ar') ? districtAr : districtEn;

  /// مساعد: أفضل صورة للبطاقة
  /// - images[0] إن وجدت
  /// - else imageUrl
  /// - else assetImage (تتعامل معها الواجهة)
  String? bestCoverUrl() {
    if (images.isNotEmpty) return images.first.trim().isEmpty ? null : images.first.trim();
    final u = imageUrl?.trim();
    if (u != null && u.isNotEmpty) return u;
    return null; // إذا null فالواجهة تستخدم assetImage
  }

  /// مساعد: هل يمكن حجز العقار؟
  bool get isReservable => status == 'available';

  /// مساعد: هل العقار غير متاح
  bool get isUnavailable => status == 'reserved' || status == 'sold';

  Map<String, dynamic> toJson() => {
        // القديم
        'id': id,
        'titleAr': titleAr,
        'titleEn': titleEn,
        'subtitleAr': subtitleAr,
        'subtitleEn': subtitleEn,
        'assetImage': assetImage,
        'imageUrl': imageUrl,
        'linkUrl': linkUrl,
        'enabled': enabled,

        // الجديد
        'propertyId': propertyId,
        'cityAr': cityAr,
        'cityEn': cityEn,
        'districtAr': districtAr,
        'districtEn': districtEn,
        'areaSqm': areaSqm,
        'price': price,
        'currency': currency,
        'status': status,
        'licenseNumber': licenseNumber,
        'isVerified': isVerified,
        'verifiedAt': verifiedAt?.toIso8601String(),
        'images': images,
        'statusSource': statusSource,
        'statusNote': statusNote,
      };

  factory AdItem.fromJson(Map<String, dynamic> j) {
    // old parsing helpers
    String? _trimOrNull(dynamic v) {
      final s = (v as String?)?.trim();
      if (s == null || s.isEmpty) return null;
      return s;
    }

    double? _toDoubleOrNull(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      final s = v.toString().trim();
      if (s.isEmpty) return null;
      return double.tryParse(s);
    }

    num? _toNumOrNull(dynamic v) {
      if (v == null) return null;
      if (v is num) return v;
      final s = v.toString().trim();
      if (s.isEmpty) return null;
      return num.tryParse(s);
    }

    DateTime? _toDateTimeOrNull(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      final s = v.toString().trim();
      if (s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    List<String> _toStringList(dynamic v) {
      if (v == null) return const [];
      if (v is List) {
        return v
            .map((e) => e?.toString().trim())
            .where((e) => e != null && e!.isNotEmpty)
            .map((e) => e!)
            .toList();
      }
      return const [];
    }

    return AdItem(
      // القديم (لا نكسره)
      id: (j['id'] ?? '').toString(),
      titleAr: (j['titleAr'] ?? '').toString(),
      titleEn: (j['titleEn'] ?? '').toString(),
      subtitleAr: (j['subtitleAr'] ?? '').toString(),
      subtitleEn: (j['subtitleEn'] ?? '').toString(),
      assetImage: (j['assetImage'] ?? '').toString(),
      imageUrl: _trimOrNull(j['imageUrl']),
      linkUrl: _trimOrNull(j['linkUrl']),
      enabled: (j['enabled'] ?? true) as bool,

      // الجديد
      propertyId: _trimOrNull(j['propertyId']),
      cityAr: _trimOrNull(j['cityAr']),
      cityEn: _trimOrNull(j['cityEn']),
      districtAr: _trimOrNull(j['districtAr']),
      districtEn: _trimOrNull(j['districtEn']),
      areaSqm: _toDoubleOrNull(j['areaSqm'] ?? j['area'] ?? j['sqm']),
      price: _toNumOrNull(j['price']),
      currency: (j['currency'] ?? 'SAR').toString(),
      status: (j['status'] ?? 'unknown').toString(),
      licenseNumber: _trimOrNull(j['licenseNumber'] ?? j['license_number']),
      isVerified: (j['isVerified'] ?? j['is_verified'] ?? false) as bool,
      verifiedAt: _toDateTimeOrNull(j['verifiedAt'] ?? j['verified_at']),
      images: _toStringList(j['images']),
      statusSource: (j['statusSource'] ?? j['status_source'] ?? 'internal').toString(),
      statusNote: _trimOrNull(j['statusNote'] ?? j['status_note']),
    );
  }
}

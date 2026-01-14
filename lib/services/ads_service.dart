// lib/services/ads_service.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aqar_user/models.dart';

class AdsService {
  static SupabaseClient get _sb => Supabase.instance.client;

  /// إظهار إعلانات اليمين فقط على الويب + شاشات كبيرة
  static bool shouldShowSideAds(double width) {
    if (!kIsWeb) return false;
    return width >= 900;
  }

  // =========================================================
  // 1) LOAD ADS (Login / Home) - from DB with safe fallback
  // =========================================================

  /// تحميل إعلانات نشطة حسب اللغة والمنصة.
  /// ملاحظة: القراءة لا تحتاج Session لأن عندك policy:
  /// (is_active=true and deleted_at is null)
  static Future<List<AdItem>> loadAds({String? lang}) async {
    final isAr = (lang ?? 'ar').toLowerCase().startsWith('ar');

    try {
      final isWeb = kIsWeb;

      final rows = await _sb
          .from('ads')
          .select(
            'id,title,image_url,link_url,show_on_web,show_on_app,is_active,deleted_at,'
            'title_ar,title_en,subtitle_ar,subtitle_en,created_at,'
            'edit_count,max_edits,created_by',
          )
          .eq('is_active', true)
          // ✅ FIX: postgrest 2.6.0: لا eq(null) ولا is_()
          .filter('deleted_at', 'is', 'null') // ✅ deleted_at IS NULL
          .eq(isWeb ? 'show_on_web' : 'show_on_app', true)
          .order('created_at', ascending: false)
          .limit(50);

      final list = <AdItem>[];
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);

        final id = (m['id'] ?? '').toString();
        if (id.isEmpty) continue;

        // عنوان + وصف حسب اللغة (مع fallback ذكي)
        final titleAr = (m['title_ar'] ?? m['title'] ?? '').toString();
        final titleEn = (m['title_en'] ?? m['title'] ?? '').toString();
        final subAr = (m['subtitle_ar'] ?? '').toString();
        final subEn = (m['subtitle_en'] ?? '').toString();

        // الصور في DB هنا URL (image_url)
        final imageUrl = (m['image_url'] ?? '').toString();
        final linkUrl = (m['link_url'] ?? '').toString();

        list.add(
          AdItem(
            id: id,
            titleAr: titleAr.isEmpty ? (isAr ? 'إعلان' : 'Ad') : titleAr,
            titleEn: titleEn.isEmpty ? (isAr ? 'إعلان' : 'Ad') : titleEn,
            subtitleAr: subAr,
            subtitleEn: subEn,
            // لو عندك URL من DB نخزنه هنا
            imageUrl: imageUrl.isEmpty ? null : imageUrl,
            linkUrl: linkUrl.isEmpty ? null : linkUrl,
            // لو ما فيه URL نترك assetImage فاضي (يمكن واجهتك تتعامل مع هذا)
            assetImage: '',
            enabled: true,
          ),
        );
      }

      // إذا لا يوجد إعلانات في DB، ارجع Demo بدل شاشة فاضية
      return list.isEmpty ? demoAds() : list;
    } catch (_) {
      // أي مشكلة (شبكة/صلاحيات/...) => fallback demo
      return demoAds();
    }
  }

  // =========================================================
  // 2) CREATOR ACTIONS (requires Session)
  //    insert + update with 3 edits max
  // =========================================================

  static bool get hasSession => _sb.auth.currentSession != null;

  static String? get currentUid => _sb.auth.currentUser?.id;

  /// إضافة إعلان من المستخدم (يتطلب تسجيل دخول).
  /// created_by سيتم ضبطه في Trigger تلقائيًا.
  static Future<Map<String, dynamic>> createAd({
    required String title,
    String? titleAr,
    String? titleEn,
    String? subtitleAr,
    String? subtitleEn,
    String? imageUrl,
    String? linkUrl,
    bool showOnWeb = false,
    bool showOnApp = true,
    bool isActive = true,
  }) async {
    if (!hasSession) {
      throw const AuthException('Not logged in');
    }

    final payload = <String, dynamic>{
      'title': title,
      'title_ar': titleAr,
      'title_en': titleEn,
      'subtitle_ar': subtitleAr,
      'subtitle_en': subtitleEn,
      'image_url': imageUrl,
      'link_url': linkUrl,
      'show_on_web': showOnWeb,
      'show_on_app': showOnApp,
      'is_active': isActive,
      // لا ترسل created_by/edit_count/max_edits/deleted_* (محمي)
    };

    final row = await _sb.from('ads').insert(payload).select().single();
    return Map<String, dynamic>.from(row);
  }

  /// تحديث إعلان (يتطلب تسجيل دخول) وسيحسب edit_count تلقائيًا في Trigger.
  /// إذا وصلت حد التعديل، Supabase سيعيد خطأ "Edit limit reached (3)."
  static Future<Map<String, dynamic>> updateAd({
    required String adId,
    String? title,
    String? titleAr,
    String? titleEn,
    String? subtitleAr,
    String? subtitleEn,
    String? imageUrl,
    String? linkUrl,
    bool? showOnWeb,
    bool? showOnApp,
    bool? isActive,
  }) async {
    if (!hasSession) {
      throw const AuthException('Not logged in');
    }

    final patch = <String, dynamic>{};
    if (title != null) patch['title'] = title;
    if (titleAr != null) patch['title_ar'] = titleAr;
    if (titleEn != null) patch['title_en'] = titleEn;
    if (subtitleAr != null) patch['subtitle_ar'] = subtitleAr;
    if (subtitleEn != null) patch['subtitle_en'] = subtitleEn;
    if (imageUrl != null) patch['image_url'] = imageUrl;
    if (linkUrl != null) patch['link_url'] = linkUrl;
    if (showOnWeb != null) patch['show_on_web'] = showOnWeb;
    if (showOnApp != null) patch['show_on_app'] = showOnApp;
    if (isActive != null) patch['is_active'] = isActive;

    if (patch.isEmpty) {
      final row = await _sb.from('ads').select().eq('id', adId).single();
      return Map<String, dynamic>.from(row);
    }

    final row =
        await _sb.from('ads').update(patch).eq('id', adId).select().single();
    return Map<String, dynamic>.from(row);
  }

  /// قائمة إعلانات المستخدم الحالي (لصفحة "إعلاناتي") + المتبقي
  static Future<List<Map<String, dynamic>>> loadMyAds() async {
    if (!hasSession) {
      throw const AuthException('Not logged in');
    }
    final uid = currentUid;
    if (uid == null) throw const AuthException('No user');

    final rows = await _sb
        .from('ads')
        .select(
          'id,title,title_ar,title_en,subtitle_ar,subtitle_en,'
          'image_url,link_url,show_on_web,show_on_app,is_active,created_at,'
          'edit_count,max_edits,created_by,deleted_at',
        )
        .eq('created_by', uid)
        .order('created_at', ascending: false);

    final out = <Map<String, dynamic>>[];
    for (final r in (rows as List)) {
      final m = Map<String, dynamic>.from(r as Map);
      final editCount = (m['edit_count'] ?? 0) as int;
      final maxEdits = (m['max_edits'] ?? 3) as int;
      out.add({
        ...m,
        'edits_remaining': (maxEdits - editCount),
      });
    }
    return out;
  }

  // =========================================================
  // 3) DELETE REQUESTS (user) - cannot delete ads directly
  // =========================================================

  static Future<Map<String, dynamic>> requestDelete({
    required String adId,
    required String reason,
  }) async {
    if (!hasSession) {
      throw const AuthException('Not logged in');
    }
    final uid = currentUid;
    if (uid == null) throw const AuthException('No user');

    final row = await _sb
        .from('ads_delete_requests')
        .insert({
          'ad_id': adId,
          'requester_id': uid,
          'reason': reason,
          // status default = pending
        })
        .select()
        .single();

    return Map<String, dynamic>.from(row);
  }

  static Future<List<Map<String, dynamic>>> loadMyDeleteRequests() async {
    if (!hasSession) {
      throw const AuthException('Not logged in');
    }
    final uid = currentUid;
    if (uid == null) throw const AuthException('No user');

    final rows = await _sb
        .from('ads_delete_requests')
        .select('id,ad_id,reason,status,admin_note,decided_at,created_at')
        .eq('requester_id', uid)
        .order('created_at', ascending: false);

    return (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // =========================================================
  // 4) Demo fallback
  // =========================================================

  static List<AdItem> demoAds() {
    return [
      AdItem(
        id: 'ad-1',
        titleAr: 'إعلان تجريبي 1',
        titleEn: 'Demo Ad 1',
        subtitleAr: 'هذا نص تجريبي للإعلان',
        subtitleEn: 'This is a demo ad text',
        assetImage: 'assets/logo.png',
        imageUrl: null,
        linkUrl: null,
        enabled: true,
      ),
      AdItem(
        id: 'ad-2',
        titleAr: 'إعلان تجريبي 2',
        titleEn: 'Demo Ad 2',
        subtitleAr: 'إعلان خاص بالتطبيق',
        subtitleEn: 'App internal announcement',
        assetImage: 'assets/splashscreen.png',
        imageUrl: null,
        linkUrl: null,
        enabled: true,
      ),
      AdItem(
        id: 'ad-3',
        titleAr: 'إعلان تجريبي 3',
        titleEn: 'Demo Ad 3',
        subtitleAr: 'قريبًا ميزات جديدة',
        subtitleEn: 'New features soon',
        assetImage: 'assets/logo.png',
        imageUrl: null,
        linkUrl: null,
        enabled: false,
      ),
    ];
  }
}

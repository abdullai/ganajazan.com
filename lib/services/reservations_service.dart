// lib/services/reservations_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class ReservationItem {
  /// ملاحظة: هذا "id" في التطبيق = reservation_id في قاعدة البيانات
  final String id;
  final String propertyId;
  final String status;
  final DateTime expiresAt;

  /// ✅ التسعير (محسوب من DB عبر Trigger)
  final double basePrice;
  final double platformFeeAmount; // 5%
  final double extraFeeAmount; // 2.5%
  final double totalAmount;

  /// ✅ الاسم الأول + الأخير (أو fallback) للحاجز
  final String? reserverName;

  /// ✅ ربط اختياري بمحادثة مرتبطة بالحجز/العقار
  final String? conversationId;

  ReservationItem({
    required this.id,
    required this.propertyId,
    required this.status,
    required this.expiresAt,
    required this.basePrice,
    required this.platformFeeAmount,
    required this.extraFeeAmount,
    required this.totalAmount,
    this.reserverName,
    this.conversationId,
  });

  String get expiresAtIso => expiresAt.toIso8601String();
}

class ReservationsService {
  static final SupabaseClient _sb = Supabase.instance.client;

  static double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  static String _s(dynamic v) => (v ?? '').toString().trim();
  static bool _isPostgresUniqueViolation(PostgrestException e) => e.code == '23505';

  // ===========================================================================
  // 1) إنشاء الحجز + (اختياري) إنشاء/إرجاع محادثة العقار
  // ===========================================================================

  /// ✅ إنشاء حجز 72 ساعة
  /// يرجع true إذا تم الحجز، و false إذا الإعلان محجوز مسبقاً (unique index).
  ///
  /// مهم: نرسل فقط base_price (والباقي يحسبه Trigger في DB)
  ///
  /// ✅ ربط الدردشة:
  /// - createConversation=true => ينشئ/يجلب conversation(kind='property') لهذا المستخدم + property
  /// - ثم يحدّث reservation_id داخل conversations إن كان فارغاً (اختياري)
  static Future<bool> createReservation({
    required String userId,
    required String propertyId,
    required double basePrice,
    bool createConversation = true,
    String? conversationTitle,
  }) async {
    try {
      final expiresAt = DateTime.now().add(const Duration(hours: 72));

      final inserted = await _sb
          .from('reservations')
          .insert({
            'user_id': userId,
            'property_id': propertyId,
            'status': 'pending',
            'expires_at': expiresAt.toUtc().toIso8601String(),
            'base_price': basePrice, // ✅ فقط
          })
          .select('reservation_id')
          .single();

      final reservationId = _s(inserted['reservation_id']);

      if (createConversation && reservationId.isNotEmpty) {
        // best-effort: لا نكسر الحجز لو فشل الربط
        try {
          await getOrCreatePropertyConversation(
            propertyId: propertyId,
            reservationId: reservationId,
            title: conversationTitle,
          );
        } catch (_) {}
      }

      return true;
    } on PostgrestException catch (e) {
      if (_isPostgresUniqueViolation(e)) return false;
      rethrow;
    } catch (_) {
      return false;
    }
  }

  /// ✅ إلغاء حجز (لسلة المستخدم)
  static Future<void> cancelReservation(String reservationId) async {
    await _sb
        .from('reservations')
        .update({'status': 'cancelled'})
        .eq('reservation_id', reservationId);
  }

  // ===========================================================================
  // 2) محادثات العقار (conversations)
  // ===========================================================================

  /// ✅ يجلب أو ينشئ conversation(kind='property') للمستخدم الحالي (auth.uid)
  ///
  /// - يعتمد على uniq_conv_property_user لمنع التكرار
  /// - يربط reservation_id إذا مررته (تحديث للمحادثة) إن كان فارغاً
  /// - يحدد counterparty_id تلقائياً من properties.owner_id
  ///
  /// يرجع conversationId
  static Future<String> getOrCreatePropertyConversation({
    required String propertyId,
    String? reservationId,
    String? title,
  }) async {
    final uid = _sb.auth.currentUser?.id ?? '';
    if (uid.isEmpty) throw Exception('Auth required');

    // 1) owner_id + title fallback
    final prop = await _sb
        .from('properties')
        .select('owner_id, title')
        .eq('id', propertyId)
        .single();

    final ownerId = _s(prop['owner_id']);
    final propTitle = _s(prop['title']);

    if (ownerId.isEmpty) throw Exception('Property owner not found');
    if (ownerId == uid) throw Exception('Cannot chat with yourself');

    // 2) find existing
    final existing = await _sb
        .from('conversations')
        .select('id, reservation_id')
        .eq('kind', 'property')
        .eq('property_id', propertyId)
        .eq('user_id', uid)
        .limit(1)
        .maybeSingle();

    if (existing != null) {
      final cid = _s(existing['id']);
      if (cid.isEmpty) throw Exception('Invalid conversation row');

      // attach reservation_id if missing
      final curRes = _s(existing['reservation_id']);
      final wantedRes = (reservationId ?? '').trim();
      if (curRes.isEmpty && wantedRes.isNotEmpty) {
        await _sb.from('conversations').update({
          'reservation_id': wantedRes,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', cid);
      }
      return cid;
    }

    // 3) create
    final wantedRes = (reservationId ?? '').trim();
    final inserted = await _sb
        .from('conversations')
        .insert({
          'kind': 'property',
          'property_id': propertyId,
          'reservation_id': wantedRes.isEmpty ? null : wantedRes,
          'user_id': uid,
          'counterparty_id': ownerId,
          'title': (title ?? propTitle).trim().isEmpty
              ? 'Property chat'
              : (title ?? propTitle).trim(),
        })
        .select('id')
        .single();

    return _s(inserted['id']);
  }

  // ===========================================================================
  // 3) تحميل السلة / تحميل حجوزات عقاراتي + conversation_id لكل عنصر
  // ===========================================================================

  /// ✅ سلة المستخدم (حجوزاتي)
  static Future<List<ReservationItem>> loadMyCart(String userId) async {
    final res = await _sb
        .from('reservations')
        .select(
          'reservation_id, property_id, status, expires_at, base_price, platform_fee_amount, extra_fee_amount, total_amount',
        )
        .eq('user_id', userId)
        .inFilter('status', ['active', 'pending'])
        .order('created_at', ascending: false);

    final rows = (res as List).cast<Map<String, dynamic>>();
    if (rows.isEmpty) return const [];

    // map property_id -> conversation id (for this user)
    final propIds = rows
        .map((r) => _s(r['property_id']))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();

    final convMap = await _fetchConversationIdsForUserProperties(
      userId: userId,
      propertyIds: propIds,
    );

    return rows.map<ReservationItem>((r) {
      final pid = _s(r['property_id']);
      return ReservationItem(
        id: _s(r['reservation_id']),
        propertyId: pid,
        status: _s(r['status']),
        expiresAt: DateTime.parse(_s(r['expires_at'])).toLocal(),
        basePrice: _toDouble(r['base_price']),
        platformFeeAmount: _toDouble(r['platform_fee_amount']),
        extraFeeAmount: _toDouble(r['extra_fee_amount']),
        totalAmount: _toDouble(r['total_amount']),
        conversationId: convMap[pid],
      );
    }).toList();
  }

  /// ✅ حجوزات على إعلاناتي (للمعلن)
  static Future<List<ReservationItem>> loadOnMyProperties({
    String lang = 'ar',
  }) async {
    final res = await _sb.from('reservations').select('''
          reservation_id,
          property_id,
          user_id,
          status,
          expires_at,
          base_price,
          platform_fee_amount,
          extra_fee_amount,
          total_amount,
          users_profiles(
            full_name,
            name,
            username,
            email,
            full_name_ar,
            full_name_en,
            first_name_ar,
            fourth_name_ar,
            first_name_en,
            fourth_name_en
          )
        ''').order('created_at', ascending: false);

    final rows = (res as List).cast<Map<String, dynamic>>();
    if (rows.isEmpty) return const [];

    String pick(dynamic v) => (v?.toString() ?? '').trim();

    String? buildName(Map<String, dynamic>? u) {
      if (u == null) return null;

      if (lang == 'ar') {
        final fl = '${pick(u['first_name_ar'])} ${pick(u['fourth_name_ar'])}'.trim();
        if (fl.isNotEmpty) return fl;

        final ar = pick(u['full_name_ar']);
        if (ar.isNotEmpty) return ar;
      } else {
        final fl = '${pick(u['first_name_en'])} ${pick(u['fourth_name_en'])}'.trim();
        if (fl.isNotEmpty) return fl;

        final en = pick(u['full_name_en']);
        if (en.isNotEmpty) return en;
      }

      final full = pick(u['full_name']);
      if (full.isNotEmpty) return full;

      final name = pick(u['name']);
      if (name.isNotEmpty) return name;

      final username = pick(u['username']);
      if (username.isNotEmpty) return username;

      final email = pick(u['email']);
      if (email.isNotEmpty) return email;

      return null;
    }

    // conversation map for (property_id, reserver_user_id)
    final keys = <String>{}; // "$propertyId|$userId"
    for (final r in rows) {
      final pid = _s(r['property_id']);
      final uid = _s(r['user_id']);
      if (pid.isNotEmpty && uid.isNotEmpty) keys.add('$pid|$uid');
    }

    final convPairsMap = await _fetchConversationIdsForPairs(keys.toList());

    return rows.map<ReservationItem>((r) {
      final u = (r['users_profiles'] as Map?)?.cast<String, dynamic>();
      final name = buildName(u);

      final pid = _s(r['property_id']);
      final reserverId = _s(r['user_id']);
      final convId = convPairsMap['$pid|$reserverId'];

      return ReservationItem(
        id: _s(r['reservation_id']),
        propertyId: pid,
        status: _s(r['status']),
        expiresAt: DateTime.parse(_s(r['expires_at'])).toLocal(),
        basePrice: _toDouble(r['base_price']),
        platformFeeAmount: _toDouble(r['platform_fee_amount']),
        extraFeeAmount: _toDouble(r['extra_fee_amount']),
        totalAmount: _toDouble(r['total_amount']),
        reserverName: name,
        conversationId: convId,
      );
    }).toList();
  }

  // ===========================================================================
  // 4) Helpers
  // ===========================================================================

  static Future<Map<String, String>> _fetchConversationIdsForUserProperties({
    required String userId,
    required List<String> propertyIds,
  }) async {
    if (propertyIds.isEmpty) return {};

    final data = await _sb
        .from('conversations')
        .select('id, property_id')
        .eq('kind', 'property')
        .eq('user_id', userId)
        .inFilter('property_id', propertyIds);

    final rows = (data as List).cast<Map>();
    final out = <String, String>{};
    for (final r in rows) {
      final pid = _s(r['property_id']);
      final cid = _s(r['id']);
      if (pid.isNotEmpty && cid.isNotEmpty) out[pid] = cid;
    }
    return out;
  }

  /// keys: "$propertyId|$userId"
  static Future<Map<String, String>> _fetchConversationIdsForPairs(List<String> keys) async {
    if (keys.isEmpty) return {};

    final propIds = <String>{};
    final userIds = <String>{};

    for (final k in keys) {
      final parts = k.split('|');
      if (parts.length != 2) continue;
      if (parts[0].trim().isNotEmpty) propIds.add(parts[0].trim());
      if (parts[1].trim().isNotEmpty) userIds.add(parts[1].trim());
    }

    if (propIds.isEmpty || userIds.isEmpty) return {};

    final data = await _sb
        .from('conversations')
        .select('id, property_id, user_id')
        .eq('kind', 'property')
        .inFilter('property_id', propIds.toList())
        .inFilter('user_id', userIds.toList());

    final rows = (data as List).cast<Map>();
    final out = <String, String>{};

    for (final r in rows) {
      final pid = _s(r['property_id']);
      final uid = _s(r['user_id']);
      final cid = _s(r['id']);
      if (pid.isEmpty || uid.isEmpty || cid.isEmpty) continue;
      out['$pid|$uid'] = cid;
    }

    return out;
  }
}

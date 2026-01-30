// lib/screens/user_dashboard.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../main.dart';
import '../models/property.dart';
import '../services/reservations_service.dart';
import '../services/fast_login_service.dart' as fl_service;
import 'add_property_page.dart' as addp;
import 'property_details_page.dart' as details;
import 'settings_page.dart';
import 'edit_property_page.dart';
import 'chat_page.dart';

class UserDashboard extends StatefulWidget {
  final String lang;
  const UserDashboard({super.key, required this.lang});

  @override
  State<UserDashboard> createState() => _UserDashboardState();
}

class _UserDashboardState extends State<UserDashboard> {
  static const Color _bankColor = Color(0xFF0F766E);
  final _sb = Supabase.instance.client;

  // Tabs:
  // 0 Home, 1 My Ads, 2 Cart, 3 Reservations (Offers), 4 Chat/Support (Unified)
  int _tabIndex = 0;

  // Search/sort
  String _searchQuery = '';
  String _sortBy = 'latest';
  Timer? _debounce;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isArabic => langNotifier.value == 'ar';
  String get _lang => langNotifier.value;

  // ✅ uid واحد فقط
  String get _uid => _sb.auth.currentUser?.id ?? '';
  bool get _isGuest => _uid.isEmpty;

  // =========================
  // Chat/Support Unified Context (داخل الداشبورد)
  // =========================
  String? _chatPropertyId;
  String? _chatReservationId;
  String? _chatTitle; // عنوان المحادثة (للعرض)
  String _chatMode = 'support'; // support | property | reservation

  void _openUnifiedChat({
    required String mode,
    String? propertyId,
    String? reservationId,
    String? title,
  }) {
    if (_isGuest) {
      _snackLoginRequired();
      return;
    }
    setState(() {
      _chatMode = mode;
      _chatPropertyId = propertyId;
      _chatReservationId = reservationId;
      _chatTitle = title;
      _tabIndex = 4;
    });
  }

  // ----------------------------
  // Caching and optimization
  // ----------------------------
  static const String _propertiesSelect = '''
    id,
    owner_id,
    username,
    title,
    description,
    city,
    type,
    area,
    price,
    is_auction,
    current_bid,
    views,
    status,
    created_at,
    latitude,
    longitude,
    property_images:property_images (
      path,
      sort_order
    )
  ''';

  final Map<String, Map<String, dynamic>> _profileCache = {};
  final Map<String, Property> _propertyCache = {};
  DateTime? _lastHomeFetch;
  DateTime? _lastMineFetch;
  DateTime? _lastCartFetch;
  static const Duration _cacheDuration = Duration(minutes: 1);

  // =========================
  // Loading / error states
  // =========================
  bool _loadingHome = true;
  bool _loadingMine = true;
  bool _loadingOffers = true;
  bool _loadingCart = true;

  String? _errorHome;
  String? _errorMine;
  String? _errorOffers;
  String? _errorCart;

  // =========================
  // Data (✅ mutable lists)
  // =========================
  List<Property> _all = <Property>[];
  List<Property> _mine = <Property>[];

  // ✅ مهم: خريطة إعلاناتي حسب id (مستخدمة في Offers)
  Map<String, Property> _myPropertyById = {};

  // Offers related to my properties (✅ mutable list)
  List<Map<String, dynamic>> _offers = <Map<String, dynamic>>[];

  // Cart (reservations rows) created by me (✅ mutable list)
  List<Map<String, dynamic>> _cart = <Map<String, dynamic>>[];
  Map<String, Property> _cartPropertyById = {};
  int _cartCount = 0;

  // Reservation overlays on listings
  final Map<String, Map<String, dynamic>> _activeReservationByPropertyId = {};

  // Badges
  int _offersCount = 0;

  // Favorites (persisted per Supabase uid)
  final Set<String> _favoriteIds = <String>{};
  bool _favoritesLoaded = false;

  bool _loggingOut = false;

  // =========================
  // Small helpers
  // =========================
  double _op(int alpha255) => (alpha255.clamp(0, 255)) / 255.0;

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  DateTime? _tryParseDt(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toLocal();
    if (v is String) return DateTime.tryParse(v)?.toLocal();
    return null;
  }

  String _timeAgo(DateTime dt, bool isAr) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes <= 1 ? 1 : diff.inMinutes;
      return isAr ? 'قبل $m دقيقة' : '$m min ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours <= 1 ? 1 : diff.inHours;
      return isAr ? 'قبل $h ساعة' : '$h hours ago';
    }
    final d = diff.inDays <= 1 ? 1 : diff.inDays;
    return isAr ? 'قبل $d يوم' : '$d days ago';
  }

  void _snackLoginRequired() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          _isArabic ? 'يجب تسجيل الدخول أولاً' : 'You must log in first',
        ),
      ),
    );
  }

  Future<void> _maybePromptFastLoginSetup() async {
    if (!_isMobile) return;

    final session = _sb.auth.currentSession;
    if (session == null) return;

    final hasLock = await fl_service.FastLoginService.hasAnyLockEnabled();
    if (hasLock) return;

    final st = await fl_service.FastLoginService.promptState();
    if (st == 'never' || st == 'done') return;

    if (!mounted) return;

    final res = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 10,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isArabic ? 'تفعيل الدخول السريع' : 'Enable Quick Login',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  _isArabic
                      ? 'لأمان أعلى وسرعة أكبر، يمكنك تفعيل PIN وبصمة الوجه/الإصبع.'
                      : 'For better security and faster access, enable PIN and biometrics.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx, 'enable'),
                    icon: const Icon(Icons.lock),
                    label: Text(_isArabic ? 'تفعيل الآن' : 'Enable now'),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, 'later'),
                        child: Text(_isArabic ? 'لاحقاً' : 'Later'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx, 'never'),
                        child: Text(_isArabic
                            ? 'عدم الإظهار مرة أخرى'
                            : 'Don\'t show again'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (res == null) return;

    if (res == 'never') {
      await fl_service.FastLoginService.setPromptState('never');
      return;
    }
    if (res == 'later') {
      await fl_service.FastLoginService.setPromptState('later');
      return;
    }

    if (res == 'enable') {
      await fl_service.FastLoginService.setPromptState('done');
      if (!mounted) return;
      Navigator.pushNamed(context, '/settings');
    }
  }

  // ---------- lifecycle ----------
  @override
  void initState() {
    super.initState();
    if (widget.lang.isNotEmpty && widget.lang != _lang) {
      langNotifier.value = widget.lang;
    }
    _reloadAll();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _maybePromptFastLoginSetup();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // =========================
  // Favorites persistence
  // =========================
  String _favKey(String uid) => 'fav_ids_$uid';

  Future<void> _loadFavoritesForUid() async {
    final uid = _uid;
    if (uid.isEmpty) {
      _favoriteIds.clear();
      _favoritesLoaded = true;
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_favKey(uid));
    _favoriteIds.clear();

    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
        _favoriteIds.addAll(list);
      } catch (_) {}
    }

    _favoritesLoaded = true;
    if (mounted) setState(() {});
  }

  Future<void> _saveFavoritesForUid() async {
    final uid = _uid;
    if (uid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_favKey(uid), jsonEncode(_favoriteIds.toList()));
  }

  bool _isFav(String id) => _favoriteIds.contains(id);

  Future<void> _toggleFav(String propertyId) async {
    if (_isGuest) return; // ✅ زائر: تعطيل المفضلة
    setState(() {
      if (_favoriteIds.contains(propertyId)) {
        _favoriteIds.remove(propertyId);
      } else {
        _favoriteIds.add(propertyId);
      }
    });
    await _saveFavoritesForUid();
  }

  // =========================
  // Data loading (Optimized)
  // =========================
  bool _shouldFetchHome() {
    if (_lastHomeFetch == null) return true;
    return DateTime.now().difference(_lastHomeFetch!) > _cacheDuration;
  }

  bool _shouldFetchMine() {
    if (_lastMineFetch == null) return true;
    return DateTime.now().difference(_lastMineFetch!) > _cacheDuration;
  }

  bool _shouldFetchCart() {
    if (_lastCartFetch == null) return true;
    return DateTime.now().difference(_lastCartFetch!) > _cacheDuration;
  }

  // NOTE (Security): We do NOT expire rows from client anymore.
  // Expiry should be handled by DB/Cron/Edge Function.
  bool _isStillValidReservationRow(Map<String, dynamic> r) {
    final st = (r['status'] ?? '').toString();
    if (st != 'active' && st != 'pending') return false;

    final ex = _tryParseDt(r['expires_at']);
    if (ex == null) return true;
    return ex.isAfter(DateTime.now());
  }

  Future<Map<String, Map<String, dynamic>>> _fetchProfilesByUserIds(
      List<String> userIds) async {
    if (userIds.isEmpty) return {};

    final uncachedIds =
        userIds.where((id) => !_profileCache.containsKey(id)).toList();

    if (uncachedIds.isEmpty) {
      return Map.fromEntries(
        userIds.map((id) => MapEntry(id, _profileCache[id]!)),
      );
    }

    try {
      final data = await _sb
          .from('users_profiles')
          .select(
              'user_id, username, full_name, full_name_ar, full_name_en, first_name_ar, fourth_name_ar, first_name_en, fourth_name_en')
          .inFilter('user_id', uncachedIds);

      final rows = (data as List).cast<Map>();
      for (final r in rows) {
        final uid = (r['user_id'] ?? '').toString();
        if (uid.isNotEmpty) {
          _profileCache[uid] = r.cast<String, dynamic>();
        }
      }

      final result = <String, Map<String, dynamic>>{};
      for (final id in userIds) {
        result[id] = _profileCache[id] ?? {};
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  String _displayNameFromProfile(Map<String, dynamic>? prof) {
    if (prof == null) return '';
    String pick(dynamic v) => (v?.toString() ?? '').trim();

    if (_isArabic) {
      final fl =
          '${pick(prof['first_name_ar'])} ${pick(prof['fourth_name_ar'])}'.trim();
      if (fl.isNotEmpty) return fl;
      final ar = pick(prof['full_name_ar']);
      if (ar.isNotEmpty) return ar;
    } else {
      final fl =
          '${pick(prof['first_name_en'])} ${pick(prof['fourth_name_en'])}'.trim();
      if (fl.isNotEmpty) return fl;
      final en = pick(prof['full_name_en']);
      if (en.isNotEmpty) return en;
    }

    final full = pick(prof['full_name']);
    if (full.isNotEmpty) return full;
    return pick(prof['username']);
  }

  Future<Map<String, Map<String, dynamic>>> _fetchActiveReservationsByPropertyIds(
      List<String> propertyIds) async {
    if (propertyIds.isEmpty) return {};
    try {
      final data = await _sb
          .from('reservations')
          .select('property_id, user_id, status, created_at, expires_at')
          .inFilter('property_id', propertyIds)
          .inFilter('status', ['active', 'pending'])
          .order('created_at', ascending: false);

      final rows = (data as List).cast<Map<String, dynamic>>();

      final byProp = <String, Map<String, dynamic>>{};
      final userIds = <String>{};

      for (final r in rows) {
        if (!_isStillValidReservationRow(r)) continue;

        final pid = (r['property_id'] ?? '').toString();
        if (pid.isEmpty) continue;
        if (!byProp.containsKey(pid)) {
          byProp[pid] = r;
          final uid = (r['user_id'] ?? '').toString();
          if (uid.isNotEmpty) userIds.add(uid);
        }
      }

      final profMap = await _fetchProfilesByUserIds(userIds.toList());
      for (final e in byProp.entries) {
        final r = e.value;
        final uid = (r['user_id'] ?? '').toString();
        final prof = profMap[uid];
        r['reserved_by_name'] = _displayNameFromProfile(prof);
      }

      return byProp;
    } catch (_) {
      return {};
    }
  }

  Future<void> _loadHome({bool force = false}) async {
    if (!force && !_shouldFetchHome() && _all.isNotEmpty) return;

    setState(() {
      _loadingHome = true;
      _errorHome = null;
    });

    try {
      final data = await _sb
          .from('properties')
          .select(_propertiesSelect)
          .order('created_at', ascending: false);

      final rows = (data as List).cast<Map>();

      final activeRows = rows.where((r) {
        final s = (r['status'] as String?) ?? 'active';
        return s == 'active';
      }).toList();

      final propIds = activeRows
          .map((r) => (r['id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
      final activeRes = await _fetchActiveReservationsByPropertyIds(propIds);

      final ownerIds = activeRows
          .map((r) => (r['owner_id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      final ownerProfiles = await _fetchProfilesByUserIds(ownerIds);

      final list = activeRows.map((row) {
        final imagesRaw = (row['property_images'] as List?) ?? const [];
        imagesRaw.sort((a, b) {
          final sa = (a['sort_order'] ?? 0) as int;
          final sb2 = (b['sort_order'] ?? 0) as int;
          return sa.compareTo(sb2);
        });

        final imageUrls = imagesRaw
            .map((e) => (e['path'] as String?)?.trim())
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .map((p) => _sb.storage.from('property-images').getPublicUrl(p))
            .toList();

        final ownerId = (row['owner_id'] ?? '').toString();
        final ownerName = _displayNameFromProfile(ownerProfiles[ownerId]);
        final ownerUsername = ownerName.isNotEmpty
            ? ownerName
            : ((row['username'] as String?)?.trim().isNotEmpty ?? false)
                ? (row['username'] as String).trim()
                : null;

        final property = _propertyFromDb(row,
            imageUrls: imageUrls, ownerUsername: ownerUsername);
        if (property.id.isNotEmpty) {
          _propertyCache[property.id] = property;
        }
        return property;
      }).toList();

      _activeReservationByPropertyId
        ..clear()
        ..addAll(activeRes);

      setState(() {
        _all = list;
        _loadingHome = false;
        _lastHomeFetch = DateTime.now();
      });
    } catch (e) {
      setState(() {
        _errorHome = e.toString();
        _loadingHome = false;
      });
    }
  }

  Future<void> _loadMineAndOffers({bool force = false}) async {
    if (!force && !_shouldFetchMine() && _mine.isNotEmpty) return;

    setState(() {
      _loadingMine = true;
      _errorMine = null;
      _loadingOffers = true;
      _errorOffers = null;
      _offersCount = 0;
    });

    try {
      if (_uid.isEmpty) {
        setState(() {
          _mine = <Property>[];
          _offers = <Map<String, dynamic>>[];
          _offersCount = 0;
          _loadingMine = false;
          _loadingOffers = false;

          _myPropertyById = {};
        });
        return;
      }

      _myPropertyById = {};

      final mineData = await _sb
          .from('properties')
          .select(_propertiesSelect)
          .eq('owner_id', _uid)
          .order('created_at', ascending: false);

      final mineRows = (mineData as List).cast<Map>();

      final myProfile = (await _fetchProfilesByUserIds([_uid]))[_uid];
      final myName = _displayNameFromProfile(myProfile);

      final mineList = mineRows.map((row) {
        final imagesRaw = (row['property_images'] as List?) ?? const [];
        imagesRaw.sort((a, b) {
          final sa = (a['sort_order'] ?? 0) as int;
          final sb2 = (b['sort_order'] ?? 0) as int;
          return sa.compareTo(sb2);
        });

        final imageUrls = imagesRaw
            .map((e) => (e['path'] as String?)?.trim())
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .map((p) => _sb.storage.from('property-images').getPublicUrl(p))
            .toList();

        final ownerUsername = myName.isNotEmpty
            ? myName
            : ((row['username'] as String?)?.trim().isNotEmpty ?? false)
                ? (row['username'] as String).trim()
                : null;

        final property = _propertyFromDb(row,
            imageUrls: imageUrls, ownerUsername: ownerUsername);
        if (property.id.isNotEmpty) {
          _propertyCache[property.id] = property;
          _myPropertyById[property.id] = property;
        }
        return property;
      }).toList();

      setState(() {
        _mine = mineList;
        _loadingMine = false;
        _lastMineFetch = DateTime.now();
      });

      final myIds =
          mineList.map((p) => p.id).where((id) => id.isNotEmpty).toList();

      if (myIds.isEmpty) {
        setState(() {
          _offers = <Map<String, dynamic>>[];
          _offersCount = 0;
          _loadingOffers = false;
        });
        return;
      }

      final offersData = await _sb
          .from('reservations')
          .select('''
            id,
            property_id,
            user_id,
            status,
            created_at,
            expires_at,
            base_price,
            platform_fee_amount,
            extra_fee_amount,
            total_amount
          ''')
          .inFilter('property_id', myIds)
          .order('created_at', ascending: false);

      final offersRowsRaw = (offersData as List).cast<Map<String, dynamic>>();
      final offersRows =
          offersRowsRaw.where(_isStillValidReservationRow).toList();

      final userIds = offersRows
          .map((r) => (r['user_id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      final profMap = await _fetchProfilesByUserIds(userIds);

      for (final r in offersRows) {
        final uid = (r['user_id'] ?? '').toString();
        r['reserved_by_name'] = _displayNameFromProfile(profMap[uid]);
      }

      int cnt = 0;
      for (final r in offersRows) {
        final st = (r['status'] ?? '').toString();
        if (st == 'active' || st == 'pending') cnt++;
      }

      setState(() {
        _offers = offersRows;
        _offersCount = cnt;
        _loadingOffers = false;
      });

      final myActiveRes = await _fetchActiveReservationsByPropertyIds(myIds);
      for (final e in myActiveRes.entries) {
        _activeReservationByPropertyId[e.key] = e.value;
      }
      if (mounted) setState(() {});
    } catch (e) {
      setState(() {
        _errorMine = e.toString();
        _loadingMine = false;

        _errorOffers = e.toString();
        _loadingOffers = false;
      });
    }
  }

  Future<void> _loadCart({bool force = false}) async {
    if (!force && !_shouldFetchCart() && _cart.isNotEmpty) return;

    setState(() {
      _loadingCart = true;
      _errorCart = null;
      _cartCount = 0;
    });

    try {
      if (_uid.isEmpty) {
        setState(() {
          _cart = <Map<String, dynamic>>[];
          _cartPropertyById = {};
          _cartCount = 0;
          _loadingCart = false;
        });
        return;
      }

      final cartData = await _sb
          .from('reservations')
          .select('''
            id,
            property_id,
            user_id,
            status,
            created_at,
            expires_at,
            base_price,
            platform_fee_amount,
            extra_fee_amount,
            total_amount
          ''')
          .eq('user_id', _uid)
          .inFilter('status', ['active', 'pending'])
          .order('created_at', ascending: false);

      final cartRowsRaw = (cartData as List).cast<Map<String, dynamic>>();
      final cartRows =
          cartRowsRaw.where(_isStillValidReservationRow).toList();

      final pids = cartRows
          .map((r) => (r['property_id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();

      Map<String, Property> byId = {};
      if (pids.isNotEmpty) {
        final uncachedIds =
            pids.where((id) => !_propertyCache.containsKey(id)).toList();

        if (uncachedIds.isNotEmpty) {
          final propsData = await _sb
              .from('properties')
              .select(_propertiesSelect)
              .inFilter('id', uncachedIds);

          final rows = (propsData as List).cast<Map>();

          final ownerIds = rows
              .map((r) => (r['owner_id'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList();

          final ownerProfiles = await _fetchProfilesByUserIds(ownerIds);

          for (final row in rows) {
            final imagesRaw = (row['property_images'] as List?) ?? const [];
            imagesRaw.sort((a, b) {
              final sa = (a['sort_order'] ?? 0) as int;
              final sb2 = (b['sort_order'] ?? 0) as int;
              return sa.compareTo(sb2);
            });

            final imageUrls = imagesRaw
                .map((e) => (e['path'] as String?)?.trim())
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .map((p) => _sb.storage.from('property-images').getPublicUrl(p))
                .toList();

            final ownerId = (row['owner_id'] ?? '').toString();
            final ownerName = _displayNameFromProfile(ownerProfiles[ownerId]);
            final ownerUsername = ownerName.isNotEmpty
                ? ownerName
                : ((row['username'] as String?)?.trim().isNotEmpty ?? false)
                    ? (row['username'] as String).trim()
                    : null;

            final p = _propertyFromDb(row,
                imageUrls: imageUrls, ownerUsername: ownerUsername);

            if (p.id.isNotEmpty) {
              _propertyCache[p.id] = p;
            }
          }
        }

        for (final id in pids) {
          if (_propertyCache.containsKey(id)) {
            byId[id] = _propertyCache[id]!;
          }
        }
      }

      setState(() {
        _cart = cartRows;
        _cartPropertyById = byId;
        _cartCount = cartRows.length;
        _loadingCart = false;
        _lastCartFetch = DateTime.now();
      });
    } catch (e) {
      setState(() {
        _errorCart = e.toString();
        _loadingCart = false;
      });
    }
  }

  Future<void> _reloadAll() async {
    await Future.wait([
      _loadHome(force: true),
      _loadMineAndOffers(force: true),
      _loadCart(force: true),
    ]);

    if (!_favoritesLoaded) {
      await _loadFavoritesForUid();
    }
  }

  // =========================
  // Property actions (Edit/Delete)
  // =========================
  Future<void> _editProperty(Property property) async {
    if (_isGuest) {
      _snackLoginRequired();
      return;
    }

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditPropertyPage(
          property: property,
          userId: _uid,
          lang: _lang,
        ),
      ),
    );

    if (!mounted) return;

    if (result is Property) {
      setState(() {
        final i1 = _all.indexWhere((p) => p.id == result.id);
        if (i1 != -1) _all[i1] = result;

        final i2 = _mine.indexWhere((p) => p.id == result.id);
        if (i2 != -1) _mine[i2] = result;

        if (result.id.isNotEmpty) {
          _propertyCache[result.id] = result;
          _myPropertyById[result.id] = result;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_lang == 'ar' ? 'تم تحديث الإعلان' : 'Listing updated'),
        ),
      );
    }
  }

  Future<void> _deleteProperty(String propertyId) async {
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_isArabic ? 'تأكيد الحذف' : 'Confirm Delete'),
        content: Text(_isArabic
            ? 'هل أنت متأكد من حذف هذا الإعلان؟ لا يمكن التراجع عن هذا الإجراء.'
            : 'Are you sure you want to delete this listing? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_isArabic ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(_isArabic ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      setState(() => _loadingMine = true);

      await _sb.from('properties').delete().eq('id', propertyId);

      if (mounted) {
        await _reloadAll();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isArabic
                ? 'تم حذف الإعلان بنجاح'
                : 'Property deleted successfully'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isArabic
                ? 'فشل حذف الإعلان: $e'
                : 'Failed to delete property: $e'),
          ),
        );
        setState(() => _loadingMine = false);
      }
    }
  }

  // =========================
  // Reservation actions
  // =========================
  bool _isReservedByAnyone(String propertyId) {
    final r = _activeReservationByPropertyId[propertyId];
    if (r == null) return false;
    if (!_isStillValidReservationRow(r)) return false;
    final st = (r['status'] ?? '').toString();
    return st == 'active' || st == 'pending';
  }

  DateTime? _reservedUntil(String propertyId) {
    final r = _activeReservationByPropertyId[propertyId];
    if (r == null) return null;
    return _tryParseDt(r['expires_at']);
  }

  String? _reservedByName(String propertyId) {
    final r = _activeReservationByPropertyId[propertyId];
    if (r == null) return null;
    final s = (r['reserved_by_name'] ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _addToCart(Property p) async {
    if (_isGuest) {
      _snackLoginRequired();
      return;
    }

    if (p.ownerId == _uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isArabic
              ? 'لا يمكنك حجز إعلانك'
              : 'You cannot reserve your own listing'),
        ),
      );
      return;
    }

    if (_isReservedByAnyone(p.id)) {
      final ex = _reservedUntil(p.id);
      final txt = ex == null ? '' : _fmtDateTime(ex);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isArabic
              ? 'العقار محجوز حتى $txt'
              : 'Already reserved until $txt'),
        ),
      );
      return;
    }

    try {
      final double basePrice = p.isAuction ? (p.currentBid ?? p.price) : p.price;

      final ok = await ReservationsService.createReservation(
        userId: _uid,
        propertyId: p.id,
        basePrice: basePrice,
      );

      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isArabic
                ? 'هذا الإعلان محجوز بالفعل'
                : 'This listing is already reserved'),
          ),
        );
        return;
      }

      _propertyCache.clear();
      _profileCache.clear();

      await Future.wait([
        _loadCart(force: true),
        _loadHome(force: true),
        _loadMineAndOffers(force: true),
      ]);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isArabic
              ? 'تمت الإضافة للسلة لمدة 72 ساعة'
              : 'Added to cart for 72 hours'),
        ),
      );

      setState(() => _tabIndex = 2);
    } catch (e) {
      final msg = e.toString();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isArabic ? 'فشل الحجز: $msg' : 'Reservation failed: $msg'),
        ),
      );
    }
  }

  Future<void> _cancelReservationFromCart(Map<String, dynamic> r) async {
    final id = (r['id'] ?? '').toString();
    if (id.isEmpty) return;

    try {
      await _sb.from('reservations').update({'status': 'cancelled'}).eq('id', id);

      _propertyCache.clear();
      await Future.wait([
        _loadCart(force: true),
        _loadHome(force: true),
        _loadMineAndOffers(force: true),
      ]);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isArabic ? 'تم إلغاء الحجز' : 'Reservation cancelled'),
        ),
      );
    } catch (e) {
      final msg = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isArabic ? 'فشل الإلغاء: $msg' : 'Cancel failed: $msg'),
        ),
      );
    }
  }

  // =========================
  // Model helpers
  // =========================
  Property _propertyFromDb(Map row,
      {required List<String> imageUrls, required String? ownerUsername}) {
    double? toDoubleN(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    int toInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    DateTime parseDt(dynamic v) {
      if (v is DateTime) return v.toLocal();
      if (v is String) return DateTime.tryParse(v)?.toLocal() ?? DateTime.now();
      return DateTime.now();
    }

    final typeStr = (row['type'] as String?) ?? 'villa';

    return Property(
      id: (row['id'] as String?) ?? '',
      ownerId: (row['owner_id'] as String?) ?? '',
      ownerUsername: ownerUsername,
      title: (row['title'] as String?) ?? '',
      type: _parseType(typeStr),
      description: (row['description'] as String?) ?? '',
      location: _mergeLocation(row),
      area: _toDouble(row['area']),
      price: _toDouble(row['price']),
      isAuction: (row['is_auction'] as bool?) ?? false,
      currentBid:
          row['current_bid'] == null ? null : _toDouble(row['current_bid']),
      images: imageUrls,
      views: toInt(row['views']),
      createdAt: parseDt(row['created_at']),
      latitude: toDoubleN(row['latitude']),
      longitude: toDoubleN(row['longitude']),
    );
  }

  String _mergeLocation(Map row) {
    final city = (row['city'] as String?)?.trim();
    if (city != null && city.isNotEmpty) return city;
    return '';
  }

  PropertyType _parseType(String s) {
    switch (s) {
      case 'apartment':
        return PropertyType.apartment;
      case 'land':
        return PropertyType.land;
      case 'villa':
      default:
        return PropertyType.villa;
    }
  }

  void _applySorting(List<Property> list) {
    switch (_sortBy) {
      case 'price_low':
        list.sort((a, b) => a.price.compareTo(b.price));
        break;
      case 'price_high':
        list.sort((a, b) => b.price.compareTo(a.price));
        break;
      case 'area_high':
        list.sort((a, b) => b.area.compareTo(a.area));
        break;
      case 'latest':
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
    }
  }

  List<Property> _filterList(List<Property> src) {
    final q = _searchQuery.trim().toLowerCase();
    final filtered = src.where((p) {
      if (q.isEmpty) return true;
      return p.title.toLowerCase().contains(q) ||
          p.location.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q);
    }).toList();
    _applySorting(filtered);
    return filtered;
  }

  // =========================
  // Navigation / actions
  // =========================
  void _readArgsInBuildOnce(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final l = args['lang'];
      if (l is String && l.isNotEmpty && l != _lang) {
        langNotifier.value = l;
      }
    }
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsPage(lang: _lang)),
    );

    if (result is Map && result['lang'] is String) {
      langNotifier.value = result['lang'] as String;
      if (mounted) setState(() {});
    }
  }

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);

    try {
      // 1) اخرج من Supabase
      await _sb.auth.signOut();

      // 2) امسح بيانات الدخول السريع
      try {
        await fl_service.FastLoginService.clearAll();
      } catch (_) {}

      // 3) امسح كاشات الواجهة
      _propertyCache.clear();
      _profileCache.clear();
      _favoriteIds.clear();
    } catch (_) {}

    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  Future<void> _openAdd() async {
    if (_isGuest) {
      _snackLoginRequired();
      return;
    }

    final res = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => addp.AddPropertyPage(userId: _uid, lang: _lang),
      ),
    );

    if (!mounted) return;

    if (res == true) {
      await _reloadAll();
      if (mounted) setState(() => _tabIndex = 1);
    }
  }

  void _openDetails(Property p) {
    final ownerForDetails = _isGuest ? null : p.ownerUsername;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => details.PropertyDetailsPage(
          property: p,
          isAr: _isArabic,
          currentUserId: _isGuest ? 'guest' : _uid,
          ownerUsername: ownerForDetails,
          isFavorite: !_isGuest && _isFav(p.id),
          onToggleFavorite: () async {
            if (_isGuest) return;
            await _toggleFav(p.id);
          },
        ),
      ),
    );
  }

  // =========================
  // UI helpers / texts
  // =========================
  String _tabTitle() {
    switch (_tabIndex) {
      case 0:
        return _isArabic ? 'الرئيسية' : 'Home';
      case 1:
        return _isArabic ? 'إعلاناتي' : 'My Listings';
      case 2:
        return _isArabic ? 'سلتي' : 'My Cart';
      case 3:
        return _isArabic ? 'الحجوزات' : 'Reservations';
      case 4:
        return _isArabic ? 'الدعم / الدردشة' : 'Support / Chat';
      default:
        return _isArabic ? 'لوحة التحكم' : 'Dashboard';
    }
  }

  String _failLoadTitle() =>
      _isArabic ? 'تعذر تحميل البيانات' : 'Failed to load data';

  String _failLoadSubtitle() => _isArabic
      ? 'تحقق من اتصال الإنترنت ثم أعد المحاولة.'
      : 'Check your internet connection then try again.';

  String _fmtDateTime(DateTime dt) {
    final d = dt.toLocal();
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _priceRow(
    BuildContext context, {
    required String label,
    required double value,
    bool bold = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final leftStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: bold ? FontWeight.w900 : FontWeight.w800,
        );
    final rightStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: bold ? FontWeight.w900 : FontWeight.w900,
          color: cs.onSurface,
        );

    return Row(
      children: [
        Expanded(child: Text(label, style: leftStyle)),
        Text('${_RealEstateCard._money(value)} ${_isArabic ? 'ر.س' : 'SAR'}',
            style: rightStyle),
      ],
    );
  }

  // =========================
  // BUILD
  // =========================
  @override
  Widget build(BuildContext context) {
    _readArgsInBuildOnce(context);

    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final homeItems = _filterList(_all);
    final myItems = _filterList(_mine);

    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: WillPopScope(
        onWillPop: () async {
          await _logout();
          return false;
        },
        child: Scaffold(
          backgroundColor: cs.surface,
          appBar: AppBar(
            elevation: 0,
            title: Text(_tabTitle(),
                style: const TextStyle(fontWeight: FontWeight.w900)),
            actions: [
              if (!_isGuest)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                            color: cs.outlineVariant.withOpacity(0.5)),
                        color: cs.surfaceVariant.withOpacity(0.55),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.favorite,
                              size: 16,
                              color: Colors.redAccent.withOpacity(0.95)),
                          const SizedBox(width: 6),
                          Text('${_favoriteIds.length}',
                              style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: cs.onSurface)),
                        ],
                      ),
                    ),
                  ),
                ),
              _IconBadgeButton(
                tooltip: _isArabic ? 'السلة (حجوزاتي)' : 'Cart (My reservations)',
                icon: Icons.shopping_cart_outlined,
                badge: _cartCount,
                color: _bankColor,
                onPressed: () => setState(() => _tabIndex = 2),
              ),
              _IconBadgeButton(
                tooltip: _isArabic ? 'الحجوزات' : 'Reservations',
                icon: Icons.receipt_long_outlined,
                badge: _offersCount,
                color: _bankColor,
                onPressed: () => setState(() => _tabIndex = 3),
              ),
              IconButton(
                tooltip: _isArabic ? 'الدعم / الدردشة' : 'Support / Chat',
                icon: const Icon(Icons.chat_bubble_outline),
                onPressed: () => setState(() => _tabIndex = 4),
              ),
              IconButton(
                tooltip: _isArabic ? 'إعدادات' : 'Settings',
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
              ),
              IconButton(
                tooltip: _isArabic ? 'تسجيل خروج' : 'Logout',
                icon: _loggingOut
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.logout),
                onPressed: _loggingOut ? null : _logout,
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (_tabIndex == 0 || _tabIndex == 1)
                  _buildTopFilters(
                    onRefresh: () async {
                      if (_tabIndex == 0) {
                        await _loadHome(force: true);
                      } else {
                        await _loadMineAndOffers(force: true);
                      }
                      await _loadCart(force: true);
                    },
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      RefreshIndicator(
                        onRefresh: () async {
                          await _loadHome(force: true);
                          await _loadCart(force: true);
                        },
                        child: _buildPropertiesBody(
                          loading: _loadingHome,
                          error: _errorHome,
                          items: homeItems,
                          emptyTitle: _isArabic
                              ? 'لا توجد إعلانات متاحة'
                              : 'No listings available',
                          emptySubtitle: _isArabic
                              ? 'لا توجد نتائج حالياً.'
                              : 'No results right now.',
                          showEditDelete: false,
                        ),
                      ),
                      RefreshIndicator(
                        onRefresh: () async {
                          await _loadMineAndOffers(force: true);
                          await _loadCart(force: true);
                        },
                        child: _buildPropertiesBody(
                          loading: _loadingMine,
                          error: _errorMine,
                          items: myItems,
                          emptyTitle: _isArabic
                              ? 'لا توجد إعلانات لك'
                              : 'No listings for you',
                          emptySubtitle: _isArabic
                              ? 'أضف إعلاناً جديداً وسيظهر هنا.'
                              : 'Add a new listing and it will appear here.',
                          showEditDelete: true,
                        ),
                      ),
                      RefreshIndicator(
                        onRefresh: () async {
                          await _loadCart(force: true);
                          await _loadHome(force: true);
                          await _loadMineAndOffers(force: true);
                        },
                        child: _buildCartBody(),
                      ),
                      RefreshIndicator(
                        onRefresh: () async {
                          await _loadMineAndOffers(force: true);
                          await _loadCart(force: true);
                        },
                        child: _buildOffersBody(),
                      ),
                      _buildChatHubBody(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: (!_isGuest && (_tabIndex == 0 || _tabIndex == 1))
              ? FloatingActionButton.extended(
                  backgroundColor: _bankColor,
                  foregroundColor: Colors.white,
                  onPressed: _openAdd,
                  icon: const Icon(Icons.add_home_work_outlined),
                  label: Text(_isArabic ? 'إضافة إعلان' : 'Add Listing',
                      style: const TextStyle(fontWeight: FontWeight.w900)),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (i) => setState(() => _tabIndex = i),
            indicatorColor: _bankColor.withOpacity(_op(28)),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home),
                label: _isArabic ? 'الرئيسية' : 'Home',
              ),
              NavigationDestination(
                icon: const Icon(Icons.list_alt_outlined),
                selectedIcon: const Icon(Icons.list_alt),
                label: _isArabic ? 'إعلاناتي' : 'My Ads',
              ),
              NavigationDestination(
                icon: _BadgeIcon(
                    icon: Icons.shopping_cart_outlined,
                    badge: _cartCount,
                    color: _bankColor),
                selectedIcon: const Icon(Icons.shopping_cart),
                label: _isArabic ? 'سلتي' : 'Cart',
              ),
              NavigationDestination(
                icon: _BadgeIcon(
                    icon: Icons.receipt_long_outlined,
                    badge: _offersCount,
                    color: _bankColor),
                selectedIcon: const Icon(Icons.receipt_long),
                label: _isArabic ? 'الحجوزات' : 'Reservations',
              ),
              NavigationDestination(
                icon: const Icon(Icons.chat_bubble_outline),
                selectedIcon: const Icon(Icons.chat_bubble),
                label: _isArabic ? 'الدعم' : 'Chat',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopFilters({required VoidCallback onRefresh}) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
            bottom: BorderSide(color: cs.outlineVariant.withOpacity(0.3))),
      ),
      child: Column(
        children: [
          _SearchField(
            hint: _isArabic
                ? 'ابحث (عنوان / مدينة / وصف)...'
                : 'Search (title / city / description)...',
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () {
                if (!mounted) return;
                setState(() => _searchQuery = v);
              });
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SortMenu(
                  isAr: _isArabic,
                  value: _sortBy,
                  onChanged: (v) => setState(() => _sortBy = v),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                label: Text(_isArabic ? 'تحديث' : 'Refresh'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // =========================
  // Body builders
  // =========================
  Widget _buildPropertiesBody({
    required bool loading,
    required String? error,
    required List<Property> items,
    required String emptyTitle,
    required String emptySubtitle,
    required bool showEditDelete,
  }) {
    final cs = Theme.of(context).colorScheme;

    if (loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
          SizedBox(height: 120),
        ],
      );
    }

    if (error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.wifi_off_outlined, size: 44, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _failLoadTitle(),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _failLoadSubtitle(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          if (kDebugMode) Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Center(
            child: ElevatedButton.icon(
              onPressed: _reloadAll,
              icon: const Icon(Icons.refresh),
              label: Text(_isArabic ? 'إعادة المحاولة' : 'Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _bankColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      );
    }

    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(Icons.home_outlined,
                    size: 84, color: _bankColor.withOpacity(_op(180))),
                const SizedBox(height: 18),
                Text(
                  emptyTitle,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  emptySubtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                ElevatedButton.icon(
                  onPressed: _reloadAll,
                  icon: const Icon(Icons.refresh),
                  label: Text(_isArabic ? 'تحديث' : 'Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _bankColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return _PropertyGrid(
      items: items,
      currentUserId: _uid.isEmpty ? 'guest' : _uid,
      isAr: _isArabic,
      bankColor: _bankColor,
      isFav: (id) => _isFav(id),
      onToggleFav: (id) => _toggleFav(id),
      onOpenDetails: (p) => _openDetails(p),
      isReserved: (pid) => _isReservedByAnyone(pid),
      reservedUntil: (pid) => _reservedUntil(pid),
      reservedByName: (pid) => _reservedByName(pid),
      onAddToCart: (p) => _addToCart(p),
      showEditDelete: showEditDelete,
      onEditProperty: _editProperty,
      onDeleteProperty: _deleteProperty,
    );
  }

  // =========================
  // Unified Chat/Support tab body
  // =========================
  Widget _buildChatHubBody() {
    final cs = Theme.of(context).colorScheme;

    if (_isGuest) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 40),
          Icon(Icons.lock_outline,
              size: 84, color: _bankColor.withOpacity(_op(180))),
          const SizedBox(height: 18),
          Text(
            _isArabic
                ? 'سجّل الدخول لاستخدام الدعم والدردشة'
                : 'Login to use Support & Chat',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            _isArabic
                ? 'الدردشة مرتبطة بالعقار والحجز لضمان الموثوقية.'
                : 'Chat is tied to property and reservation for trust.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    final title = _chatTitle?.trim();
    final hasContext = (_chatMode != 'support') &&
        ((_chatPropertyId ?? '').isNotEmpty ||
            (_chatReservationId ?? '').isNotEmpty);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.45)),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 10),
                color: cs.shadow.withOpacity(0.08),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _bankColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.support_agent, color: _bankColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _isArabic ? 'الدعم والمحادثات' : 'Support & Conversations',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _isArabic
                    ? 'تم توحيد (الدعم) و(دردشة العقار/الحجز) في تبويب واحد لضمان عدم التكرار وربط المحادثة بالسياق.'
                    : 'Support + property/reservation chat are unified in one tab to avoid duplication and tie chat to context.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _openUnifiedChat(
                          mode: 'support',
                          title: _isArabic ? 'الدعم' : 'Support'),
                      icon: const Icon(Icons.support_agent),
                      label: Text(_isArabic ? 'فتح الدعم' : 'Open Support',
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _bankColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (hasContext)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: cs.outlineVariant.withOpacity(0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isArabic ? 'آخر سياق محدد' : 'Last selected context',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MiniChip(
                      icon: Icons.home_work_outlined,
                      text: title?.isNotEmpty == true
                          ? title!
                          : (_isArabic ? 'محادثة عقار' : 'Property chat'),
                      bankColor: _bankColor,
                    ),
                    if ((_chatReservationId ?? '').isNotEmpty)
                      _MiniChip(
                        icon: Icons.receipt_long_outlined,
                        text: _isArabic
                            ? 'حجز: ${_chatReservationId!.substring(0, _chatReservationId!.length.clamp(0, 8))}...'
                            : 'Res: ${_chatReservationId!.substring(0, _chatReservationId!.length.clamp(0, 8))}...',
                        bankColor: _bankColor,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ChatPage()),
                      );
                    },
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text(
                      _isArabic ? 'فتح الدردشة' : 'Open Chat',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                )
              ],
            ),
          ),
        if (!hasContext)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceVariant.withOpacity(0.25),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: cs.outlineVariant.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _isArabic
                        ? 'لفتح دردشة مرتبطة بعقار/حجز: اذهب للسلة أو الحجوزات واضغط "دردشة".'
                        : 'To open a property/reservation chat: go to Cart or Reservations and tap "Chat".',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // =========================
  // Cart / Offers
  // =========================
  Widget _buildCartBody() {
    final cs = Theme.of(context).colorScheme;

    if (_loadingCart) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
          SizedBox(height: 120),
        ],
      );
    }

    if (_errorCart != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Text(
              _isArabic ? 'تعذر تحميل السلة' : 'Failed to load cart',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w900),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _isArabic
                  ? 'تحقق من الاتصال ثم أعد المحاولة.'
                  : 'Check connection then retry.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          if (kDebugMode) Text(_errorCart!, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Center(
            child: ElevatedButton.icon(
              onPressed: _loadCart,
              icon: const Icon(Icons.refresh),
              label: Text(_isArabic ? 'إعادة المحاولة' : 'Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _bankColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      );
    }

    if (_uid.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(Icons.lock_outline,
                    size: 84, color: _bankColor.withOpacity(_op(180))),
                const SizedBox(height: 18),
                Text(
                  _isArabic ? 'سجّل الدخول لعرض السلة' : 'Login to view cart',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_cart.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                Icon(Icons.shopping_cart_outlined,
                    size: 84, color: _bankColor.withOpacity(_op(180))),
                const SizedBox(height: 18),
                Text(
                  _isArabic ? 'سلّتك فارغة' : 'Your cart is empty',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                ElevatedButton.icon(
                  onPressed: () => setState(() => _tabIndex = 0),
                  icon: const Icon(Icons.home_outlined),
                  label: Text(_isArabic ? 'اذهب للرئيسية' : 'Go to Home'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _bankColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _cart.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final r = _cart[i];
        final reservationId = (r['id'] ?? '').toString();
        final propertyId = (r['property_id'] ?? '').toString();
        final p = _cartPropertyById[propertyId];

        final basePrice = _toDouble(r['base_price']);
        final platformFee = _toDouble(r['platform_fee_amount']);
        final extraFee = _toDouble(r['extra_fee_amount']);
        final total = _toDouble(r['total_amount']);

        final createdAt = _tryParseDt(r['created_at']);
        final expiresAt = _tryParseDt(r['expires_at']);
        final createdText = createdAt == null
            ? (_isArabic ? 'غير معروف' : 'Unknown')
            : _timeAgo(createdAt, _isArabic);
        final expiresText = expiresAt == null
            ? (_isArabic ? 'غير معروف' : 'Unknown')
            : _fmtDateTime(expiresAt);

        return _ReservationCard(
          bankColor: _bankColor,
          icon: Icons.shopping_cart_outlined,
          title: p?.title ?? (_isArabic ? 'عقار' : 'Property'),
          chips: [
            _MiniChip(
                icon: Icons.schedule,
                text: _isArabic ? 'منذ: $createdText' : 'Since: $createdText',
                bankColor: _bankColor),
            _MiniChip(
                icon: Icons.timer_outlined,
                text:
                    _isArabic ? 'ينتهي: $expiresText' : 'Expires: $expiresText',
                bankColor: _bankColor),
          ],
          priceTable: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _priceRow(context,
                  label: _isArabic ? 'السعر الأساسي' : 'Base price',
                  value: basePrice),
              const SizedBox(height: 6),
              _priceRow(context,
                  label: _isArabic ? 'عمولة المنصة (5%)' : 'Platform fee (5%)',
                  value: platformFee),
              const SizedBox(height: 6),
              _priceRow(context,
                  label: _isArabic ? 'رسوم إضافية (2.5%)' : 'Extra fee (2.5%)',
                  value: extraFee),
              const Divider(height: 16),
              _priceRow(context,
                  label: _isArabic ? 'الإجمالي' : 'Total',
                  value: total,
                  bold: true),
            ],
          ),
          primaryAction: _ReservationAction(
            kind: _ReservationActionKind.outlined,
            icon: Icons.open_in_new,
            label: _isArabic ? 'فتح الإعلان' : 'Open listing',
            onPressed: p == null ? null : () => _openDetails(p),
          ),
          secondaryAction: _ReservationAction(
            kind: _ReservationActionKind.outlined,
            icon: Icons.chat_bubble_outline,
            label: _isArabic ? 'دردشة' : 'Chat',
            onPressed: () {
              final t =
                  p?.title ?? (_isArabic ? 'دردشة الحجز' : 'Reservation chat');
              _openUnifiedChat(
                mode: 'reservation',
                propertyId: propertyId,
                reservationId: reservationId,
                title: t,
              );
            },
          ),
          thirdAction: _ReservationAction(
            kind: _ReservationActionKind.filledDanger,
            icon: Icons.close,
            label: _isArabic ? 'إلغاء' : 'Cancel',
            onPressed: () => _cancelReservationFromCart(r),
          ),
        );
      },
    );
  }

  Widget _buildOffersBody() {
    final cs = Theme.of(context).colorScheme;

    if (_loadingOffers) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
          SizedBox(height: 120),
        ],
      );
    }

    if (_errorOffers != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Text(
              _isArabic ? 'تعذر تحميل الحجوزات' : 'Failed to load reservations',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w900),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _isArabic
                  ? 'تحقق من الاتصال ثم أعد المحاولة.'
                  : 'Check connection then retry.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          if (kDebugMode) Text(_errorOffers!, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Center(
            child: ElevatedButton.icon(
              onPressed: _loadMineAndOffers,
              icon: const Icon(Icons.refresh),
              label: Text(_isArabic ? 'إعادة المحاولة' : 'Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _bankColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      );
    }

    if (_uid.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(Icons.lock_outline,
                    size: 84, color: _bankColor.withOpacity(_op(180))),
                const SizedBox(height: 18),
                Text(
                  _isArabic
                      ? 'سجّل الدخول لعرض الحجوزات'
                      : 'Login to view reservations',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_offers.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                Icon(Icons.receipt_long_outlined,
                    size: 84, color: _bankColor.withOpacity(_op(180))),
                const SizedBox(height: 18),
                Text(
                  _isArabic
                      ? 'لا توجد حجوزات على إعلاناتك'
                      : 'No reservations on your listings',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                ElevatedButton.icon(
                  onPressed: _loadMineAndOffers,
                  icon: const Icon(Icons.refresh),
                  label: Text(_isArabic ? 'تحديث' : 'Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _bankColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _offers.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final r = _offers[i];
        final reservationId = (r['id'] ?? '').toString();
        final propertyId = (r['property_id'] ?? '').toString();
        final p = _myPropertyById[propertyId];

        final basePrice = _toDouble(r['base_price']);
        final platformFee = _toDouble(r['platform_fee_amount']);
        final extraFee = _toDouble(r['extra_fee_amount']);
        final total = _toDouble(r['total_amount']);

        final createdAt = _tryParseDt(r['created_at']);
        final expiresAt = _tryParseDt(r['expires_at']);
        final createdText = createdAt == null
            ? (_isArabic ? 'غير معروف' : 'Unknown')
            : _timeAgo(createdAt, _isArabic);
        final expiresText = expiresAt == null
            ? (_isArabic ? 'غير معروف' : 'Unknown')
            : _fmtDateTime(expiresAt);

        final status = (r['status'] ?? '').toString().trim();
        final buyerName = (r['reserved_by_name'] ?? '').toString().trim();
        final buyerLabel =
            buyerName.isNotEmpty ? buyerName : ((r['user_id'] ?? 'N/A').toString());

        return _ReservationCard(
          bankColor: _bankColor,
          icon: Icons.receipt_long_outlined,
          title: p?.title ?? (_isArabic ? 'إعلان' : 'Listing'),
          subtitle: Text(
            _isArabic ? 'منذ: $createdText' : 'Time: $createdText',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700),
          ),
          chips: [
            _MiniChip(
              icon: Icons.tag,
              text: _isArabic
                  ? 'الحالة: ${status.isEmpty ? 'غير محدد' : status}'
                  : 'Status: ${status.isEmpty ? 'N/A' : status}',
              bankColor: _bankColor,
            ),
            _MiniChip(
              icon: Icons.person_outline,
              text: _isArabic ? 'الحاجز: $buyerLabel' : 'Reserved by: $buyerLabel',
              bankColor: _bankColor,
            ),
            _MiniChip(
              icon: Icons.timer_outlined,
              text:
                  _isArabic ? 'ينتهي: $expiresText' : 'Expires: $expiresText',
              bankColor: _bankColor,
            ),
          ],
          priceTable: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _priceRow(context,
                  label: _isArabic ? 'السعر الأساسي' : 'Base price',
                  value: basePrice),
              const SizedBox(height: 6),
              _priceRow(context,
                  label: _isArabic ? 'عمولة المنصة (5%)' : 'Platform fee (5%)',
                  value: platformFee),
              const SizedBox(height: 6),
              _priceRow(context,
                  label: _isArabic ? 'رسوم إضافية (2.5%)' : 'Extra fee (2.5%)',
                  value: extraFee),
              const Divider(height: 16),
              _priceRow(context,
                  label: _isArabic ? 'الإجمالي' : 'Total',
                  value: total,
                  bold: true),
            ],
          ),
          primaryAction: _ReservationAction(
            kind: _ReservationActionKind.outlined,
            icon: Icons.open_in_new,
            label: _isArabic ? 'فتح الإعلان' : 'Open listing',
            onPressed: p == null ? null : () => _openDetails(p),
          ),
          secondaryAction: _ReservationAction(
            kind: _ReservationActionKind.outlined,
            icon: Icons.chat_bubble_outline,
            label: _isArabic ? 'دردشة' : 'Chat',
            onPressed: () {
              final t =
                  p?.title ?? (_isArabic ? 'دردشة الحجز' : 'Reservation chat');
              _openUnifiedChat(
                mode: 'reservation',
                propertyId: propertyId,
                reservationId: reservationId,
                title: t,
              );
            },
          ),
          thirdAction: null,
        );
      },
    );
  }
}

// =========================
// Widgets
// =========================

class _IconBadgeButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final int badge;
  final Color color;
  final VoidCallback onPressed;

  const _IconBadgeButton({
    required this.tooltip,
    required this.icon,
    required this.badge,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton(onPressed: onPressed, icon: Icon(icon)),
          if (badge > 0)
            PositionedDirectional(
              end: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 1.2),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BadgeIcon extends StatelessWidget {
  final IconData icon;
  final int badge;
  final Color color;

  const _BadgeIcon(
      {required this.icon, required this.badge, required this.color});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (badge > 0)
          PositionedDirectional(
            end: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 1.2),
              ),
              child: Text(
                badge > 99 ? '99+' : '$badge',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 10),
              ),
            ),
          ),
      ],
    );
  }
}

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bankColor;

  const _MiniChip(
      {required this.icon, required this.text, required this.bankColor});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bankColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: bankColor.withOpacity(0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: bankColor),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface)),
        ],
      ),
    );
  }
}

enum _ReservationActionKind { outlined, filledDanger }

class _ReservationAction {
  final _ReservationActionKind kind;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _ReservationAction({
    required this.kind,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
}

class _ReservationCard extends StatelessWidget {
  final Color bankColor;
  final IconData icon;
  final String title;
  final Widget? subtitle;
  final List<Widget> chips;
  final Widget priceTable;

  final _ReservationAction? primaryAction;
  final _ReservationAction? secondaryAction;
  final _ReservationAction? thirdAction;

  const _ReservationCard({
    required this.bankColor,
    required this.icon,
    required this.title,
    required this.chips,
    required this.priceTable,
    required this.primaryAction,
    required this.secondaryAction,
    required this.thirdAction,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget buildAction(_ReservationAction a) {
      switch (a.kind) {
        case _ReservationActionKind.outlined:
          return Expanded(
            child: OutlinedButton.icon(
              onPressed: a.onPressed,
              icon: Icon(a.icon),
              label: Text(a.label),
            ),
          );
        case _ReservationActionKind.filledDanger:
          return Expanded(
            child: ElevatedButton.icon(
              onPressed: a.onPressed,
              icon: Icon(a.icon),
              label: Text(a.label),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          );
      }
    }

    final actions = <Widget>[];
    if (primaryAction != null) actions.add(buildAction(primaryAction!));
    if (secondaryAction != null) {
      if (actions.isNotEmpty) actions.add(const SizedBox(width: 10));
      actions.add(buildAction(secondaryAction!));
    }
    if (thirdAction != null) {
      if (actions.isNotEmpty) actions.add(const SizedBox(width: 10));
      actions.add(buildAction(thirdAction!));
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: cs.surface,
        border: Border.all(color: cs.outlineVariant.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 10),
            color: cs.shadow.withOpacity(0.08),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: bankColor.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: bankColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    subtitle!,
                  ],
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: chips),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceVariant.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: cs.outlineVariant.withOpacity(0.45)),
                    ),
                    child: priceTable,
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(children: actions),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================
// Property Grid / Cards
// =========================

class _PropertyGrid extends StatelessWidget {
  final List<Property> items;
  final String currentUserId;
  final bool isAr;
  final Color bankColor;

  final bool Function(String id) isFav;
  final Future<void> Function(String id) onToggleFav;
  final void Function(Property p) onOpenDetails;

  final bool Function(String propertyId) isReserved;
  final DateTime? Function(String propertyId) reservedUntil;
  final String? Function(String propertyId) reservedByName;

  final Future<void> Function(Property p) onAddToCart;

  final bool showEditDelete;
  final Future<void> Function(Property p) onEditProperty;
  final Future<void> Function(String propertyId) onDeleteProperty;

  const _PropertyGrid({
    required this.items,
    required this.currentUserId,
    required this.isAr,
    required this.bankColor,
    required this.isFav,
    required this.onToggleFav,
    required this.onOpenDetails,
    required this.isReserved,
    required this.reservedUntil,
    required this.reservedByName,
    required this.onAddToCart,
    required this.showEditDelete,
    required this.onEditProperty,
    required this.onDeleteProperty,
  });

  int _crossAxisCount(double w) {
    if (w < 720) return 1; // جوال/صغير
    if (w < 980) return 2; // تابلت
    if (w < 1250) return 3;
    if (w < 1550) return 4;
    return 5;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final cross = _crossAxisCount(w);
        final paddingH = w >= 900 ? 18.0 : 12.0;
        final spacing = 12.0;

        final cardW = (w - (paddingH * 2) - (spacing * (cross - 1))) / cross;
        final horizontalCard = cardW >= 320; // صورة + بيانات جنبها
        final aspect = horizontalCard
            ? (cross == 1 ? 1.9 : 1.35)
            : (cross == 1 ? 0.82 : 0.72);

        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: paddingH, vertical: 12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: aspect,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final p = items[i];
            final isOwner = p.ownerId == currentUserId;
            final isGuest = currentUserId == 'guest';

            return _RealEstateCard(
              property: p,
              isOwner: isOwner,
              isAr: isAr,
              bankColor: bankColor,
              favorite: !isGuest && isFav(p.id),
              // ✅ fix: VoidCallback لا يقبل Future
              onToggleFav: isGuest ? () {} : () { onToggleFav(p.id); },
              onOpenDetails: () => onOpenDetails(p),
              isReserved: isReserved(p.id),
              reservedUntil: reservedUntil(p.id),
              reservedByName: reservedByName(p.id),
              onAddToCart: (isGuest || isOwner) ? null : () => onAddToCart(p),
              currentUserId: currentUserId,
              showEditDelete: showEditDelete && isOwner,
              onEditProperty: () => onEditProperty(p),
              onDeleteProperty: () => onDeleteProperty(p.id),
            );
          },
        );
      },
    );
  }
}

class _RealEstateCard extends StatelessWidget {
  final Property property;
  final bool isOwner;
  final bool isAr;
  final Color bankColor;

  final bool favorite;
  final VoidCallback onToggleFav;
  final VoidCallback onOpenDetails;

  final bool isReserved;
  final DateTime? reservedUntil;
  final String? reservedByName;

  final Future<void> Function()? onAddToCart;
  final String currentUserId;

  final bool showEditDelete;
  final VoidCallback? onEditProperty;
  final VoidCallback? onDeleteProperty;

  const _RealEstateCard({
    required this.property,
    required this.isOwner,
    required this.isAr,
    required this.bankColor,
    required this.favorite,
    required this.onToggleFav,
    required this.onOpenDetails,
    required this.isReserved,
    required this.reservedUntil,
    required this.reservedByName,
    required this.onAddToCart,
    required this.currentUserId,
    this.showEditDelete = false,
    this.onEditProperty,
    this.onDeleteProperty,
  });

  String _fmt(DateTime dt) {
    final d = dt.toLocal();
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _imageBlock(BuildContext context, {required bool horizontal}) {
    final cs = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: horizontal
          ? const BorderRadiusDirectional.horizontal(
              start: Radius.circular(18),
              end: Radius.circular(0),
            )
          : const BorderRadius.vertical(top: Radius.circular(18)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PropertyImage(urls: property.images),
          if (property.isAuction)
            PositionedDirectional(
              top: 10,
              end: 10,
              child: _Pill(
                text: isAr ? 'مزاد' : 'Auction',
                icon: Icons.gavel_outlined,
                background: Colors.orange.withOpacity(0.95),
                foreground: Colors.white,
              ),
            ),
          PositionedDirectional(
            bottom: 10,
            end: 10,
            child: _Pill(
              text: '${property.views}',
              icon: Icons.remove_red_eye_outlined,
              background: Colors.black.withOpacity(0.45),
              foreground: Colors.white,
            ),
          ),
          if (isReserved)
            PositionedDirectional(
              bottom: 10,
              start: 10,
              child: _Pill(
                text: isAr ? 'محجوز' : 'Reserved',
                icon: Icons.lock_clock_outlined,
                background: Colors.red.withOpacity(0.86),
                foreground: Colors.white,
              ),
            ),
          PositionedDirectional(
            top: 10,
            start: 10,
            child: Opacity(
              opacity: currentUserId == 'guest' ? 0.5 : 1,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: currentUserId == 'guest' ? null : onToggleFav,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withOpacity(0.25)),
                    ),
                    child: Icon(
                      favorite ? Icons.favorite : Icons.favorite_border,
                      color: favorite ? Colors.redAccent : Colors.white,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (showEditDelete &&
              (onEditProperty != null || onDeleteProperty != null))
            PositionedDirectional(
              top: 10,
              end: 50,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onEditProperty != null)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: onEditProperty,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.25)),
                          ),
                          child: const Icon(Icons.edit,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  if (onDeleteProperty != null)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: onDeleteProperty,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.25)),
                          ),
                          child: const Icon(Icons.delete,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outlineVariant.withOpacity(0.0)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // ✅ fix: استعمل static داخل نفس الكلاس بدل دالة خارجية
    final timeText = _timeAgo(property.createdAt, isAr);

    final reservedChipText = () {
      final ex = reservedUntil;
      final until = ex == null ? '' : _fmt(ex);
      if (isOwner) {
        final who = (reservedByName ?? '').trim();
        if (who.isNotEmpty) {
          return isAr
              ? 'محجوز بواسطة: $who • حتى $until'
              : 'Reserved by: $who • until $until';
        }
        return isAr ? 'محجوز • حتى $until' : 'Reserved • until $until';
      }
      return isAr ? 'محجوز • حتى $until' : 'Reserved • until $until';
    }();

    final borderColor = theme.brightness == Brightness.light
        ? Colors.black.withOpacity(0.15)
        : Colors.white.withOpacity(0.15);

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final horizontal = w >= 320;

        final imageW = horizontal ? (w < 380 ? 130.0 : 160.0) : null;

        Widget content() {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  property.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text(
                  property.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                if (isReserved)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.red.withOpacity(0.25)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_clock_outlined,
                            size: 16, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            reservedChipText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 16, color: bankColor),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        property.location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.straighten_outlined,
                        size: 16, color: bankColor),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        isAr
                            ? '${property.area.toStringAsFixed(0)} م²'
                            : '${property.area.toStringAsFixed(0)} m²',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        property.isAuction
                            ? (isAr
                                ? '${_money(property.currentBid ?? 0)} ر.س'
                                : '${_money(property.currentBid ?? 0)} SAR')
                            : (isAr
                                ? '${_money(property.price)} ر.س'
                                : '${_money(property.price)} SAR'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color:
                              property.isAuction ? Colors.orange : Colors.green,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 18),
                Row(
                  children: [
                    Text(timeText,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    const Spacer(),
                  ],
                ),
                if (!isOwner)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: isReserved ? null : () async { await onAddToCart?.call(); },
                        icon: const Icon(Icons.add_shopping_cart),
                        label: Text(
                          isAr ? 'إضافة للسلة 72 ساعة' : 'Reserve in cart (72h)',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: bankColor,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              cs.surfaceVariant.withOpacity(0.55),
                          disabledForegroundColor: cs.onSurfaceVariant,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onOpenDetails,
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                    color: cs.shadow.withOpacity(0.10),
                  )
                ],
              ),
              child: horizontal
                  ? Row(
                      children: [
                        SizedBox(
                          width: imageW!,
                          child: _imageBlock(context, horizontal: true),
                        ),
                        Expanded(child: content()),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                            child: _imageBlock(context, horizontal: false)),
                        content(),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  static String _money(double v) {
    final s = v.toStringAsFixed(0);
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final fromEnd = s.length - i;
      b.write(s[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) b.write(',');
    }
    return b.toString();
  }

  static String _timeAgo(DateTime dt, bool isAr) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes <= 1 ? 1 : diff.inMinutes;
      return isAr ? 'قبل $m دقيقة' : '$m min ago';
    }
    if (diff.inHours < 24) {
      final h = diff.inHours <= 1 ? 1 : diff.inHours;
      return isAr ? 'قبل $h ساعة' : '$h hours ago';
    }
    final d = diff.inDays <= 1 ? 1 : diff.inDays;
    return isAr ? 'قبل $d يوم' : '$d days ago';
  }
}

class _PropertyImage extends StatelessWidget {
  final List<String> urls;
  const _PropertyImage({required this.urls});

  bool _isUrl(String s) => s.startsWith('http://') || s.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (urls.isEmpty) {
      return Container(
        color: cs.surfaceVariant.withOpacity(0.55),
        child: const Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }

    final first = urls.first.trim();
    if (first.isEmpty) {
      return Container(
        color: cs.surfaceVariant.withOpacity(0.55),
        child: const Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }

    if (_isUrl(first)) {
      return Image.network(
        first,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: cs.surfaceVariant.withOpacity(0.55),
          child: const Center(child: Icon(Icons.image_not_supported_outlined)),
        ),
      );
    }

    return Image.asset(
      first,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: cs.surfaceVariant.withOpacity(0.55),
        child: const Center(child: Icon(Icons.image_not_supported_outlined)),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? background;
  final Color? foreground;

  const _Pill(
      {required this.text,
      required this.icon,
      this.background,
      this.foreground});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = background ?? cs.surface.withOpacity(0.92);
    final fg = foreground ?? cs.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w900, fontSize: 12)),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSmall = MediaQuery.of(context).size.width < 600;

    return TextField(
      onChanged: onChanged,
      style: TextStyle(fontWeight: FontWeight.w900, fontSize: isSmall ? 14 : 16),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w800,
            fontSize: isSmall ? 13 : 15),
        prefixIcon: Icon(Icons.search,
            color: cs.onSurfaceVariant, size: isSmall ? 20 : 24),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: cs.outlineVariant)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF0F766E), width: 1.6),
        ),
        isDense: true,
        filled: true,
        contentPadding: isSmall
            ? const EdgeInsets.symmetric(vertical: 12, horizontal: 12)
            : const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  final bool isAr;
  final String value;
  final ValueChanged<String> onChanged;

  const _SortMenu(
      {required this.isAr, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isSmall = MediaQuery.of(context).size.width < 600;

    return DropdownButtonHideUnderline(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          style: TextStyle(
              fontSize: isSmall ? 14 : 16, fontWeight: FontWeight.w900),
          items: [
            DropdownMenuItem(
                value: 'latest', child: Text(isAr ? 'الأحدث' : 'Latest')),
            DropdownMenuItem(
                value: 'price_low',
                child: Text(isAr ? 'السعر: الأقل' : 'Price: Low')),
            DropdownMenuItem(
                value: 'price_high',
                child: Text(isAr ? 'السعر: الأعلى' : 'Price: High')),
            DropdownMenuItem(
                value: 'area_high',
                child: Text(isAr ? 'المساحة: الأكبر' : 'Area: High')),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

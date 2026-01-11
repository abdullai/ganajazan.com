// lib/screens/user_dashboard.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../main.dart'; // langNotifier + themeModeNotifier (إن وُجد)
import '../models/property.dart';
import 'add_property_page.dart';
import 'chat_page.dart';
import 'settings_page.dart';
import 'package:flutter/foundation.dart';


class UserDashboard extends StatefulWidget {
  final String lang;
  const UserDashboard({super.key, required this.lang});

  @override
  State<UserDashboard> createState() => _UserDashboardState();
}

class _UserDashboardState extends State<UserDashboard> {
  static const Color _bankColor = Color(0xFF0F766E);

  final _sb = Supabase.instance.client;

  // Tabs: 0 Home, 1 My Ads, 2 Offers, 3 Support, 4 Settings
  int _tabIndex = 0;

  // Search/sort
  String _searchQuery = '';
  String _sortBy = 'latest';
  Timer? _debounce;

  // Loading/error
  bool _loadingHome = true;
  bool _loadingMine = true;
  bool _loadingOffers = true;

  String? _errorHome;
  String? _errorMine;
  String? _errorOffers;

  // Data
  List<Property> _all = const [];
  List<Property> _mine = const [];

  // Offers (reservations rows) related to my properties
  List<Map<String, dynamic>> _offers = const [];
  Map<String, Property> _myPropertyById = {};

  String get _lang => langNotifier.value;
  bool get _isAr => _lang == 'ar';
  String get _uid => _sb.auth.currentUser?.id ?? '';

  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // =========================
  // Data loading
  // =========================

  Future<void> _reloadAll() async {
    await Future.wait([
      _loadHome(),
      _loadMineAndOffers(),
    ]);
  }

  Future<void> _loadHome() async {
    setState(() {
      _loadingHome = true;
      _errorHome = null;
    });

    try {
      final data = await _sb
          .from('properties')
          .select(
            '''
            id,
            owner_id,
            title,
            description,
            location,
            city,
            type,
            area,
            price,
            is_auction,
            current_bid,
            views,
            status,
            created_at,
            property_images:property_images (
              path,
              sort_order
            )
            ''',
          )
          .order('created_at', ascending: false);

      final rows = (data as List).cast<Map>();

      final activeRows = rows.where((r) {
        final s = (r['status'] as String?) ?? 'active';
        return s == 'active';
      }).toList();

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

        return _propertyFromDb(row, imageUrls: imageUrls);
      }).toList();

      setState(() {
        _all = list;
        _loadingHome = false;
      });
    } catch (e) {
      setState(() {
        _errorHome = e.toString();
        _loadingHome = false;
      });
    }
  }

  Future<void> _loadMineAndOffers() async {
    setState(() {
      _loadingMine = true;
      _errorMine = null;
      _loadingOffers = true;
      _errorOffers = null;
    });

    try {
      if (_uid.isEmpty) {
        setState(() {
          _mine = const [];
          _offers = const [];
          _myPropertyById = {};
          _loadingMine = false;
          _loadingOffers = false;
        });
        return;
      }

      // 1) My properties
      final mineData = await _sb
          .from('properties')
          .select(
            '''
            id,
            owner_id,
            title,
            description,
            location,
            city,
            type,
            area,
            price,
            is_auction,
            current_bid,
            views,
            status,
            created_at,
            property_images:property_images (
              path,
              sort_order
            )
            ''',
          )
          .eq('owner_id', _uid)
          .order('created_at', ascending: false);

      final mineRows = (mineData as List).cast<Map>();

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

        return _propertyFromDb(row, imageUrls: imageUrls);
      }).toList();

      final byId = <String, Property>{};
      for (final p in mineList) {
        if (p.id.isNotEmpty) byId[p.id] = p;
      }

      setState(() {
        _mine = mineList;
        _myPropertyById = byId;
        _loadingMine = false;
      });

      // 2) Offers for my properties
      final myIds = byId.keys.toList();
      if (myIds.isEmpty) {
        setState(() {
          _offers = const [];
          _loadingOffers = false;
        });
        return;
      }

      final offersData = await _sb
          .from('reservations')
          .select('*')
          .inFilter('property_id', myIds)
          .order('created_at', ascending: false);

      final offersRows = (offersData as List).cast<Map<String, dynamic>>();

      setState(() {
        _offers = offersRows;
        _loadingOffers = false;
      });
    } catch (e) {
      setState(() {
        _errorMine = e.toString();
        _loadingMine = false;

        _errorOffers = e.toString();
        _loadingOffers = false;
      });
    }
  }

  // =========================
  // Model helpers
  // =========================

  Property _propertyFromDb(Map row, {required List<String> imageUrls}) {
    double toDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
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
      title: (row['title'] as String?) ?? '',
      type: _parseType(typeStr),
      description: (row['description'] as String?) ?? '',
      location: _mergeLocation(row),
      area: toDouble(row['area']),
      price: toDouble(row['price']),
      isAuction: (row['is_auction'] as bool?) ?? false,
      currentBid: row['current_bid'] == null ? null : toDouble(row['current_bid']),
      images: imageUrls,
      views: toInt(row['views']),
      createdAt: parseDt(row['created_at']),
    );
  }

  String _mergeLocation(Map row) {
    final loc = (row['location'] as String?)?.trim();
    final city = (row['city'] as String?)?.trim();
    if (loc != null && loc.isNotEmpty) return loc;
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
      await _sb.auth.signOut();
    } catch (_) {}

    if (!mounted) return;

    // ✅ مضمون يرجّع لتسجيل الدخول حتى لو الستاك ملخبط
    try {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
    } catch (_) {
      // fallback: يرجّع لأول صفحة
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _openAdd() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddPropertyPage()),
    );
    await _reloadAll();
  }

  // =========================
  // UI helpers / texts
  // =========================

  String _tabTitle() {
    switch (_tabIndex) {
      case 0:
        return _isAr ? 'الرئيسية' : 'Home';
      case 1:
        return _isAr ? 'إعلاناتي' : 'My Listings';
      case 2:
        return _isAr ? 'العروض' : 'Offers';
      case 3:
        return _isAr ? 'الدعم/الدردشة' : 'Support/Chat';
      case 4:
      default:
        return _isAr ? 'الإعدادات' : 'Settings';
    }
  }

  String _failLoadTitle() => _isAr ? 'تعذر تحميل البيانات' : 'Failed to load data';

  String _failLoadSubtitle() => _isAr
      ? 'تحقق من اتصال الإنترنت ثم أعد المحاولة.'
      : 'Check your internet connection then try again.';

  Widget _buildTopFilters({required VoidCallback onRefresh}) {
    final isHomeOrMine = _tabIndex == 0 || _tabIndex == 1;
    if (!isHomeOrMine) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 240, maxWidth: 620),
            child: _SearchField(
              hint: _isAr
                  ? 'ابحث (عنوان / موقع / وصف)...'
                  : 'Search (title / location / description)...',
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), () {
                  if (!mounted) return;
                  setState(() => _searchQuery = v);
                });
              },
            ),
          ),
          _SortMenu(
            isAr: _isAr,
            value: _sortBy,
            onChanged: (v) => setState(() => _sortBy = v),
          ),
          FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: Text(_isAr ? 'تحديث' : 'Refresh'),
          ),
        ],
      ),
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final homeItems = _filterList(_all);
    final myItems = _filterList(_mine);

    final navTheme = NavigationBarThemeData(
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontWeight: selected ? FontWeight.w900 : FontWeight.w800,
          fontSize: 12,
          color: selected ? _bankColor : cs.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? _bankColor : cs.onSurfaceVariant,
        );
      }),
    );

    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: PopScope(
        canPop: false,
        onPopInvoked: (_) => _logout(), // ✅ زر الرجوع يخرج ويعيدك لصفحة الدخول
        child: Scaffold(
          backgroundColor: cs.surface,
          appBar: AppBar(
            elevation: 0,
            title: Text(
              _tabTitle(),
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            actions: [
              IconButton(
                tooltip: _isAr ? 'إعدادات' : 'Settings',
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
              ),
              IconButton(
                tooltip: _isAr ? 'تسجيل خروج' : 'Logout',
                icon: _loggingOut
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout),
                onPressed: _loggingOut ? null : _logout,
              ),
            ],
            bottom: PreferredSize(
              preferredSize:
                  Size.fromHeight((_tabIndex == 0 || _tabIndex == 1) ? 92 : 0),
              child: (_tabIndex == 0 || _tabIndex == 1)
                  ? _buildTopFilters(
                      onRefresh: () async {
                        if (_tabIndex == 0) {
                          await _loadHome();
                        } else {
                          await _loadMineAndOffers();
                        }
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          body: SafeArea(
            child: IndexedStack(
              index: _tabIndex,
              children: [
                // 0) Home
                RefreshIndicator(
                  onRefresh: _loadHome,
                  child: _buildPropertiesBody(
                    loading: _loadingHome,
                    error: _errorHome,
                    items: homeItems,
                    emptyTitle: _isAr ? 'لا توجد إعلانات متاحة' : 'No listings available',
                    emptySubtitle: _isAr
                        ? 'حالياً لا يوجد أي إعلان في قاعدة البيانات. جرّب التحديث لاحقاً.'
                        : 'There are no listings in the database right now. Try again later.',
                  ),
                ),

                // 1) My Listings
                RefreshIndicator(
                  onRefresh: _loadMineAndOffers,
                  child: _buildPropertiesBody(
                    loading: _loadingMine,
                    error: _errorMine,
                    items: myItems,
                    emptyTitle: _isAr ? 'لا توجد إعلانات لك' : 'No listings for you',
                    emptySubtitle: _isAr
                        ? 'أضف إعلاناً جديداً وسيظهر هنا.'
                        : 'Add a new listing and it will appear here.',
                  ),
                ),

                // 2) Offers
                RefreshIndicator(
                  onRefresh: _loadMineAndOffers,
                  child: _buildOffersBody(),
                ),

                // 3) Support/Chat
                const ChatPage(),

                // 4) Settings
                SettingsPage(lang: _lang),
              ],
            ),
          ),
          floatingActionButton: (_tabIndex == 0 || _tabIndex == 1)
              ? FloatingActionButton.extended(
                  backgroundColor: _bankColor,
                  foregroundColor: Colors.white,
                  onPressed: _openAdd,
                  icon: const Icon(Icons.add_home_work_outlined),
                  label: Text(
                    _isAr ? 'إضافة إعلان' : 'Add Listing',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                )
              : null,
          bottomNavigationBar: NavigationBarTheme(
            data: navTheme,
            child: NavigationBar(
              selectedIndex: _tabIndex,
              onDestinationSelected: (i) => setState(() => _tabIndex = i),
              indicatorColor: _bankColor.withValues(alpha: 28),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home),
                  label: _isAr ? 'الرئيسية' : 'Home',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.list_alt_outlined),
                  selectedIcon: const Icon(Icons.list_alt),
                  label: _isAr ? 'إعلاناتي' : 'My Ads',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.local_offer_outlined),
                  selectedIcon: const Icon(Icons.local_offer),
                  label: _isAr ? 'العروض' : 'Offers',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.support_agent_outlined),
                  selectedIcon: const Icon(Icons.support_agent),
                  label: _isAr ? 'الدعم' : 'Support',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.settings_outlined),
                  selectedIcon: const Icon(Icons.settings),
                  label: _isAr ? 'الإعدادات' : 'Settings',
                ),
              ],
            ),
          ),
        ),
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

    // ✅ خطأ: نعرض نص عربي مناسب + نص توضيحي عربي بدل الإنجليزي
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
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          // نُبقي تفاصيل الخطأ للمطور فقط
          if (kDebugMode) Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Center(
            child: ElevatedButton.icon(
              onPressed: _reloadAll,
              icon: const Icon(Icons.refresh),
              label: Text(_isAr ? 'إعادة المحاولة' : 'Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _bankColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      );
    }

    // ✅ لا يوجد إعلانات: نعرض "لا توجد إعلانات متاحة" بدل "تعذر تحميل..."
    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.home_outlined,
                  size: 84,
                  color: _bankColor.withValues(alpha: 180),
                ),
                const SizedBox(height: 18),
                Text(
                  emptyTitle,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: cs.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  emptySubtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                ElevatedButton.icon(
                  onPressed: _reloadAll,
                  icon: const Icon(Icons.refresh),
                  label: Text(_isAr ? 'تحديث' : 'Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _bankColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
      isAr: _isAr,
      bankColor: _bankColor,
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
              _isAr ? 'تعذر تحميل العروض' : 'Failed to load offers',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _isAr ? 'تحقق من الاتصال ثم أعد المحاولة.' : 'Check connection then retry.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
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
              label: Text(_isAr ? 'إعادة المحاولة' : 'Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _bankColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
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
                Icon(
                  Icons.local_offer_outlined,
                  size: 84,
                  color: _bankColor.withValues(alpha: 180),
                ),
                const SizedBox(height: 18),
                Text(
                  _isAr ? 'لا توجد عروض على إعلاناتك' : 'No offers on your listings',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: cs.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  _isAr
                      ? 'عند وصول أي حجز/عرض (reservations) على عقاراتك سيظهر هنا.'
                      : 'When any reservation/offer is created for your properties, it will appear here.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                ElevatedButton.icon(
                  onPressed: _loadMineAndOffers,
                  icon: const Icon(Icons.refresh),
                  label: Text(_isAr ? 'تحديث' : 'Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _bankColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
        final propertyId = (r['property_id'] ?? '').toString();
        final p = _myPropertyById[propertyId];

        final createdAt = _tryParseDt(r['created_at']);
        final createdText =
            createdAt == null ? (_isAr ? 'غير معروف' : 'Unknown') : _timeAgo(createdAt, _isAr);

        final status = (r['status'] ?? r['state'] ?? '').toString();
        final amount = r['amount'] ?? r['price'] ?? r['offer_price'] ?? r['bid'] ?? r['value'];

        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 115)),
            boxShadow: [
              BoxShadow(
                blurRadius: 18,
                offset: const Offset(0, 10),
                color: Theme.of(context).colorScheme.shadow.withValues(alpha: 20),
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
                    color: _bankColor.withValues(alpha: 18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.local_offer_outlined, color: _bankColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p?.title ?? (_isAr ? 'إعلان' : 'Listing'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isAr ? 'منذ: $createdText' : 'Time: $createdText',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _MiniChip(
                            icon: Icons.tag,
                            text: _isAr
                                ? 'الحالة: ${status.isEmpty ? 'غير محدد' : status}'
                                : 'Status: ${status.isEmpty ? 'N/A' : status}',
                            bankColor: _bankColor,
                          ),
                          _MiniChip(
                            icon: Icons.payments_outlined,
                            text: _isAr
                                ? 'المبلغ: ${amount == null ? 'غير محدد' : amount.toString()}'
                                : 'Amount: ${amount == null ? 'N/A' : amount.toString()}',
                            bankColor: _bankColor,
                          ),
                          _MiniChip(
                            icon: Icons.person_outline,
                            text: _isAr
                                ? 'صاحب العرض: ${(r['user_id'] ?? r['buyer_id'] ?? 'N/A').toString()}'
                                : 'User: ${(r['user_id'] ?? r['buyer_id'] ?? 'N/A').toString()}',
                            bankColor: _bankColor,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  DateTime? _tryParseDt(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toLocal();
    if (v is String) return DateTime.tryParse(v)?.toLocal();
    return null;
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

// =========================
// Widgets
// =========================

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color bankColor;

  const _MiniChip({
    required this.icon,
    required this.text,
    required this.bankColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bankColor.withValues(alpha: 12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: bankColor.withValues(alpha: 38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: bankColor),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _PropertyGrid extends StatelessWidget {
  final List<Property> items;
  final String currentUserId;
  final bool isAr;
  final Color bankColor;

  const _PropertyGrid({
    required this.items,
    required this.currentUserId,
    required this.isAr,
    required this.bankColor,
  });

  int _crossAxisCount(double w) {
    if (w >= 1400) return 5;
    if (w >= 1100) return 4;
    if (w >= 860) return 3;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final cross = _crossAxisCount(w);

        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: w >= 900 ? 18 : 12,
            vertical: 12,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: w >= 900 ? 0.78 : 0.72,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final p = items[i];
            return _RealEstateCard(
              property: p,
              isOwner: p.ownerId == currentUserId,
              isAr: isAr,
              bankColor: bankColor,
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

  const _RealEstateCard({
    required this.property,
    required this.isOwner,
    required this.isAr,
    required this.bankColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final timeText = _timeAgo(property.createdAt, isAr);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 115)),
          boxShadow: [
            BoxShadow(
              blurRadius: 18,
              offset: const Offset(0, 10),
              color: cs.shadow.withValues(alpha: 26),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _PropertyImage(urls: property.images),
                    if (property.isAuction)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: _Pill(
                          text: isAr ? 'مزاد' : 'Auction',
                          icon: Icons.gavel_outlined,
                          background: Colors.orange.withValues(alpha: 242),
                          foreground: Colors.white,
                        ),
                      ),
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: _Pill(
                        text: '${property.views}',
                        icon: Icons.remove_red_eye_outlined,
                        background: Colors.black.withValues(alpha: 115),
                        foreground: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    property.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
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
                  Row(
                    children: [
                      Icon(Icons.location_on_outlined, size: 16, color: bankColor),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          property.location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.straighten_outlined, size: 16, color: bankColor),
                      const SizedBox(width: 4),
                      Text(
                        isAr ? '${property.area.toStringAsFixed(0)} م²' : '${property.area.toStringAsFixed(0)} m²',
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      Text(
                        property.isAuction
                            ? (isAr
                                ? 'أعلى مزايدة: ${_money(property.currentBid ?? 0)} ر.س'
                                : 'Top bid: ${_money(property.currentBid ?? 0)} SAR')
                            : (isAr ? 'السعر: ${_money(property.price)} ر.س' : 'Price: ${_money(property.price)} SAR'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: property.isAuction ? Colors.orange : Colors.green,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 18),
                  Row(
                    children: [
                      Text(
                        timeText,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: isAr ? 'مراسلة' : 'Message',
                        icon: Icon(Icons.chat_bubble_outline, color: bankColor),
                        onPressed: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
                        },
                      ),
                      if (isOwner)
                        IconButton(
                          tooltip: isAr ? 'حذف (إعلانك فقط)' : 'Delete (yours only)',
                          icon: const Icon(Icons.delete_outline),
                          color: Colors.red,
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                behavior: SnackBarBehavior.floating,
                                content: Text(isAr ? 'أضف منطق الحذف لاحقاً' : 'Add delete logic later'),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (urls.isEmpty) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }

    final first = urls.first;
    final isUrl = first.startsWith('http://') || first.startsWith('https://');

    if (isUrl) {
      return Image.network(
        first,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: cs.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.image_not_supported_outlined)),
        ),
      );
    }

    return Image.asset(
      first,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: cs.surfaceContainerHighest,
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

  const _Pill({
    required this.text,
    required this.icon,
    this.background,
    this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = background ?? cs.surface.withValues(alpha: 235);
    final fg = foreground ?? cs.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 115)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
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

    return TextField(
      onChanged: onChanged,
      style: const TextStyle(fontWeight: FontWeight.w900),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w800),
        prefixIcon: Icon(Icons.search, color: cs.onSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _UserDashboardState._bankColor, width: 1.6),
        ),
        isDense: true,
        filled: true,
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  final bool isAr;
  final String value;
  final ValueChanged<String> onChanged;

  const _SortMenu({
    required this.isAr,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DropdownButtonHideUnderline(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: DropdownButton<String>(
          value: value,
          items: [
            DropdownMenuItem(value: 'latest', child: Text(isAr ? 'الأحدث' : 'Latest')),
            DropdownMenuItem(value: 'price_low', child: Text(isAr ? 'السعر: الأقل' : 'Price: Low')),
            DropdownMenuItem(value: 'price_high', child: Text(isAr ? 'السعر: الأعلى' : 'Price: High')),
            DropdownMenuItem(value: 'area_high', child: Text(isAr ? 'المساحة: الأكبر' : 'Area: High')),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

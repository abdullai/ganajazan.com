// lib/screens/property_details_page.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/property.dart';

class PropertyDetailsPage extends StatefulWidget {
  final Property property;
  final bool isAr;
  final String currentUserId;

  /// ✅ من users_profiles.username (fallback على properties.username حسب اللي تمرره من الداشبورد)
  final String? ownerUsername;

  final bool isFavorite;
  final Future<void> Function() onToggleFavorite;

  const PropertyDetailsPage({
    super.key,
    required this.property,
    required this.isAr,
    required this.currentUserId,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.ownerUsername,
  });

  @override
  State<PropertyDetailsPage> createState() => _PropertyDetailsPageState();
}

class _PropertyDetailsPageState extends State<PropertyDetailsPage> {
  double? lat;
  double? lng;

  String _coordsKey(String id) => 'coords_$id';

  @override
  void initState() {
    super.initState();

    // ✅ DB First (بدون ما يسبب خطأ لو الموديل ما فيه latitude/longitude)
    final dbLat = _tryReadDbLat(widget.property);
    final dbLng = _tryReadDbLng(widget.property);

    if (dbLat != null && dbLng != null) {
      lat = dbLat;
      lng = dbLng;
    } else {
      _loadCoords(); // fallback قديم
    }
  }

  double? _tryReadDbLat(Property p) {
    try {
      final dynamic v = (p as dynamic).latitude;
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return null;
    } catch (_) {
      return null;
    }
  }

  double? _tryReadDbLng(Property p) {
    try {
      final dynamic v = (p as dynamic).longitude;
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadCoords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_coordsKey(widget.property.id));
    if (raw == null) return;

    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        lat = (m['lat'] as num?)?.toDouble();
        lng = (m['lng'] as num?)?.toDouble();
      });
    } catch (_) {}
  }

  // =========================
  // Pricing helpers
  // =========================
  double _vatAmount(double price) => price * 0.05;
  double _totalWithVat(double price) => price + _vatAmount(price);
  double _commissionAmount(double price) => _totalWithVat(price) * 0.025;

  String _money(double v) {
    final s = v.toStringAsFixed(0);
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final fromEnd = s.length - i;
      b.write(s[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) b.write(',');
    }
    return b.toString();
  }

  String _labelPrice(double v) => widget.isAr ? '${_money(v)} ر.س' : '${_money(v)} SAR';

  // =========================
  // Share text
  // =========================
  String _shareText({
    required String title,
    required String loc,
    required double base,
    required double vat,
    required double total,
    required double comm,
    required String id,
  }) {
    final u = widget.ownerUsername;
    final coords = (lat != null && lng != null)
        ? '${lat!.toStringAsFixed(6)}, ${lng!.toStringAsFixed(6)}'
        : null;

    if (widget.isAr) {
      final sb = StringBuffer()
        ..writeln('🏡 $title')
        ..writeln('📍 المدينة: $loc')
        ..writeln('🆔 رقم الإعلان: $id')
        ..writeln((u != null && u.trim().isNotEmpty) ? '👤 المعلن: ${u.trim()}' : '')
        ..writeln('💰 السعر: ${_labelPrice(base)}')
        ..writeln('🧾 الضريبة (5%): ${_labelPrice(vat)}')
        ..writeln('✅ الإجمالي بعد الضريبة: ${_labelPrice(total)}')
        ..writeln('🌐 عمولة المنصة (2.5%): ${_labelPrice(comm)}');
      if (coords != null) sb.writeln('🧭 الإحداثيات: $coords');
      sb.writeln('\n#Aqar');
      return sb.toString().trim();
    } else {
      final sb = StringBuffer()
        ..writeln('🏡 $title')
        ..writeln('📍 City: $loc')
        ..writeln('🆔 Listing ID: $id')
        ..writeln((u != null && u.trim().isNotEmpty) ? '👤 Owner: ${u.trim()}' : '')
        ..writeln('💰 Price: ${_labelPrice(base)}')
        ..writeln('🧾 VAT (5%): ${_labelPrice(vat)}')
        ..writeln('✅ Total incl. VAT: ${_labelPrice(total)}')
        ..writeln('🌐 Platform fee (2.5%): ${_labelPrice(comm)}');
      if (coords != null) sb.writeln('🧭 Coordinates: $coords');
      sb.writeln('\n#Aqar');
      return sb.toString().trim();
    }
  }

  Future<void> _copy(String text, {String? okMsgAr, String? okMsgEn}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.isAr ? (okMsgAr ?? 'تم النسخ') : (okMsgEn ?? 'Copied'))),
    );
  }

  // =========================
  // Cover helper: URL + asset + empty
  // =========================
  Widget _coverImage(ColorScheme cs, bool isDark) {
    final cover = widget.property.images.isNotEmpty ? widget.property.images.first.trim() : '';
    final isUrl = cover.startsWith('http://') || cover.startsWith('https://');

    if (cover.isEmpty) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Icon(Icons.image_not_supported_outlined, color: isDark ? Colors.white : cs.onSurface),
        ),
      );
    }

    if (isUrl) {
      return Image.network(
        cover,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: cs.surfaceContainerHighest,
          child: Center(child: Icon(Icons.image_not_supported_outlined, color: isDark ? Colors.white : cs.onSurface)),
        ),
      );
    }

    return Image.asset(
      cover,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: cs.surfaceContainerHighest,
        child: Center(child: Icon(Icons.image_not_supported_outlined, color: isDark ? Colors.white : cs.onSurface)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final textColor = isDark ? Colors.white : cs.onSurface;
    final subColor = isDark ? Colors.white70 : cs.onSurfaceVariant;

    final base = widget.property.isAuction ? (widget.property.currentBid ?? 0) : widget.property.price;
    final vat = _vatAmount(base);
    final total = _totalWithVat(base);
    final comm = _commissionAmount(base);

    final title = widget.property.title;
    final loc = widget.property.location;

    final shareText = _shareText(
      title: title,
      loc: loc,
      base: base,
      vat: vat,
      total: total,
      comm: comm,
      id: widget.property.id,
    );

    return Directionality(
      textDirection: widget.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          title: Text(
            widget.isAr ? 'تفاصيل الإعلان' : 'Listing details',
            style: TextStyle(color: textColor, fontWeight: FontWeight.w900),
          ),
          iconTheme: IconThemeData(color: isDark ? Colors.white : cs.onSurface),
          actions: [
            IconButton(
              tooltip: widget.isAr ? 'نسخ المعرف' : 'Copy ID',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => _copy(widget.property.id, okMsgAr: 'تم نسخ المعرّف', okMsgEn: 'ID copied'),
            ),
            IconButton(
              tooltip: widget.isAr ? 'مفضلة' : 'Favorite',
              icon: Icon(widget.isFavorite ? Icons.favorite : Icons.favorite_border),
              color: widget.isFavorite ? Colors.redAccent : (isDark ? Colors.white : cs.onSurface),
              onPressed: () async {
                await widget.onToggleFavorite();
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _AppHeader(isAr: widget.isAr, ownerUsername: widget.ownerUsername),
            const SizedBox(height: 12),

            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _coverImage(cs, isDark),
              ),
            ),
            const SizedBox(height: 12),

            Text(title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: textColor)),
            const SizedBox(height: 6),

            Row(
              children: [
                Icon(Icons.location_on_outlined, size: 18, color: isDark ? Colors.white : cs.onSurface),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(loc, style: TextStyle(color: subColor, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            _infoCard(
              isDark: isDark,
              title: widget.isAr ? 'الوصف' : 'Description',
              child: Text(
                widget.property.description,
                style: TextStyle(color: textColor, height: 1.6, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),

            _infoCard(
              isDark: isDark,
              title: widget.isAr ? 'تفاصيل العقار' : 'Property info',
              child: Column(
                children: [
                  _kv(
                    widget.isAr ? 'المساحة' : 'Area',
                    widget.isAr
                        ? '${widget.property.area.toStringAsFixed(0)} م²'
                        : '${widget.property.area.toStringAsFixed(0)} m²',
                    isDark,
                  ),
                  const SizedBox(height: 8),
                  _kv(widget.isAr ? 'النوع' : 'Type', _typeLabel(widget.property.type, widget.isAr), isDark),
                  const SizedBox(height: 8),
                  _kv(widget.isAr ? 'المشاهدات' : 'Views', '${widget.property.views}', isDark),
                ],
              ),
            ),
            const SizedBox(height: 10),

            _infoCard(
              isDark: isDark,
              title: widget.isAr ? 'الأسعار والرسوم' : 'Pricing & fees',
              child: Column(
                children: [
                  _kv(
                    widget.property.isAuction
                        ? (widget.isAr ? 'أعلى مزايدة' : 'Top bid')
                        : (widget.isAr ? 'السعر المطلوب' : 'Requested price'),
                    _labelPrice(base),
                    isDark,
                  ),
                  const SizedBox(height: 8),
                  _kv(widget.isAr ? 'الضريبة (5%)' : 'VAT (5%)', _labelPrice(vat), isDark),
                  const SizedBox(height: 8),
                  _kv(widget.isAr ? 'الإجمالي بعد الضريبة' : 'Total incl. VAT', _labelPrice(total), isDark,
                      emphasize: true),
                  const SizedBox(height: 8),
                  _kv(widget.isAr ? 'عمولة المنصة (2.5%)' : 'Platform fee (2.5%)', _labelPrice(comm), isDark),
                ],
              ),
            ),
            const SizedBox(height: 10),

            _infoCard(
              isDark: isDark,
              title: widget.isAr ? 'الإحداثيات' : 'Coordinates',
              child: (lat == null || lng == null)
                  ? Text(
                      widget.isAr ? 'لا توجد إحداثيات مضافة' : 'No coordinates added',
                      style: TextStyle(color: subColor, fontWeight: FontWeight.w800),
                    )
                  : Column(
                      children: [
                        _kv('Latitude', lat!.toStringAsFixed(6), isDark),
                        const SizedBox(height: 8),
                        _kv('Longitude', lng!.toStringAsFixed(6), isDark),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.copy_rounded),
                            label: Text(widget.isAr ? 'نسخ الإحداثيات' : 'Copy coords'),
                            onPressed: () => _copy(
                              '${lat!.toStringAsFixed(6)}, ${lng!.toStringAsFixed(6)}',
                              okMsgAr: 'تم النسخ',
                              okMsgEn: 'Copied',
                            ),
                          ),
                        ),
                      ],
                    ),
            ),

            const SizedBox(height: 14),

            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(widget.isAr ? 'نسخ نص للمشاركة' : 'Copy share text'),
                      onPressed: () => _copy(shareText, okMsgAr: 'تم نسخ نص المشاركة', okMsgEn: 'Share text copied'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(widget.isAr ? 'نسخ وصف الإعلان' : 'Copy description'),
                      onPressed: () => _copy(widget.property.description, okMsgAr: 'تم نسخ الوصف', okMsgEn: 'Description copied'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // =========================
  // UI helpers
  // =========================
  Widget _infoCard({required bool isDark, required String title, required Widget child}) {
    final cs = Theme.of(context).colorScheme;
    final textColor = isDark ? Colors.white : cs.onSurface;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.45)),
        color: isDark ? Colors.white.withOpacity(0.06) : cs.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: textColor, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _kv(String k, String v, bool isDark, {bool emphasize = false}) {
    final cs = Theme.of(context).colorScheme;
    final textColor = isDark ? Colors.white : cs.onSurface;
    final subColor = isDark ? Colors.white70 : cs.onSurfaceVariant;

    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(
              color: emphasize ? textColor : subColor,
              fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
            ),
          ),
        ),
        Text(
          v,
          style: TextStyle(
            color: textColor,
            fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
      ],
    );
  }

  static String _typeLabel(PropertyType t, bool isAr) {
    switch (t) {
      case PropertyType.villa:
        return isAr ? 'فيلا' : 'Villa';
      case PropertyType.apartment:
        return isAr ? 'شقة' : 'Apartment';
      case PropertyType.land:
        return isAr ? 'أرض' : 'Land';
    }
  }
}

class _AppHeader extends StatelessWidget {
  final bool isAr;
  final String? ownerUsername;

  const _AppHeader({required this.isAr, required this.ownerUsername});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final who = (ownerUsername == null || ownerUsername!.trim().isEmpty)
        ? (isAr ? 'معلن' : 'Owner')
        : ownerUsername!.trim();

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.45)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 54,
              height: 54,
              color: isDark ? Colors.white.withOpacity(0.06) : cs.surfaceContainerHighest,
              child: Image.asset(
                'assets/splashscreen.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(Icons.home_work_outlined, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aqar',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  isAr ? 'المعلن: $who' : 'Owner: $who',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: const Color(0xFF0F766E).withOpacity(0.12),
              border: Border.all(color: const Color(0xFF0F766E).withOpacity(0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_outlined, size: 16, color: Color(0xFF0F766E)),
                const SizedBox(width: 6),
                Text(
                  isAr ? 'تفاصيل' : 'Details',
                  style: const TextStyle(
                    color: Color(0xFF0F766E),
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

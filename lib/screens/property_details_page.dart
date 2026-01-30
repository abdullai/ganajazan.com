import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/property.dart';
import '../services/reservations_service.dart'; // ✅ مهم (getOrCreatePropertyConversation)
import 'chat_page.dart'; // ✅ ChatPage يستقبل conversationId

class PropertyDetailsPage extends StatefulWidget {
  final Property property;
  final bool isAr;
  final String currentUserId;
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
  bool _loadingCoords = false;

  bool _openingChat = false;

  bool get _isGuest => widget.currentUserId == 'guest';

  @override
  void initState() {
    super.initState();
    _loadCoordinates();
  }

  Future<void> _loadCoordinates() async {
    setState(() => _loadingCoords = true);

    if (widget.property.latitude != null && widget.property.longitude != null) {
      setState(() {
        lat = widget.property.latitude;
        lng = widget.property.longitude;
        _loadingCoords = false;
      });
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'coords_${widget.property.id}';
      final raw = prefs.getString(key);

      if (raw != null) {
        final data = json.decode(raw) as Map<String, dynamic>;
        setState(() {
          lat = (data['lat'] as num?)?.toDouble();
          lng = (data['lng'] as num?)?.toDouble();
        });
      }
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loadingCoords = false);
    }
  }

  void _snackLoginRequired() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          widget.isAr ? 'يجب تسجيل الدخول أولاً' : 'You must log in first',
        ),
      ),
    );
  }

  Future<void> _openChatWithOwner() async {
    if (_isGuest) {
      _snackLoginRequired();
      return;
    }

    if (_openingChat) return;

    setState(() => _openingChat = true);
    try {
      final conversationId =
          await ReservationsService.getOrCreatePropertyConversation(
        propertyId: widget.property.id,
        title: widget.property.title,
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            isAr: widget.isAr,
            conversationId: conversationId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(widget.isAr ? 'تعذر فتح الدردشة' : 'Failed to open chat'),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingChat = false);
    }
  }

  String _formatNumber(double value) {
    final s = value.toStringAsFixed(0);
    final buffer = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
      buffer.write(s[i]);
    }
    return buffer.toString();
  }

  String get _currencySymbol => widget.isAr ? 'ر.س' : 'SAR';

  double get _basePrice => widget.property.isAuction
      ? (widget.property.currentBid ?? widget.property.price)
      : widget.property.price;

  double get _vatAmount => _basePrice * 0.05;
  double get _platformFee => _basePrice * 0.025;
  double get _totalAfterVat => _basePrice + _vatAmount;
  double get _finalTotal => _basePrice + _vatAmount + _platformFee;

  String get _shareText {
    final ownerName = widget.ownerUsername?.trim() ?? '';
    final coordsText = (lat != null && lng != null)
        ? '\n📍 ${widget.isAr ? 'الإحداثيات:' : 'Coordinates:'} ${lat!.toStringAsFixed(6)}, ${lng!.toStringAsFixed(6)}'
        : '';

    return '''
🏡 ${widget.property.title}
📍 ${widget.isAr ? 'الموقع:' : 'Location:'} ${widget.property.location}
${ownerName.isNotEmpty ? '👤 ${widget.isAr ? 'المعلن:' : 'Owner:'} $ownerName' : ''}
💰 ${widget.isAr ? 'السعر:' : 'Price:'} ${_formatNumber(_basePrice)} $_currencySymbol
🧾 ${widget.isAr ? 'الضريبة (5%):' : 'VAT (5%):'} ${_formatNumber(_vatAmount)} $_currencySymbol
✅ ${widget.isAr ? 'الإجمالي بعد الضريبة:' : 'Total after VAT:'} ${_formatNumber(_totalAfterVat)} $_currencySymbol
🌐 ${widget.isAr ? 'عمولة المنصة (2.5%):' : 'Platform fee (2.5%):'} ${_formatNumber(_platformFee)} $_currencySymbol
🏁 ${widget.isAr ? 'الإجمالي النهائي:' : 'Final total:'} ${_formatNumber(_finalTotal)} $_currencySymbol$coordsText

#Aqar #${widget.isAr ? 'عقار' : 'RealEstate'}
''';
  }

  Future<void> _copyToClipboard(String text, {String? successMessage}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(successMessage ?? (widget.isAr ? 'تم النسخ' : 'Copied')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildCoverImage() {
    final cs = Theme.of(context).colorScheme;

    if (widget.property.images.isEmpty) {
      return Container(
        color: cs.surfaceVariant.withOpacity(0.6),
        child: Center(
          child: Icon(Icons.image_not_supported_outlined,
              size: 60, color: cs.onSurfaceVariant),
        ),
      );
    }

    final imageUrl = widget.property.images.first;

    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        final total = loadingProgress.expectedTotalBytes;
        final loaded = loadingProgress.cumulativeBytesLoaded;
        return Center(
          child: CircularProgressIndicator(
              value: total != null ? loaded / total : null),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: cs.surfaceVariant.withOpacity(0.6),
          child: Center(
            child: Icon(Icons.broken_image_outlined,
                size: 60, color: cs.onSurfaceVariant),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Directionality(
      textDirection: widget.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: cs.surface,
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 250,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                background: _buildCoverImage(),
                title: Text(
                  widget.property.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                          color: Colors.black,
                          blurRadius: 10,
                          offset: Offset(0, 0))
                    ],
                  ),
                ),
              ),
              actions: [
                Opacity(
                  opacity: _isGuest ? 0.5 : 1,
                  child: IconButton(
                    icon: Icon(
                      widget.isFavorite
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color:
                          widget.isFavorite ? Colors.red : Colors.white,
                    ),
                    onPressed: _isGuest
                        ? _snackLoginRequired
                        : () async => widget.onToggleFavorite(),
                  ),
                ),
              ],
            ),
            SliverList(
              delegate: SliverChildListDelegate([
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildOwnerCard(),
                      const SizedBox(height: 12),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: _openingChat
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.chat_bubble_outline),
                          label: Text(widget.isAr
                              ? 'مراسلة المعلن'
                              : 'Chat with owner'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0F766E),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed:
                              _openingChat ? null : _openChatWithOwner,
                        ),
                      ),

                      const SizedBox(height: 16),
                      _buildInfoRow(
                        icon: Icons.location_on_outlined,
                        title: widget.isAr ? 'الموقع' : 'Location',
                        value: widget.property.location,
                      ),
                      const SizedBox(height: 12),
                      _buildSection(
                        title: widget.isAr ? 'الوصف' : 'Description',
                        child: Text(
                          widget.property.description,
                          style: TextStyle(
                              fontSize: 16, color: cs.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildSection(
                        title: widget.isAr
                            ? 'تفاصيل العقار'
                            : 'Property Details',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _buildDetailChip(
                              icon: Icons.square_foot_outlined,
                              label: widget.isAr
                                  ? '${widget.property.area.toStringAsFixed(0)} م²'
                                  : '${widget.property.area.toStringAsFixed(0)} m²',
                              subtitle: widget.isAr ? 'المساحة' : 'Area',
                            ),
                            _buildDetailChip(
                              icon: Icons.home_outlined,
                              label: _getTypeLabel(widget.property.type),
                              subtitle: widget.isAr ? 'النوع' : 'Type',
                            ),
                            _buildDetailChip(
                              icon: Icons.remove_red_eye_outlined,
                              label: widget.property.views.toString(),
                              subtitle:
                                  widget.isAr ? 'المشاهدات' : 'Views',
                            ),
                            if (widget.property.isAuction)
                              _buildDetailChip(
                                icon: Icons.gavel_outlined,
                                label: widget.isAr ? 'مزاد' : 'Auction',
                                subtitle: widget.isAr ? 'الحالة' : 'Status',
                                color: Colors.orange,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildPricingSection(),
                      const SizedBox(height: 16),
                      _buildCoordinatesSection(),
                      const SizedBox(height: 24),
                      _buildCopyButtons(),
                    ],
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  // ====== UI helpers (كما هي عندك) ======

  Widget _buildOwnerCard() {
    final cs = Theme.of(context).colorScheme;
    final ownerName =
        widget.ownerUsername?.trim() ?? (widget.isAr ? 'معلن' : 'Owner');
    final verifiedText = widget.isAr ? 'موثّق' : 'Verified';

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
        boxShadow: [
          BoxShadow(
              color: cs.shadow.withOpacity(0.08),
              blurRadius: 10,
              offset: const Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFF0F766E).withOpacity(0.12),
            child: const Icon(Icons.person_outline, color: Color(0xFF0F766E)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ownerName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text(widget.isAr ? 'المعلن' : 'Property Owner',
                    style:
                        TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0F766E).withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: const Color(0xFF0F766E).withOpacity(0.30)),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_outlined,
                    size: 16, color: Color(0xFF0F766E)),
                const SizedBox(width: 6),
                Text(
                  verifiedText,
                  style: const TextStyle(
                      color: Color(0xFF0F766E),
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
      {required IconData icon,
      required String title,
      required String value}) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF0F766E), size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 4),
              Text(value,
                  style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSection({required String title, required Widget child}) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Color(0xFF0F766E))),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
            boxShadow: [
              BoxShadow(
                  color: cs.shadow.withOpacity(0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 4))
            ],
          ),
          child: child,
        ),
      ],
    );
  }

  Widget _buildDetailChip({
    required IconData icon,
    required String label,
    required String subtitle,
    Color? color,
  }) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? const Color(0xFF0F766E);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withOpacity(0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: c, fontWeight: FontWeight.bold, fontSize: 14)),
              Text(subtitle,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPricingSection() {
    return _buildSection(
      title: widget.isAr ? 'الأسعار والرسوم' : 'Pricing & Fees',
      child: Column(
        children: [
          _buildPriceRow(
              title: widget.isAr ? 'السعر الأساسي' : 'Base Price',
              amount: _basePrice,
              isHighlighted: true),
          const SizedBox(height: 8),
          _buildPriceRow(
              title: '${widget.isAr ? 'الضريبة' : 'VAT'} (5%)',
              amount: _vatAmount),
          const SizedBox(height: 8),
          _buildPriceRow(
              title: widget.isAr ? 'الإجمالي بعد الضريبة' : 'Total after VAT',
              amount: _totalAfterVat),
          const SizedBox(height: 8),
          _buildPriceRow(
              title: '${widget.isAr ? 'عمولة المنصة' : 'Platform Fee'} (2.5%)',
              amount: _platformFee),
          const Divider(height: 24, thickness: 1.5),
          _buildPriceRow(
            title: widget.isAr ? 'الإجمالي النهائي' : 'Final Total',
            amount: _finalTotal,
            isHighlighted: true,
            isTotal: true,
          ),
        ],
      ),
    );
  }

  Widget _buildPriceRow({
    required String title,
    required double amount,
    bool isHighlighted = false,
    bool isTotal = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final color = isTotal ? const Color(0xFF0F766E) : cs.onSurfaceVariant;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: TextStyle(
                fontSize: isTotal ? 16 : 14,
                fontWeight:
                    isHighlighted ? FontWeight.bold : FontWeight.normal,
                color: color)),
        Text('${_formatNumber(amount)} $_currencySymbol',
            style: TextStyle(
                fontSize: isTotal ? 18 : 14,
                fontWeight:
                    isHighlighted ? FontWeight.bold : FontWeight.normal,
                color: color)),
      ],
    );
  }

  Widget _buildCoordinatesSection() {
    final cs = Theme.of(context).colorScheme;

    return _buildSection(
      title: widget.isAr ? 'الإحداثيات' : 'Coordinates',
      child: _loadingCoords
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : (lat != null && lng != null)
              ? Column(
                  children: [
                    Row(
                      children: [
                        _buildCoordinateItem('Lat', lat!.toStringAsFixed(6)),
                        const SizedBox(width: 10),
                        _buildCoordinateItem('Lng', lng!.toStringAsFixed(6)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy_outlined),
                        label: Text(widget.isAr
                            ? 'نسخ الإحداثيات'
                            : 'Copy Coordinates'),
                        onPressed: () => _copyToClipboard(
                          '${lat!.toStringAsFixed(6)}, ${lng!.toStringAsFixed(6)}',
                          successMessage: widget.isAr
                              ? 'تم نسخ الإحداثيات'
                              : 'Coordinates copied',
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Text(
                    widget.isAr
                        ? 'لا توجد إحداثيات متاحة'
                        : 'No coordinates available',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
    );
  }

  Widget _buildCoordinateItem(String label, String value) {
    final cs = Theme.of(context).colorScheme;

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.surfaceVariant.withOpacity(0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
            ),
            child: Text(value,
                style: const TextStyle(fontFamily: 'Monospace', fontSize: 14)),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyButtons() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.share_outlined),
            label: Text(widget.isAr ? 'نسخ نص المشاركة' : 'Copy Share Text'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => _copyToClipboard(_shareText,
                successMessage:
                    widget.isAr ? 'تم نسخ نص المشاركة' : 'Share text copied'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.description_outlined),
            label: Text(widget.isAr ? 'نسخ وصف الإعلان' : 'Copy Description'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0F766E),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              side: const BorderSide(color: Color(0xFF0F766E)),
            ),
            onPressed: () => _copyToClipboard(widget.property.description,
                successMessage: widget.isAr ? 'تم نسخ الوصف' : 'Description copied'),
          ),
        ),
      ],
    );
  }

  String _getTypeLabel(PropertyType type) {
    switch (type) {
      case PropertyType.villa:
        return widget.isAr ? 'فيلا' : 'Villa';
      case PropertyType.apartment:
        return widget.isAr ? 'شقة' : 'Apartment';
      case PropertyType.land:
        return widget.isAr ? 'أرض' : 'Land';
    }
  }
}

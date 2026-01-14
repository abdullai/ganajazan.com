// lib/screens/add_property_page.dart

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class AddPropertyPage extends StatefulWidget {
  final String userId;
  final String lang;

  const AddPropertyPage({
    super.key,
    required this.userId,
    required this.lang,
  });

  @override
  State<AddPropertyPage> createState() => _AddPropertyPageState();
}

class _AddPropertyPageState extends State<AddPropertyPage> {
  final _sb = Supabase.instance.client;

  final _formKey = GlobalKey<FormState>();

  // Required fields
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _location = TextEditingController();
  final _city = TextEditingController();
  final _area = TextEditingController();
  final _price = TextEditingController();

  bool _isAuction = false;
  final _currentBid = TextEditingController();

  // DB enum exists
  String _type = 'villa'; // 'villa' | 'apartment' | 'land'

  bool _saving = false;
  String? _error;

  // picked images
  final List<_PickedImage> _images = [];

  bool get _isAr => widget.lang == 'ar';

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _location.dispose();
    _city.dispose();
    _area.dispose();
    _price.dispose();
    _currentBid.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_saving) return false;
    if (_images.isEmpty) return false;
    return true;
  }

  Future<void> _pickImages() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
        withData: true, // مهم للويب
      );

      if (res == null) return;

      final newOnes = res.files
          .where((f) => f.bytes != null && f.name.isNotEmpty)
          .map((f) => _PickedImage(name: f.name, bytes: f.bytes!))
          .toList();

      if (newOnes.isEmpty) return;

      setState(() => _images.addAll(newOnes));
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _removeImageAt(int i) => setState(() => _images.removeAt(i));

  void _moveImage(int from, int to) {
    setState(() {
      final item = _images.removeAt(from);
      _images.insert(to, item);
    });
  }

  double _parseDouble(String s) {
    final v = s.trim().replaceAll(',', '');
    return double.tryParse(v) ?? 0;
  }

  Future<void> _submit() async {
    setState(() => _error = null);

    final user = _sb.auth.currentUser;
    if (user == null) {
      setState(() => _error = _isAr ? 'يجب تسجيل الدخول أولاً' : 'You must sign in first');
      return;
    }

    final ok = _formKey.currentState?.validate() ?? false;
    if (!ok) return;

    if (_images.isEmpty) {
      setState(() => _error = _isAr ? 'اختر صورة واحدة على الأقل' : 'Pick at least one image');
      return;
    }

    setState(() => _saving = true);

    try {
      // إن كان userId المُمرر موجود (من الداشبورد) استخدمه، وإلا استخدم currentUser.id
      final ownerId = (widget.userId.trim().isNotEmpty) ? widget.userId.trim() : user.id;

      // 1) Insert property (get id)
      final inserted = await _sb
          .from('properties')
          .insert({
            'owner_id': ownerId,
            'title': _title.text.trim(),
            'description': _desc.text.trim(),
            'location': _location.text.trim(),
            'city': _city.text.trim(),
            'type': _type,
            'area': _parseDouble(_area.text),
            'price': _parseDouble(_price.text),
            'is_auction': _isAuction,
            'current_bid': _isAuction ? _parseDouble(_currentBid.text) : null,
            'views': 0,
            'status': 'active',
          })
          .select('id')
          .single();

      final propertyId = inserted['id'] as String;

      // 2) Upload images + insert property_images
      final bucket = _sb.storage.from('property-images');
      final uuid = const Uuid();

      final imagesToInsert = <Map<String, dynamic>>[];

      for (int i = 0; i < _images.length; i++) {
        final img = _images[i];

        final ext = _safeExt(img.name);
        final fileName = '${uuid.v4()}.$ext';
        final path = '$ownerId/$fileName';

        final contentType = _guessContentType(ext);

        await bucket.uploadBinary(
          path,
          img.bytes,
          fileOptions: FileOptions(
            upsert: false,
            contentType: contentType,
          ),
        );

        imagesToInsert.add({
          'property_id': propertyId,
          'path': path,
          'sort_order': i,
        });
      }

      if (imagesToInsert.isNotEmpty) {
        await _sb.from('property_images').insert(imagesToInsert);
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isAr ? 'تم نشر الإعلان بنجاح' : 'Listing published successfully')),
      );

      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _safeExt(String name) {
    final n = name.toLowerCase();
    final dot = n.lastIndexOf('.');
    if (dot == -1) return 'jpg';
    final ext = n.substring(dot + 1).trim();
    if (ext.isEmpty) return 'jpg';
    if (ext == 'jpeg') return 'jpg';
    return ext;
  }

  String _guessContentType(String ext) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'jpg':
      default:
        return 'image/jpeg';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          title: Text(_isAr ? 'إضافة إعلان' : 'Add Listing'),
          actions: [
            IconButton(
              tooltip: _isAr ? 'اختيار صور' : 'Pick images',
              icon: const Icon(Icons.photo_library_outlined),
              onPressed: _saving ? null : _pickImages,
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final maxW = w >= 1100 ? 980.0 : (w >= 900 ? 900.0 : w);

              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: w >= 900 ? 16 : 12,
                  vertical: 12,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _HeaderCard(isAr: _isAr),
                        const SizedBox(height: 12),

                        _ImagesCard(
                          isAr: _isAr,
                          images: _images,
                          saving: _saving,
                          onPick: _pickImages,
                          onRemove: _removeImageAt,
                          onMove: _moveImage,
                        ),
                        const SizedBox(height: 12),

                        _FormCard(
                          isAr: _isAr,
                          formKey: _formKey,
                          title: _title,
                          desc: _desc,
                          location: _location,
                          city: _city,
                          area: _area,
                          price: _price,
                          isAuction: _isAuction,
                          currentBid: _currentBid,
                          type: _type,
                          saving: _saving,
                          onAuctionChanged: (v) {
                            setState(() {
                              _isAuction = v;
                              if (!v) _currentBid.text = '';
                            });
                          },
                          onTypeChanged: (v) => setState(() => _type = v),
                        ),
                        const SizedBox(height: 12),

                        if (_error != null) _ErrorBox(text: _error!, isAr: _isAr),
                        const SizedBox(height: 12),

                        _SubmitBar(
                          isAr: _isAr,
                          saving: _saving,
                          enabled: _canSubmit,
                          onSubmit: _submit,
                        ),

                        const SizedBox(height: 18),

                        if (kIsWeb)
                          Text(
                            _isAr
                                ? 'ملاحظة: على الويب، اختر صورك من الجهاز وسيتم رفعها مباشرة إلى التخزين.'
                                : 'Note: On web, images are picked from your device and uploaded to storage.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// =======================
/// UI Pieces
/// =======================

class _HeaderCard extends StatelessWidget {
  final bool isAr;
  const _HeaderCard({required this.isAr});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 115)),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            offset: const Offset(0, 10),
            color: cs.shadow.withValues(alpha: 20),
          )
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 26),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.add_home_work_outlined, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr ? 'انشر إعلانك' : 'Publish your listing',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  isAr ? 'املأ الحقول الإلزامية وأضف صورًا واضحة.' : 'Fill required fields and add clear images.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImagesCard extends StatelessWidget {
  final bool isAr;
  final List<_PickedImage> images;
  final bool saving;
  final VoidCallback onPick;
  final void Function(int i) onRemove;
  final void Function(int from, int to) onMove;

  const _ImagesCard({
    required this.isAr,
    required this.images,
    required this.saving,
    required this.onPick,
    required this.onRemove,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 115)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isAr ? 'الصور (إلزامي)' : 'Images (required)',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: saving ? null : onPick,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(isAr ? 'اختيار صور' : 'Pick images'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (images.isEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 153),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.outlineVariant.withValues(alpha: 89)),
              ),
              child: Row(
                children: [
                  Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isAr ? 'لم يتم اختيار صور بعد' : 'No images selected yet',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: List.generate(images.length, (i) {
                final img = images[i];
                return _ImageThumb(
                  bytes: img.bytes,
                  index: i,
                  total: images.length,
                  isAr: isAr,
                  onRemove: saving ? null : () => onRemove(i),
                  onMoveLeft: saving || i == 0 ? null : () => onMove(i, i - 1),
                  onMoveRight: saving || i == images.length - 1 ? null : () => onMove(i, i + 1),
                );
              }),
            ),
          const SizedBox(height: 8),
          Text(
            isAr ? 'رتّب الصور: الصورة الأولى هي الغلاف.' : 'Reorder: first image is the cover.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ImageThumb extends StatelessWidget {
  final Uint8List bytes;
  final int index;
  final int total;
  final bool isAr;
  final VoidCallback? onRemove;
  final VoidCallback? onMoveLeft;
  final VoidCallback? onMoveRight;

  const _ImageThumb({
    required this.bytes,
    required this.index,
    required this.total,
    required this.isAr,
    this.onRemove,
    this.onMoveLeft,
    this.onMoveRight,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(bytes, fit: BoxFit.cover),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 115),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        index == 0 ? (isAr ? 'غلاف' : 'Cover') : '${index + 1}/$total',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                tooltip: isAr ? 'يسار' : 'Left',
                onPressed: onMoveLeft,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: isAr ? 'يمين' : 'Right',
                onPressed: onMoveRight,
                icon: const Icon(Icons.chevron_right),
              ),
              const Spacer(),
              IconButton(
                tooltip: isAr ? 'حذف' : 'Remove',
                onPressed: onRemove,
                icon: Icon(Icons.delete_outline, color: cs.error),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FormCard extends StatelessWidget {
  final bool isAr;
  final GlobalKey<FormState> formKey;

  final TextEditingController title;
  final TextEditingController desc;
  final TextEditingController location;
  final TextEditingController city;
  final TextEditingController area;
  final TextEditingController price;

  final bool isAuction;
  final TextEditingController currentBid;

  final String type;
  final bool saving;

  final ValueChanged<bool> onAuctionChanged;
  final ValueChanged<String> onTypeChanged;

  const _FormCard({
    required this.isAr,
    required this.formKey,
    required this.title,
    required this.desc,
    required this.location,
    required this.city,
    required this.area,
    required this.price,
    required this.isAuction,
    required this.currentBid,
    required this.type,
    required this.saving,
    required this.onAuctionChanged,
    required this.onTypeChanged,
  });

  String? _req(String? v, String msg) {
    if (v == null || v.trim().isEmpty) return msg;
    return null;
  }

  String? _numReq(String? v, String msg, {double min = 1}) {
    if (v == null || v.trim().isEmpty) return msg;
    final x = double.tryParse(v.trim().replaceAll(',', ''));
    if (x == null) return msg;
    if (x < min) return msg;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 115)),
      ),
      padding: const EdgeInsets.all(14),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'تفاصيل الإعلان (إلزامي)' : 'Listing details (required)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),

            _Field(
              controller: title,
              enabled: !saving,
              label: isAr ? 'العنوان' : 'Title',
              hint: isAr ? 'مثال: شقة فاخرة قريبة من الخدمات' : 'e.g. Modern apartment near services',
              validator: (v) => _req(v, isAr ? 'العنوان مطلوب' : 'Title is required'),
              maxLines: 1,
            ),
            const SizedBox(height: 10),

            _Field(
              controller: desc,
              enabled: !saving,
              label: isAr ? 'الوصف' : 'Description',
              hint: isAr ? 'اكتب تفاصيل واضحة...' : 'Write clear details...',
              validator: (v) => _req(v, isAr ? 'الوصف مطلوب' : 'Description is required'),
              maxLines: 4,
            ),
            const SizedBox(height: 10),

            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 820;

                final locationField = Expanded(
                  child: _Field(
                    controller: location,
                    enabled: !saving,
                    label: isAr ? 'الموقع' : 'Location',
                    hint: isAr ? 'مثال: الرياض - حطين' : 'e.g. Riyadh - Hittin',
                    validator: (v) => _req(v, isAr ? 'الموقع مطلوب' : 'Location is required'),
                    maxLines: 1,
                  ),
                );

                final cityField = Expanded(
                  child: _Field(
                    controller: city,
                    enabled: !saving,
                    label: isAr ? 'المدينة' : 'City',
                    hint: isAr ? 'مثال: الرياض' : 'e.g. Riyadh',
                    validator: (v) => _req(v, isAr ? 'المدينة مطلوبة' : 'City is required'),
                    maxLines: 1,
                  ),
                );

                return wide
                    ? Row(children: [locationField, const SizedBox(width: 10), cityField])
                    : Column(children: [locationField, const SizedBox(height: 10), cityField]);
              },
            ),
            const SizedBox(height: 10),

            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 820;

                final areaField = Expanded(
                  child: _Field(
                    controller: area,
                    enabled: !saving,
                    label: isAr ? 'المساحة (م²)' : 'Area (m²)',
                    hint: isAr ? 'مثال: 210' : 'e.g. 210',
                    validator: (v) => _numReq(v, isAr ? 'المساحة مطلوبة' : 'Area is required', min: 1),
                    keyboardType: TextInputType.number,
                    maxLines: 1,
                  ),
                );

                final priceField = Expanded(
                  child: _Field(
                    controller: price,
                    enabled: !saving,
                    label: isAr ? 'السعر (SAR)' : 'Price (SAR)',
                    hint: isAr ? 'مثال: 950000' : 'e.g. 950000',
                    validator: (v) => _numReq(v, isAr ? 'السعر مطلوب' : 'Price is required', min: 1),
                    keyboardType: TextInputType.number,
                    maxLines: 1,
                  ),
                );

                return wide
                    ? Row(children: [areaField, const SizedBox(width: 10), priceField])
                    : Column(children: [areaField, const SizedBox(height: 10), priceField]);
              },
            ),
            const SizedBox(height: 12),

            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 820;

                final typeField = Expanded(
                  child: _Dropdown(
                    enabled: !saving,
                    label: isAr ? 'نوع العقار' : 'Property type',
                    value: type,
                    items: [
                      _DropItem(value: 'villa', label: isAr ? 'فيلا' : 'Villa'),
                      _DropItem(value: 'apartment', label: isAr ? 'شقة' : 'Apartment'),
                      _DropItem(value: 'land', label: isAr ? 'أرض' : 'Land'),
                    ],
                    onChanged: onTypeChanged,
                  ),
                );

                final auctionField = Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cs.outlineVariant.withValues(alpha: 140)),
                      color: cs.surface,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.gavel_outlined, color: cs.onSurfaceVariant),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            isAr ? 'هذا الإعلان مزاد؟' : 'Is this an auction?',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Switch(
                          value: isAuction,
                          onChanged: saving ? null : onAuctionChanged,
                        ),
                      ],
                    ),
                  ),
                );

                return wide
                    ? Row(children: [typeField, const SizedBox(width: 10), auctionField])
                    : Column(children: [typeField, const SizedBox(height: 10), auctionField]);
              },
            ),

            if (isAuction) ...[
              const SizedBox(height: 10),
              _Field(
                controller: currentBid,
                enabled: !saving,
                label: isAr ? 'أعلى مزايدة حالية (SAR)' : 'Current top bid (SAR)',
                hint: isAr ? 'مثال: 1100000' : 'e.g. 1100000',
                validator: (v) => _numReq(v, isAr ? 'قيمة المزايدة مطلوبة' : 'Bid is required', min: 1),
                keyboardType: TextInputType.number,
                maxLines: 1,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SubmitBar extends StatelessWidget {
  final bool isAr;
  final bool saving;
  final bool enabled;
  final VoidCallback onSubmit;

  const _SubmitBar({
    required this.isAr,
    required this.saving,
    required this.enabled,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 115)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isAr
                  ? (enabled ? 'جاهز للنشر' : 'أكمل الحقول وأضف صورًا')
                  : (enabled ? 'Ready to publish' : 'Complete fields and add images'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: enabled ? cs.onSurface : cs.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: enabled ? onSubmit : null,
            icon: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.publish_outlined),
            label: Text(isAr ? 'نشر الإعلان' : 'Publish'),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String text;
  final bool isAr;
  const _ErrorBox({required this.text, required this.isAr});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 140),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.error.withValues(alpha: 64)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              textAlign: isAr ? TextAlign.right : TextAlign.left,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final String label;
  final String hint;
  final String? Function(String?)? validator;
  final int maxLines;
  final TextInputType? keyboardType;

  const _Field({
    required this.controller,
    required this.enabled,
    required this.label,
    required this.hint,
    this.validator,
    required this.maxLines,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      validator: validator,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        isDense: true,
        filled: true,
      ),
    );
  }
}

class _DropItem {
  final String value;
  final String label;
  const _DropItem({required this.value, required this.label});
}

class _Dropdown extends StatelessWidget {
  final bool enabled;
  final String label;
  final String value;
  final List<_DropItem> items;
  final ValueChanged<String> onChanged;

  const _Dropdown({
    required this.enabled,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        isDense: true,
        filled: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          items: items
              .map((e) => DropdownMenuItem(value: e.value, child: Text(e.label)))
              .toList(),
          onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
        ),
      ),
    );
  }
}

class _PickedImage {
  final String name;
  final Uint8List bytes;
  const _PickedImage({required this.name, required this.bytes});
}

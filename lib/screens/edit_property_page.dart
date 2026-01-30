// lib/screens/edit_property_page.dart
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/property.dart';
import '../services/watermark_service.dart';

class EditPropertyPage extends StatefulWidget {
  final Property property;
  final String userId;
  final String lang;

  const EditPropertyPage({
    super.key,
    required this.property,
    required this.userId,
    required this.lang,
  });

  @override
  State<EditPropertyPage> createState() => _EditPropertyPageState();
}

class _EditPropertyPageState extends State<EditPropertyPage> {
  final _sb = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late PropertyType _selectedType;

  late TextEditingController _priceController;
  late TextEditingController _areaController;

  bool get _isAr => widget.lang.toLowerCase() != 'en';
  String get _uid => _sb.auth.currentUser?.id ?? '';
  bool get _isGuest => _uid.isEmpty;

  bool _loading = true;
  bool _saving = false;

  // ✅ جديد: قفل أثناء اختيار الملفات (Flutter Web) لمنع تداخل rebuilds / رجوع غير مقصود
  bool _picking = false;

  String? _error;

  // قائمة موحدة للصور (موجودة + جديدة) للحذف/الترتيب
  final List<_EditImageItem> _items = [];
  final Set<String> _deletedExistingRowIds = {};
  final Set<String> _deletedExistingPaths = {};

  @override
  void initState() {
    super.initState();

    _titleController = TextEditingController(text: widget.property.title);
    _descriptionController = TextEditingController(text: widget.property.description);
    _selectedType = widget.property.type;

    _priceController = TextEditingController(text: widget.property.price.toString());
    _areaController = TextEditingController(text: widget.property.area.toString());

    _loadImages();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _areaController.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)),
    );
  }

  double _parseNum(String s) {
    final t = s.trim().replaceAll(',', '');
    return double.tryParse(t) ?? 0;
  }

  Future<void> _loadImages() async {
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _deletedExistingRowIds.clear();
      _deletedExistingPaths.clear();
    });

    try {
      // تحميل صور العقار من property_images (الأفضل والأصح من الاعتماد على property.images)
      final rows = await _sb
          .from('property_images')
          .select('id, path, sort_order')
          .eq('property_id', widget.property.id)
          .order('sort_order', ascending: true);

      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final id = (m['id'] ?? '').toString();
        final path = (m['path'] ?? '').toString();
        if (id.isEmpty || path.isEmpty) continue;

        _items.add(_EditImageItem.existing(rowId: id, path: path));
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _pickImages() async {
    if (_saving || _picking) return;

    if (_isGuest) {
      _showSnack(_isAr ? 'يجب تسجيل الدخول لتعديل الصور' : 'You must log in to edit images');
      return;
    }

    setState(() => _picking = true);

    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
        withData: true,
      );

      if (!mounted) return;

      if (res == null) return;

      final newOnes = res.files
          .where((f) => f.bytes != null && f.name.isNotEmpty)
          .map((f) => _EditImageItem.newOne(name: f.name, bytes: f.bytes!))
          .toList();

      if (newOnes.isEmpty) return;

      setState(() {
        _items.addAll(newOnes);
      });
    } catch (e) {
      if (mounted) {
        _showSnack(_isAr ? 'فشل اختيار الصور: $e' : 'Pick images failed: $e');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removeAt(int index) {
    final it = _items[index];

    setState(() {
      _items.removeAt(index);

      if (it.isExisting) {
        _deletedExistingRowIds.add(it.rowId!);
        _deletedExistingPaths.add(it.path!);
      }
    });
  }

  void _move(int from, int to) {
    if (from == to) return;
    setState(() {
      final item = _items.removeAt(from);
      _items.insert(to, item);
    });
  }

  String _storagePublicUrl(String path) {
    // إذا bucket public
    return _sb.storage.from('property-images').getPublicUrl(path);
  }

  Future<void> _save() async {
    if (_saving) return;

    if (_isGuest) {
      _showSnack(_isAr ? 'يجب تسجيل الدخول للتعديل' : 'You must log in to edit');
      return;
    }

    if (_uid != widget.property.ownerId) {
      _showSnack(_isAr ? 'لا تملك صلاحية تعديل هذا الإعلان' : 'You are not allowed to edit this listing');
      return;
    }

    final ok = _formKey.currentState?.validate() ?? false;
    if (!ok) return;

    if (_items.isEmpty) {
      _showSnack(_isAr ? 'يجب وجود صورة واحدة على الأقل' : 'At least one image is required');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final bucket = _sb.storage.from('property-images');
    final uuid = const Uuid();

    try {
      // 1) تحديث بيانات العقار
      final price = _parseNum(_priceController.text);
      final area = _parseNum(_areaController.text);

      await _sb.from('properties').update({
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'type': _selectedType.toString().split('.').last,
        'price': price,
        'area': area,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.property.id);

      // 2) حذف الصور المحذوفة من DB
      if (_deletedExistingRowIds.isNotEmpty) {
        await _sb.from('property_images').delete().inFilter('id', _deletedExistingRowIds.toList());
      }

      // 3) حذف ملفات storage للصور المحذوفة (اختياري لكنه الأفضل)
      if (_deletedExistingPaths.isNotEmpty) {
        try {
          await bucket.remove(_deletedExistingPaths.toList());
        } catch (_) {
          // تجاهل إذا policy تمنع delete أو bucket غير public… إلخ
        }
      }

      // 4) رفع الصور الجديدة + إدراجها في property_images
      // ثم نعيد بناء قائمة (موجود + جديد) لمعالجة sort_order النهائي.
      for (final it in _items.where((x) => x.isNew).toList()) {
        final fileName = '${uuid.v4()}.jpg';
        final path = '${_uid.trim()}/$fileName';

        Uint8List bytesToUpload = it.bytes!;
        try {
          bytesToUpload = await WatermarkService.addTextWatermark(
            bytesToUpload,
            text: '© عقار موثوق | Aqar-Reliable',
          );
        } catch (_) {}

        await bucket.uploadBinary(
          path,
          bytesToUpload,
          fileOptions: const FileOptions(upsert: false, contentType: 'image/jpeg'),
        );

        // أدخل صف جديد في property_images وأعد rowId
        final inserted = await _sb
            .from('property_images')
            .insert({
              'property_id': widget.property.id,
              'path': path,
              'sort_order': 0, // سيتم تصحيحه لاحقاً
            })
            .select('id')
            .single();

        final newRowId = (inserted['id'] ?? '').toString();

        // حول العنصر من "new" إلى "existing" داخل القائمة مع rowId/path
        final idx = _items.indexOf(it);
        if (idx >= 0) {
          _items[idx] = _EditImageItem.existing(rowId: newRowId, path: path);
        }
      }

      // 5) تحديث sort_order لجميع الصور حسب ترتيب _items الحالي
      for (int i = 0; i < _items.length; i++) {
        final it = _items[i];
        if (!it.isExisting || (it.rowId ?? '').isEmpty) continue;

        await _sb.from('property_images').update({
          'sort_order': i,
        }).eq('id', it.rowId!);
      }

      if (!mounted) return;

      _showSnack(_isAr ? 'تم حفظ التعديلات' : 'Changes saved');
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _getArabicTypeName(PropertyType type) {
    switch (type) {
      case PropertyType.villa:
        return 'فيلا';
      case PropertyType.apartment:
        return 'شقة';
      case PropertyType.land:
        return 'أرض';
      default:
        return type.toString().split('.').last;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isAr ? 'تعديل الإعلان' : 'Edit listing'),
          actions: [
            IconButton(
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (_isGuest) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
                      ),
                      child: Text(
                        _isAr ? 'أنت الآن زائر. سجّل الدخول لتعديل الإعلان.' : 'You are a guest. Log in to edit the listing.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _titleController,
                          enabled: !_saving && !_isGuest,
                          decoration: InputDecoration(
                            labelText: _isAr ? 'عنوان العقار' : 'Title',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final s = (v ?? '').trim();
                            if (s.isEmpty) return _isAr ? 'العنوان مطلوب' : 'Title is required';
                            if (s.length < 3) return _isAr ? 'العنوان قصير' : 'Title is too short';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),

                        DropdownButtonFormField<PropertyType>(
                          value: _selectedType,
                          decoration: InputDecoration(
                            labelText: _isAr ? 'نوع العقار' : 'Type',
                            border: const OutlineInputBorder(),
                          ),
                          items: PropertyType.values.map((type) {
                            return DropdownMenuItem<PropertyType>(
                              value: type,
                              child: Text(_isAr ? _getArabicTypeName(type) : type.toString().split('.').last),
                            );
                          }).toList(),
                          onChanged: (_saving || _isGuest)
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setState(() => _selectedType = value);
                                },
                        ),
                        const SizedBox(height: 12),

                        TextFormField(
                          controller: _priceController,
                          enabled: !_saving && !_isGuest,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: _isAr ? 'السعر (ريال)' : 'Price (SAR)',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final n = _parseNum(v ?? '');
                            if (n <= 0) return _isAr ? 'السعر غير صحيح' : 'Invalid price';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),

                        TextFormField(
                          controller: _areaController,
                          enabled: !_saving && !_isGuest,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: _isAr ? 'المساحة (م²)' : 'Area (m²)',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final n = _parseNum(v ?? '');
                            if (n <= 0) return _isAr ? 'المساحة غير صحيحة' : 'Invalid area';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),

                        TextFormField(
                          controller: _descriptionController,
                          enabled: !_saving && !_isGuest,
                          maxLines: 5,
                          decoration: InputDecoration(
                            labelText: _isAr ? 'الوصف' : 'Description',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final s = (v ?? '').trim();
                            if (s.isEmpty) return _isAr ? 'الوصف مطلوب' : 'Description is required';
                            if (s.length < 10) return _isAr ? 'الوصف قصير' : 'Description is too short';
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Images card
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _isAr ? 'صور الإعلان' : 'Listing images',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
                              ),
                            ),
                            ElevatedButton.icon(
                              // ✅ تعديل: تعطيل الزر أثناء _picking أيضًا
                              onPressed: (_saving || _isGuest || _picking) ? null : _pickImages,
                              icon: _picking
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.add_photo_alternate_outlined),
                              label: Text(_isAr ? 'إضافة صور' : 'Add images'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        if (_items.isEmpty)
                          Text(
                            _isAr ? 'لا توجد صور' : 'No images',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                          )
                        else
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: List.generate(_items.length, (i) {
                              final it = _items[i];

                              Widget img;
                              if (it.isExisting) {
                                img = Image.network(
                                  _storagePublicUrl(it.path!),
                                  fit: BoxFit.cover,
                                );
                              } else {
                                img = Image.memory(it.bytes!, fit: BoxFit.cover);
                              }

                              return _ImageTile(
                                index: i,
                                image: img,
                                disabled: _saving || _isGuest || _picking,
                                onRemove: () => _removeAt(i),
                                onMoveLeft: i == 0 ? null : () => _move(i, i - 1),
                                onMoveRight: i == _items.length - 1 ? null : () => _move(i, i + 1),
                              );
                            }),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Save button
                  SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: (_saving || _isGuest || _picking) ? null : _save,
                      icon: _saving
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save_outlined),
                      label: Text(_isAr ? 'حفظ التعديلات' : 'Save changes'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ImageTile extends StatelessWidget {
  final int index;
  final Widget image;
  final bool disabled;
  final VoidCallback onRemove;
  final VoidCallback? onMoveLeft;
  final VoidCallback? onMoveRight;

  const _ImageTile({
    required this.index,
    required this.image,
    required this.disabled,
    required this.onRemove,
    required this.onMoveLeft,
    required this.onMoveRight,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Container(
          width: 120,
          height: 120,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
          ),
          child: image,
        ),
        Positioned(
          top: 6,
          left: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: cs.surface.withOpacity(0.9),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
            ),
            child: Text(
              '#${index + 1}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: IconButton(
            onPressed: disabled ? null : onRemove,
            icon: const Icon(Icons.close),
            style: IconButton.styleFrom(
              backgroundColor: cs.surface.withOpacity(0.9),
              foregroundColor: cs.error,
              padding: const EdgeInsets.all(6),
            ),
          ),
        ),
        Positioned(
          bottom: 6,
          right: 6,
          child: Row(
            children: [
              IconButton(
                onPressed: disabled ? null : onMoveLeft,
                icon: const Icon(Icons.chevron_left),
                style: IconButton.styleFrom(
                  backgroundColor: cs.surface.withOpacity(0.9),
                  foregroundColor: cs.onSurface,
                  padding: const EdgeInsets.all(6),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: disabled ? null : onMoveRight,
                icon: const Icon(Icons.chevron_right),
                style: IconButton.styleFrom(
                  backgroundColor: cs.surface.withOpacity(0.9),
                  foregroundColor: cs.onSurface,
                  padding: const EdgeInsets.all(6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EditImageItem {
  final bool isExisting;
  final String? rowId; // id في property_images
  final String? path; // storage path
  final String? name;
  final Uint8List? bytes;

  const _EditImageItem._({
    required this.isExisting,
    this.rowId,
    this.path,
    this.name,
    this.bytes,
  });

  factory _EditImageItem.existing({required String rowId, required String path}) {
    return _EditImageItem._(isExisting: true, rowId: rowId, path: path);
  }

  factory _EditImageItem.newOne({required String name, required Uint8List bytes}) {
    return _EditImageItem._(isExisting: false, name: name, bytes: bytes);
  }

  bool get isNew => !isExisting;
}

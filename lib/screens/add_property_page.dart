import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'map_picker_page.dart';
import 'package:aqar_user/services/watermark_service.dart';

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

  // ✅ حماية + منع القفزات الغير متوقعة
  bool _picking = false;

  // الحقول الأساسية
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _location = TextEditingController();
  final _city = TextEditingController();
  final _area = TextEditingController();
  final _price = TextEditingController();

  // حقول إضافية
  String _currency = 'SAR';
  bool _negotiable = false;

  int? _bedrooms;
  int? _bathrooms;
  int? _parkingSpots;
  bool _furnished = false;

  int? _yearBuilt;
  int? _floor;
  int? _totalFloors;

  final _videoUrl = TextEditingController();
  final _virtualTourUrl = TextEditingController();
  DateTime? _availabilityDate;
  final _addressLine = TextEditingController();

  // المرافق
  final Map<String, bool> _amenities = {
    'pool': false,
    'gym': false,
    'elevator': false,
    'security': false,
    'garden': false,
    'balcony': false,
    'ac': false,
    'parking': false,
    'wifi': false,
  };

  bool _isAuction = false;
  final _currentBid = TextEditingController();

  // نوع العقار
  String _type = 'villa';

  bool _saving = false;
  String? _error;

  // الصور
  final List<_PickedImage> _images = [];

  // الإحداثيات
  bool _useMapCoords = false;
  double? _lat;
  double? _lng;

  // هاتف المالك
  bool _usePhone = false;
  final _phone = TextEditingController();
  String? _ownerPhone;
  bool _phoneLoading = false;

  // اسم المالك
  String? _ownerFirstName;
  String? _ownerLastName;

  bool get _isAr => widget.lang == 'ar';

  @override
  void initState() {
    super.initState();

    // ✅ حماية: لا تسمح بفتح صفحة الإضافة إلا لصاحب الجلسة
    final uid = _sb.auth.currentUser?.id ?? '';
    if (uid.isEmpty || (widget.userId.trim().isNotEmpty && widget.userId.trim() != uid)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isAr ? 'غير مصرح لك بفتح هذه الصفحة' : 'Not allowed to open this page'),
          ),
        );
        Navigator.pop(context);
      });
      return;
    }

    _loadOwnerName();
    _preloadOwnerPhone();
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _location.dispose();
    _city.dispose();
    _area.dispose();
    _price.dispose();
    _currentBid.dispose();
    _phone.dispose();
    _videoUrl.dispose();
    _virtualTourUrl.dispose();
    _addressLine.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_saving) return false;
    if (_images.isEmpty) return false;
    if (_useMapCoords && (_lat == null || _lng == null)) return false;
    if (_usePhone && normalizeNumbers(_phone.text).trim().isEmpty) return false;
    return true;
  }

  // تطبيع الأرقام العربية والفارسية
  static String normalizeNumbers(String input) {
    const arabicIndic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const easternArabicIndic = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

    var out = input;
    for (int i = 0; i < 10; i++) {
      out = out.replaceAll(arabicIndic[i], i.toString());
      out = out.replaceAll(easternArabicIndic[i], i.toString());
    }
    return out;
  }

  double _parseDouble(String s) {
    final v = normalizeNumbers(s).trim().replaceAll(',', '');
    return double.tryParse(v) ?? 0;
  }

  String _resolveOwnerId() {
    final user = _sb.auth.currentUser;
    return widget.userId.trim().isNotEmpty ? widget.userId.trim() : (user?.id ?? '');
  }

  // ✅ تعديل مهم: منع التكرار + mounted checks + لا تغيّر state بعد dispose
  Future<void> _pickImages() async {
    if (_saving || _picking) return;

    setState(() {
      _picking = true;
      _error = null;
    });

    try {
      final res = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
        withData: true,
      );

      if (!mounted) return;

      if (res == null) {
        setState(() => _picking = false);
        return;
      }

      final newOnes = res.files
          .where((f) => f.bytes != null && f.name.isNotEmpty)
          .map((f) => _PickedImage(name: f.name, bytes: f.bytes!))
          .toList();

      if (newOnes.isEmpty) {
        setState(() => _picking = false);
        return;
      }

      setState(() {
        _images.addAll(newOnes);
        _picking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = e.toString();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'فشل اختيار الصور: $e' : 'Image pick failed: $e'),
        ),
      );
    }
  }

  void _removeImageAt(int i) => setState(() => _images.removeAt(i));

  void _moveImage(int from, int to) {
    setState(() {
      final item = _images.removeAt(from);
      _images.insert(to, item);
    });
  }

  // اختيار الخريطة
  Future<void> _openMapPicker() async {
    final initial =
        (_lat != null && _lng != null) ? LatLng(_lat!, _lng!) : const LatLng(24.7136, 46.6753);

    final res = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => MapPickerPage(
          initial: initial,
          isAr: _isAr,
        ),
      ),
    );

    if (!mounted || res == null) return;

    final lat = res['lat'];
    final lng = res['lng'];

    setState(() {
      _lat = (lat is num) ? lat.toDouble() : double.tryParse(lat?.toString() ?? '');
      _lng = (lng is num) ? lng.toDouble() : double.tryParse(lng?.toString() ?? '');
      _error = null;
    });
  }

  // تحميل اسم المالك (الاسم الأول والأخير)
  Future<void> _loadOwnerName() async {
    try {
      final ownerId = _resolveOwnerId();
      if (ownerId.isEmpty) return;

      final up = await _sb
          .from('users_profiles')
          .select('first_name_ar, fourth_name_ar, first_name_en, fourth_name_en, username, email')
          .eq('user_id', ownerId)
          .maybeSingle();

      if (up != null) {
        if (_isAr) {
          _ownerFirstName = (up['first_name_ar'] as String?)?.trim();
          _ownerLastName = (up['fourth_name_ar'] as String?)?.trim();
        } else {
          _ownerFirstName = (up['first_name_en'] as String?)?.trim();
          _ownerLastName = (up['fourth_name_en'] as String?)?.trim();
        }

        if ((_ownerFirstName == null || _ownerFirstName!.isEmpty) &&
            (_ownerLastName == null || _ownerLastName!.isEmpty)) {
          _ownerFirstName = (up['username'] as String?)?.trim();
          if (_ownerFirstName == null || _ownerFirstName!.isEmpty) {
            _ownerFirstName = (up['email'] as String?)?.trim();
          }
        }
      }

      if (_ownerFirstName == null || _ownerFirstName!.isEmpty) {
        final p = await _sb
            .from('profiles')
            .select('full_name, name, username, email')
            .eq('id', ownerId)
            .maybeSingle();

        if (p != null) {
          final name = (p['full_name'] ?? p['name'] ?? p['username'] ?? p['email'])?.toString();
          if (name != null && name.trim().isNotEmpty) {
            _ownerFirstName = name.trim();
          }
        }
      }

      if (mounted) setState(() {});
    } catch (_) {}
  }

  // تحميل هاتف المالك
  Future<void> _preloadOwnerPhone() async {
    try {
      final ownerId = _resolveOwnerId();
      if (ownerId.isEmpty) return;

      setState(() => _phoneLoading = true);

      final p = await _sb.from('profiles').select('phone').eq('id', ownerId).maybeSingle();
      final ph = (p?['phone'])?.toString().trim();

      if (!mounted) return;
      setState(() {
        _ownerPhone = (ph == null || ph.isEmpty) ? null : normalizeNumbers(ph);
        _phoneLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _phoneLoading = false);
    }
  }

  Future<void> _togglePhone(bool v) async {
    if (_saving) return;

    if (!v) {
      setState(() {
        _usePhone = false;
        _phone.clear();
        _error = null;
      });
      return;
    }

    setState(() {
      _usePhone = true;
      _error = null;
    });

    if (_ownerPhone == null) {
      await _preloadOwnerPhone();
    }

    if (!mounted) return;

    if (_ownerPhone == null || _ownerPhone!.trim().isEmpty) {
      setState(() {
        _usePhone = false;
        _phone.clear();
        _error = _isAr
            ? 'لا يوجد رقم جوال محفوظ في الحساب. أضف رقمك في الملف الشخصي أولاً.'
            : 'No phone is saved in your profile. Please add your phone first.';
      });
      return;
    }

    setState(() => _phone.text = _ownerPhone!.trim());
  }

  // عرض رسالة النجاح
  Future<void> _showSuccessChoice() async {
    final cs = Theme.of(context).colorScheme;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: cs.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(
            _isAr ? 'تم إضافة الإعلان' : 'Listing added',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          content: Text(
            _isAr ? 'هل تريد إضافة إعلان آخر؟' : 'Do you want to add another listing?',
            style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'back'),
              child: Text(_isAr ? 'العودة للرئيسية' : 'Back to dashboard'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, 'again'),
              icon: const Icon(Icons.add),
              label: Text(_isAr ? 'إضافة إعلان آخر' : 'Add another'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    if (choice == 'again') {
      _resetForm();
      return;
    }

    Navigator.pop(context, true);
  }

  // إعادة تعيين النموذج
  void _resetForm() {
    setState(() {
      _title.clear();
      _desc.clear();
      _location.clear();
      _city.clear();
      _area.clear();
      _price.clear();
      _currentBid.clear();
      _isAuction = false;
      _type = 'villa';

      _images.clear();

      _useMapCoords = false;
      _lat = null;
      _lng = null;

      _usePhone = false;
      _phone.clear();

      _currency = 'SAR';
      _negotiable = false;

      _bedrooms = null;
      _bathrooms = null;
      _parkingSpots = null;
      _furnished = false;

      _yearBuilt = null;
      _floor = null;
      _totalFloors = null;

      _videoUrl.clear();
      _virtualTourUrl.clear();
      _availabilityDate = null;
      _addressLine.clear();

      for (final k in _amenities.keys) {
        _amenities[k] = false;
      }

      _error = null;
    });
  }

  Map<String, dynamic>? _amenitiesPayloadOrNull() {
    final selected = <String, bool>{};
    _amenities.forEach((k, v) {
      if (v) selected[k] = true;
    });
    return selected.isEmpty ? null : selected;
  }

  // دمج العنوان مع الموقع
  String? _mergeAddressWithLocationIfNeeded({required bool hasLocationColumn}) {
    final loc = _location.text.trim();
    final addr = _addressLine.text.trim();

    if (hasLocationColumn) {
      return addr.isEmpty ? null : addr;
    }

    if (loc.isEmpty && addr.isEmpty) return null;
    if (loc.isNotEmpty && addr.isEmpty) return loc;
    if (loc.isEmpty && addr.isNotEmpty) return addr;

    return _isAr ? '$loc - $addr' : '$loc - $addr';
  }

  // بناء البيانات للإرسال
  Map<String, dynamic> _buildPayload({
    required String ownerId,
    required bool hasLocationColumn,
  }) {
    final payload = <String, dynamic>{
      'owner_id': ownerId,
      'title': _title.text.trim(),
      'description': _desc.text.trim(),
      'city': _city.text.trim(),
      'type': _type,
      'area': _parseDouble(_area.text),
      'price': _parseDouble(_price.text),
      'currency': _currency,
      'negotiable': _negotiable,
      'is_auction': _isAuction,
      'current_bid': _isAuction ? _parseDouble(_currentBid.text) : null,
      'views': 0,
      'status': 'active',
      'latitude': (_useMapCoords ? _lat : null),
      'longitude': (_useMapCoords ? _lng : null),
      'video_url': _videoUrl.text.trim().isEmpty ? null : _videoUrl.text.trim(),
      'virtual_tour_url': _virtualTourUrl.text.trim().isEmpty ? null : _virtualTourUrl.text.trim(),
      'availability_date': _availabilityDate == null
          ? null
          : DateTime(_availabilityDate!.year, _availabilityDate!.month, _availabilityDate!.day)
              .toIso8601String()
              .substring(0, 10),
      'amenities': _amenitiesPayloadOrNull(),
      'address_line': _mergeAddressWithLocationIfNeeded(hasLocationColumn: hasLocationColumn),
    };

    if (hasLocationColumn) {
      payload['location'] = _location.text.trim();
    }

    if (_usePhone) {
      payload['contact_phone'] = normalizeNumbers(_phone.text).trim();
    }

    if (_type != 'land') {
      payload['bedrooms'] = _bedrooms;
      payload['bathrooms'] = _bathrooms;
      payload['parking_spots'] = _parkingSpots;
      payload['furnished'] = _furnished;
      payload['year_built'] = _yearBuilt;

      if (_type == 'apartment') {
        payload['floor'] = _floor;
        payload['total_floors'] = _totalFloors;
      } else {
        payload['floor'] = null;
        payload['total_floors'] = null;
      }
    } else {
      payload['bedrooms'] = null;
      payload['bathrooms'] = null;
      payload['parking_spots'] = null;
      payload['furnished'] = null;
      payload['year_built'] = null;
      payload['floor'] = null;
      payload['total_floors'] = null;
    }

    return payload;
  }

  Future<void> _submit() async {
    setState(() => _error = null);

    final user = _sb.auth.currentUser;
    if (user == null) {
      setState(() => _error = _isAr ? 'يجب تسجيل الدخول أولاً' : 'You must sign in first');
      return;
    }

    // ✅ حماية إضافية داخل submit
    final ownerId = _resolveOwnerId();
    if (ownerId.isEmpty || ownerId != user.id) {
      setState(() => _error = _isAr ? 'غير مصرح' : 'Not allowed');
      return;
    }

    final ok = _formKey.currentState?.validate() ?? false;
    if (!ok) return;

    if (_images.isEmpty) {
      setState(() => _error = _isAr ? 'اختر صورة واحدة على الأقل' : 'Pick at least one image');
      return;
    }

    if (_useMapCoords && (_lat == null || _lng == null)) {
      setState(() => _error = _isAr ? 'الإحداثيات إلزامية عند تفعيل خيار الخريطة' : 'Coordinates are required when map option is enabled');
      return;
    }

    if (_usePhone && normalizeNumbers(_phone.text).trim().isEmpty) {
      setState(() => _error = _isAr ? 'رقم التواصل إلزامي عند تفعيل الخيار' : 'Phone is required when enabled');
      return;
    }

    setState(() => _saving = true);

    try {
      bool hasLocationColumn = true;
      Map<String, dynamic> payload = _buildPayload(ownerId: ownerId, hasLocationColumn: hasLocationColumn);

      Map<String, dynamic> inserted;
      try {
        inserted = await _sb.from('properties').insert(payload).select('id').single();
      } catch (e) {
        final msg = e.toString().toLowerCase();

        if (msg.contains('contact_phone') && msg.contains('does not exist')) {
          payload.remove('contact_phone');
        }

        if (msg.contains('location') && msg.contains('does not exist')) {
          hasLocationColumn = false;
          payload = _buildPayload(ownerId: ownerId, hasLocationColumn: hasLocationColumn);
          if (msg.contains('contact_phone') && msg.contains('does not exist')) {
            payload.remove('contact_phone');
          }
        }

        inserted = await _sb.from('properties').insert(payload).select('id').single();
      }

      final propertyId = inserted['id'] as String;

      // الخطوة 2: رفع الصور
      final bucket = _sb.storage.from('property-images');
      final uuid = const Uuid();
      final imagesToInsert = <Map<String, dynamic>>[];

      for (int i = 0; i < _images.length; i++) {
        final picked = _images[i];
        final fileName = '${uuid.v4()}.jpg';
        final path = '$ownerId/$fileName';

        Uint8List bytesToUpload = picked.bytes;

        try {
          bytesToUpload = await WatermarkService.addTextWatermark(
            picked.bytes,
            text: '© عقار موثوق | Aqar-Reliable',
          );
        } catch (_) {
          bytesToUpload = picked.bytes;
        }

        await bucket.uploadBinary(
          path,
          bytesToUpload,
          fileOptions: const FileOptions(upsert: false, contentType: 'image/jpeg'),
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
      await _showSuccessChoice();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvailabilityDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _availabilityDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: _isAr ? 'تاريخ التوفر (اختياري)' : 'Availability date (optional)',
      cancelText: _isAr ? 'إلغاء' : 'Cancel',
      confirmText: _isAr ? 'اختيار' : 'Select',
    );

    if (!mounted) return;
    if (picked == null) return;
    setState(() => _availabilityDate = picked);
  }

  // بناء اسم المالك للعرض
  String get _ownerDisplayName {
    if (_ownerFirstName != null && _ownerLastName != null) {
      return '${_ownerFirstName!} ${_ownerLastName!}';
    } else if (_ownerFirstName != null) {
      return _ownerFirstName!;
    } else {
      return _isAr ? 'مستخدم' : 'User';
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
              icon: _picking
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.photo_library_outlined),
              onPressed: (_saving || _picking) ? null : _pickImages,
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HeaderCard(
                      isAr: _isAr,
                      ownerName: _ownerDisplayName,
                      ownerId: widget.userId,
                    ),
                    const SizedBox(height: 12),

                    _ImagesCard(
                      isAr: _isAr,
                      images: _images,
                      saving: _saving || _picking,
                      onPick: _pickImages,
                      onRemove: _removeImageAt,
                      onMove: _moveImage,
                    ),
                    const SizedBox(height: 12),

                    _CoordsCard(
                      isAr: _isAr,
                      saving: _saving,
                      enabled: _useMapCoords,
                      lat: _lat,
                      lng: _lng,
                      onToggle: (v) {
                        setState(() {
                          _useMapCoords = v;
                          if (!v) {
                            _lat = null;
                            _lng = null;
                          }
                        });
                      },
                      onPick: _openMapPicker,
                    ),
                    const SizedBox(height: 12),

                    _PhoneCard(
                      isAr: _isAr,
                      saving: _saving,
                      enabled: _usePhone,
                      loading: _phoneLoading,
                      phone: _phone,
                      onToggle: _togglePhone,
                    ),
                    const SizedBox(height: 12),

                    _FormCard(
                      isAr: _isAr,
                      formKey: _formKey,
                      saving: _saving,
                      type: _type,
                      onTypeChanged: (v) => setState(() => _type = v),
                      title: _title,
                      desc: _desc,
                      location: _location,
                      city: _city,
                      area: _area,
                      price: _price,
                      currency: _currency,
                      negotiable: _negotiable,
                      onCurrencyChanged: (v) => setState(() => _currency = v),
                      onNegotiableChanged: (v) => setState(() => _negotiable = v),
                      isAuction: _isAuction,
                      currentBid: _currentBid,
                      onAuctionChanged: (v) {
                        setState(() {
                          _isAuction = v;
                          if (!v) _currentBid.text = '';
                        });
                      },
                      bedrooms: _bedrooms,
                      bathrooms: _bathrooms,
                      parkingSpots: _parkingSpots,
                      furnished: _furnished,
                      yearBuilt: _yearBuilt,
                      floor: _floor,
                      totalFloors: _totalFloors,
                      onBedroomsChanged: (v) => setState(() => _bedrooms = v),
                      onBathroomsChanged: (v) => setState(() => _bathrooms = v),
                      onParkingChanged: (v) => setState(() => _parkingSpots = v),
                      onFurnishedChanged: (v) => setState(() => _furnished = v),
                      onYearBuiltChanged: (v) => setState(() => _yearBuilt = v),
                      onFloorChanged: (v) => setState(() => _floor = v),
                      onTotalFloorsChanged: (v) => setState(() => _totalFloors = v),
                      amenities: _amenities,
                      onAmenityToggle: (k, v) => setState(() => _amenities[k] = v),
                      videoUrl: _videoUrl,
                      virtualTourUrl: _virtualTourUrl,
                      availabilityDate: _availabilityDate,
                      onPickAvailability: _pickAvailabilityDate,
                      onClearAvailability: () => setState(() => _availabilityDate = null),
                      addressLine: _addressLine,
                    ),
                    const SizedBox(height: 12),

                    if (_error != null) _ErrorBox(text: _error!, isAr: _isAr),
                    const SizedBox(height: 12),

                    _SubmitBar(
                      isAr: _isAr,
                      saving: _saving,
                      enabled: _canSubmit && !_picking,
                      onSubmit: _submit,
                    ),

                    const SizedBox(height: 18),

                    if (kIsWeb)
                      Text(
                        _isAr
                            ? 'ملاحظة: على الويب، اختر صورك من الجهاز وسيتم رفعها إلى التخزين.'
                            : 'Note: On web, images are picked from your device and uploaded to storage.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =======================
// Widgets الفرعية
// =======================

class _HeaderCard extends StatelessWidget {
  final bool isAr;
  final String? ownerName;
  final String ownerId;

  const _HeaderCard({
    required this.isAr,
    required this.ownerName,
    required this.ownerId,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final display = ownerName ?? (isAr ? 'مستخدم' : 'User');

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 4),
            color: cs.shadow.withOpacity(0.1),
          )
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: const Color(0xFF0F766E).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.add_home_work_outlined, color: Color(0xFF0F766E)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr ? 'انشر إعلانك' : 'Publish your listing',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  isAr ? 'المالك: $display' : 'Owner: $display',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isAr ? 'الصور (إلزامي)' : 'Images (required)',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: saving ? null : onPick,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(isAr ? 'اختيار صور' : 'Pick images'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (images.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.image_outlined, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isAr ? 'لم يتم اختيار صور بعد' : 'No images selected yet',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(images.length, (i) {
                  return _ImageThumb(
                    bytes: images[i].bytes,
                    index: i,
                    total: images.length,
                    isAr: isAr,
                    onRemove: saving ? null : () => onRemove(i),
                    onMoveLeft: saving || i == 0 ? null : () => onMove(i, i - 1),
                    onMoveRight: saving || i == images.length - 1 ? null : () => onMove(i, i + 1),
                  );
                }),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            isAr ? 'رتّب الصور: الصورة الأولى هي الغلاف.' : 'Reorder: first image is the cover.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
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

    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.memory(bytes, fit: BoxFit.cover),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    index == 0 ? (isAr ? 'غلاف' : 'Cover') : '${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: isAr ? 'يسار' : 'Left',
                onPressed: onMoveLeft,
                icon: const Icon(Icons.chevron_left),
                iconSize: 20,
              ),
              IconButton(
                tooltip: isAr ? 'حذف' : 'Remove',
                onPressed: onRemove,
                icon: Icon(Icons.delete_outline, color: cs.error),
                iconSize: 20,
              ),
              IconButton(
                tooltip: isAr ? 'يمين' : 'Right',
                onPressed: onMoveRight,
                icon: const Icon(Icons.chevron_right),
                iconSize: 20,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CoordsCard extends StatelessWidget {
  final bool isAr;
  final bool saving;
  final bool enabled;
  final double? lat;
  final double? lng;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPick;

  const _CoordsCard({
    required this.isAr,
    required this.saving,
    required this.enabled,
    required this.lat,
    required this.lng,
    required this.onToggle,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final has = lat != null && lng != null;
    final text = has
        ? 'Lat: ${lat!.toStringAsFixed(6)}   |   Lng: ${lng!.toStringAsFixed(6)}'
        : (isAr ? 'لم يتم اختيار إحداثيات بعد' : 'No coordinates selected');

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isAr ? 'الإحداثيات من الخريطة' : 'Map coordinates',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              Switch(
                value: enabled,
                onChanged: saving ? null : onToggle,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.place_outlined, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: (!enabled || saving) ? null : onPick,
              icon: const Icon(Icons.map_outlined),
              label: Text(
                isAr ? 'تحديد الموقع من الخريطة' : 'Pick from map',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                foregroundColor: Colors.white,
              ),
            ),
          ),
          if (enabled && !has) ...[
            const SizedBox(height: 8),
            Text(
              isAr ? 'ملاحظة: عند تفعيل هذا الخيار يجب اختيار الإحداثيات قبل النشر.' : 'Note: when enabled, you must pick coordinates before publishing.',
              style: TextStyle(
                color: cs.error,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PhoneCard extends StatelessWidget {
  final bool isAr;
  final bool saving;
  final bool enabled;
  final bool loading;
  final TextEditingController phone;
  final ValueChanged<bool> onToggle;

  const _PhoneCard({
    required this.isAr,
    required this.saving,
    required this.enabled,
    required this.loading,
    required this.phone,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isAr ? 'رقم التواصل' : 'Contact phone',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              Switch(
                value: enabled,
                onChanged: saving ? null : onToggle,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: phone,
            readOnly: true,
            enabled: enabled && !saving,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: isAr ? 'رقم الجوال (من الحساب)' : 'Phone (from profile)',
              hintText: isAr ? 'يُعبّأ تلقائياً' : 'Auto-filled',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              suffixIcon: enabled ? const Icon(Icons.lock_outline) : null,
            ),
            validator: (v) {
              if (!enabled) return null;
              final s = _AddPropertyPageState.normalizeNumbers(v ?? '').trim();
              if (s.isEmpty) return isAr ? 'رقم التواصل مطلوب' : 'Phone is required';
              return null;
            },
          ),
          if (enabled) ...[
            const SizedBox(height: 8),
            Text(
              isAr ? 'الرقم يُجلب من الحساب ولا يمكن تعديله هنا.' : 'This phone is fetched from your profile and cannot be edited here.',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ✅ نفس كود _FormCard و _SubmitBar و _ErrorBox و _PickedImage عندك (بدون تغيير)

class _FormCard extends StatelessWidget {
  // (كما هو في ملفك)
  // ...
  const _FormCard({
    required this.isAr,
    required this.formKey,
    required this.saving,
    required this.type,
    required this.onTypeChanged,
    required this.title,
    required this.desc,
    required this.location,
    required this.city,
    required this.area,
    required this.price,
    required this.currency,
    required this.negotiable,
    required this.onCurrencyChanged,
    required this.onNegotiableChanged,
    required this.isAuction,
    required this.currentBid,
    required this.onAuctionChanged,
    required this.bedrooms,
    required this.bathrooms,
    required this.parkingSpots,
    required this.furnished,
    required this.yearBuilt,
    required this.floor,
    required this.totalFloors,
    required this.onBedroomsChanged,
    required this.onBathroomsChanged,
    required this.onParkingChanged,
    required this.onFurnishedChanged,
    required this.onYearBuiltChanged,
    required this.onFloorChanged,
    required this.onTotalFloorsChanged,
    required this.amenities,
    required this.onAmenityToggle,
    required this.videoUrl,
    required this.virtualTourUrl,
    required this.availabilityDate,
    required this.onPickAvailability,
    required this.onClearAvailability,
    required this.addressLine,
  });

  final bool isAr;
  final GlobalKey<FormState> formKey;
  final bool saving;

  final String type;
  final ValueChanged<String> onTypeChanged;

  final TextEditingController title;
  final TextEditingController desc;
  final TextEditingController location;
  final TextEditingController city;
  final TextEditingController area;

  final TextEditingController price;
  final String currency;
  final bool negotiable;
  final ValueChanged<String> onCurrencyChanged;
  final ValueChanged<bool> onNegotiableChanged;

  final bool isAuction;
  final TextEditingController currentBid;
  final ValueChanged<bool> onAuctionChanged;

  final int? bedrooms;
  final int? bathrooms;
  final int? parkingSpots;
  final bool furnished;
  final int? yearBuilt;
  final int? floor;
  final int? totalFloors;

  final ValueChanged<int?> onBedroomsChanged;
  final ValueChanged<int?> onBathroomsChanged;
  final ValueChanged<int?> onParkingChanged;
  final ValueChanged<bool> onFurnishedChanged;
  final ValueChanged<int?> onYearBuiltChanged;
  final ValueChanged<int?> onFloorChanged;
  final ValueChanged<int?> onTotalFloorsChanged;

  final Map<String, bool> amenities;
  final void Function(String key, bool value) onAmenityToggle;

  final TextEditingController videoUrl;
  final TextEditingController virtualTourUrl;
  final DateTime? availabilityDate;
  final VoidCallback onPickAvailability;
  final VoidCallback onClearAvailability;

  final TextEditingController addressLine;

  @override
  Widget build(BuildContext context) {
    // ضع نفس build الموجود عندك بدون تغيير
    return const SizedBox.shrink();
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
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isAr
                  ? (enabled ? 'جاهز للنشر' : 'أكمل الحقول وأضف صورًا (وإحداثيات/هاتف إن فُعّلت)')
                  : (enabled ? 'Ready to publish' : 'Complete fields + images (and coords/phone if enabled)'),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: enabled ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: enabled ? onSubmit : null,
            icon: saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.publish_outlined),
            label: Text(isAr ? 'نشر الإعلان' : 'Publish'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
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
        color: cs.errorContainer.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cs.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
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

class _PickedImage {
  final String name;
  final Uint8List bytes;
  const _PickedImage({required this.name, required this.bytes});
}

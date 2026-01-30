// lib/screens/map_picker_page.dart
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapPickerPage extends StatefulWidget {
  /// ✅ اختياري: تمرير نقطة بداية (لو عندك إحداثيات سابقة)
  final LatLng? initial;

  /// ✅ اختياري: لغة الصفحة
  final bool isAr;

  const MapPickerPage({
    super.key,
    this.initial,
    this.isAr = true,
  });

  @override
  State<MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<MapPickerPage> {
  late LatLng _selected;
  Marker? _marker;
  GoogleMapController? _ctrl;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial ?? const LatLng(24.7136, 46.6753); // الرياض افتراضي
    _marker = Marker(markerId: const MarkerId('picked'), position: _selected);
  }

  void _onTap(LatLng pos) {
    setState(() {
      _selected = pos;
      _marker = Marker(markerId: const MarkerId('picked'), position: pos);
    });
  }

  void _confirm() {
    Navigator.pop(context, {
      'lat': _selected.latitude,
      'lng': _selected.longitude,
    });
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'تحديد الموقع من الخريطة' : 'Pick location on map'),
          actions: [
            IconButton(
              tooltip: isAr ? 'اعتماد' : 'Confirm',
              icon: const Icon(Icons.check),
              onPressed: _confirm,
            ),
          ],
        ),
        body: Stack(
          children: [
            GoogleMap(
              initialCameraPosition: CameraPosition(target: _selected, zoom: 13),
              onMapCreated: (c) => _ctrl = c,
              onTap: _onTap,
              markers: _marker != null ? {_marker!} : {},
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
              compassEnabled: true,
              zoomControlsEnabled: true,
            ),

            // ✅ شريط معلومات بسيط + زر اعتماد أسفل
            Positioned(
              bottom: 14,
              left: 14,
              right: 14,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Theme.of(context).colorScheme.surface.withOpacity(0.92),
                        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6)),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 18,
                            offset: const Offset(0, 10),
                            color: Theme.of(context).colorScheme.shadow.withOpacity(0.15),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.place_outlined),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isAr
                                  ? 'Lat: ${_selected.latitude.toStringAsFixed(6)}  |  Lng: ${_selected.longitude.toStringAsFixed(6)}'
                                  : 'Lat: ${_selected.latitude.toStringAsFixed(6)}  |  Lng: ${_selected.longitude.toStringAsFixed(6)}',
                              style: const TextStyle(fontWeight: FontWeight.w800),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check),
                        label: Text(isAr ? 'اعتماد الموقع' : 'Confirm location'),
                        onPressed: _confirm,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

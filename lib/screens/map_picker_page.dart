import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapPickerPage extends StatefulWidget {
  const MapPickerPage({super.key});

  @override
  State<MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<MapPickerPage> {
  LatLng _selected = const LatLng(24.7136, 46.6753); // الرياض افتراضي
  Marker? _marker;

  @override
  void initState() {
    super.initState();
    _marker = Marker(
      markerId: const MarkerId('picked'),
      position: _selected,
    );
  }

  void _onTap(LatLng pos) {
    setState(() {
      _selected = pos;
      _marker = Marker(
        markerId: const MarkerId('picked'),
        position: pos,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تحديد الموقع من الخريطة'),
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _selected,
              zoom: 13,
            ),
            onTap: _onTap,
            markers: _marker != null ? {_marker!} : {},
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
          ),
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('اعتماد الموقع'),
              onPressed: () {
                Navigator.pop(context, {
                  'lat': _selected.latitude,
                  'lng': _selected.longitude,
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}

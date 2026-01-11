import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';

class SettingsPage extends StatefulWidget {
  final String lang;
  const SettingsPage({super.key, required this.lang});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _lang;
  late ThemeMode _mode;

  @override
  void initState() {
    super.initState();
    _lang = widget.lang;
    _mode = themeModeNotifier.value;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('language', _lang);
    await prefs.setString('themeMode', _mode.name);

    if (!mounted) return; // ✅ fix: لا تستخدم context بعد await

    themeModeNotifier.value = _mode;
    Navigator.pop(context, {'lang': _lang});
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _lang == 'ar';
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'الإعدادات' : 'Settings'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              isAr ? 'اللغة' : 'Language',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ar', label: Text('العربية')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {_lang},
              onSelectionChanged: (s) => setState(() => _lang = s.first),
            ),
            const SizedBox(height: 32),
            Text(
              isAr ? 'الثيم' : 'Theme',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(isAr ? 'حفظ والرجوع' : 'Save & Back'),
            ),
          ],
        ),
      ),
    );
  }
}

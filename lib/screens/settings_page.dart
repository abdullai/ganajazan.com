// lib/screens/settings_page.dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../services/fast_login_service.dart';

class SettingsPage extends StatefulWidget {
  final String lang;
  const SettingsPage({super.key, required this.lang});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _lang;
  late ThemeMode _mode;

  bool _pinEnabled = false;
  bool _bioEnabled = false;
  bool _busy = false;

  bool get _isAr => _lang == 'ar';
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _lang = widget.lang;
    _mode = themeModeNotifier.value;
    _loadFastLogin();
  }

  Future<void> _loadFastLogin() async {
    final pin = await FastLoginService.isPinEnabled();
    final bio = await FastLoginService.isBiometricEnabled();
    if (!mounted) return;
    setState(() {
      _pinEnabled = pin;
      _bioEnabled = bio;
    });
  }

  Future<void> _saveBase() async {
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('language', _lang);
      await prefs.setString('themeMode', _mode.name);

      if (!mounted) return;

      themeModeNotifier.value = _mode;

      // ✅ avoid red screen: pop safely after frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.pop(context, {'lang': _lang});
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'فشل حفظ الإعدادات' : 'Failed to save settings'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ✅ 6 digits + confirm 6 digits, RTL writing for ALL languages
  Future<void> _setPinFlow({required bool isChange}) async {
    if (!_isMobile) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'ميزة PIN متاحة على الجوال فقط' : 'PIN is available on mobile only'),
        ),
      );
      return;
    }

    final pinCtrl = TextEditingController();
    final pinCtrl2 = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return Directionality(
          textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            title: Text(
              _isAr
                  ? (isChange ? 'تغيير PIN' : 'إنشاء PIN')
                  : (isChange ? 'Change PIN' : 'Create PIN'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Directionality(
                  textDirection: TextDirection.rtl, // ✅ always RTL typing
                  child: TextField(
                    controller: pinCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: _isAr ? 'PIN (6 أرقام)' : 'PIN (6 digits)',
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Directionality(
                  textDirection: TextDirection.rtl, // ✅ always RTL typing
                  child: TextField(
                    controller: pinCtrl2,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: _isAr ? 'تأكيد PIN' : 'Confirm PIN',
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(_isAr ? 'إلغاء' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final a = FastLoginService.normalizeDigits(pinCtrl.text);
                  final b = FastLoginService.normalizeDigits(pinCtrl2.text);
                  if (a.length != 6 || b.length != 6 || a != b) {
                    // ✅ use dialog context to show error safely
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(_isAr ? 'تأكد من PIN (6 أرقام) والتطابق' : 'Ensure 6-digit PIN and match'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(_isAr ? 'حفظ' : 'Save'),
              ),
            ],
          ),
        );
      },
    );

    if (ok != true) {
      pinCtrl.dispose();
      pinCtrl2.dispose();
      return;
    }

    final pin = FastLoginService.normalizeDigits(pinCtrl.text);
    pinCtrl.dispose();
    pinCtrl2.dispose();

    setState(() => _busy = true);
    try {
      await FastLoginService.setPin(pin);
      await FastLoginService.setPinEnabled(true); // ✅ ensure enabled
      if (!mounted) return;
      setState(() => _pinEnabled = true);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'تم حفظ PIN' : 'PIN saved'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'فشل حفظ PIN' : 'Failed to save PIN'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleBio(bool v) async {
    if (!_isMobile) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'ميزة البصمة/الوجه متاحة على الجوال فقط' : 'Biometrics are available on mobile only'),
        ),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      if (v) {
        final can = await FastLoginService.canCheckBiometrics();
        if (!can) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(_isAr ? 'البصمة/الوجه غير مدعوم على هذا الجهاز' : 'Biometrics not supported on this device'),
            ),
          );
          return;
        }

        final ok = await FastLoginService.authenticateBiometric(isAr: _isAr);
        if (!ok) return;

        await FastLoginService.setBiometricEnabled(true);
        if (!mounted) return;
        setState(() => _bioEnabled = true);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isAr ? 'تم تفعيل البصمة/الوجه' : 'Biometrics enabled'),
          ),
        );
      } else {
        await FastLoginService.setBiometricEnabled(false);
        if (!mounted) return;
        setState(() => _bioEnabled = false);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isAr ? 'تم إيقاف البصمة/الوجه' : 'Biometrics disabled'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'حدث خطأ أثناء حفظ البصمة' : 'Error while saving biometrics'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePin(bool v) async {
    if (!_isMobile) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'ميزة PIN متاحة على الجوال فقط' : 'PIN is available on mobile only'),
        ),
      );
      return;
    }

    if (v) {
      await _setPinFlow(isChange: false);
    } else {
      setState(() => _busy = true);
      try {
        await FastLoginService.setPinEnabled(false);
        if (!mounted) return;
        setState(() {
          _pinEnabled = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isAr ? 'تم إيقاف PIN' : 'PIN disabled'),
          ),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(_isAr ? 'فشل إيقاف PIN' : 'Failed to disable PIN'),
          ),
        );
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _disableAllFastLogin() async {
    setState(() => _busy = true);
    try {
      await FastLoginService.clearAll();
      if (!mounted) return;
      setState(() {
        _pinEnabled = false;
        _bioEnabled = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'تم إيقاف الدخول السريع' : 'Quick Login disabled'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'فشل إيقاف الدخول السريع' : 'Failed to disable Quick Login'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobileOnlyNote = !_isMobile;

    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isAr ? 'الإعدادات' : 'Settings'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_isAr ? 'اللغة' : 'Language',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ar', label: Text('العربية')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {_lang},
              onSelectionChanged: _busy ? null : (s) => setState(() => _lang = s.first),
            ),
            const SizedBox(height: 28),

            Text(_isAr ? 'الثيم' : 'Theme',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ],
              selected: {_mode},
              onSelectionChanged: _busy ? null : (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 28),

            Text(_isAr ? 'الدخول السريع (قفل التطبيق)' : 'Quick Login (App Lock)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),

            if (mobileOnlyNote)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Text(
                  _isAr
                      ? 'ميزة الدخول السريع (PIN/البصمة) متاحة على الجوالات والأجهزة الذكية فقط.'
                      : 'Quick Login (PIN/Biometrics) is available on mobile devices only.',
                ),
              ),

            const SizedBox(height: 8),

            SwitchListTile(
              value: _bioEnabled,
              onChanged: (_busy || !_isMobile) ? null : _toggleBio,
              title: Text(_isAr ? 'تفعيل بصمة/FaceID' : 'Enable Biometrics'),
              subtitle: Text(_isAr ? 'يتطلب دعم الجهاز وإذن البصمة' : 'Requires device support and permission'),
            ),
            SwitchListTile(
              value: _pinEnabled,
              onChanged: (_busy || !_isMobile) ? null : _togglePin,
              title: Text(_isAr ? 'تفعيل PIN (6 أرقام)' : 'Enable PIN (6 digits)'),
              subtitle: Text(_isAr ? 'مفيد للأجهزة بدون بصمة' : 'Useful if no biometrics'),
            ),
            if (_pinEnabled)
              ListTile(
                leading: const Icon(Icons.password),
                title: Text(_isAr ? 'تغيير PIN' : 'Change PIN'),
                onTap: (_busy || !_isMobile) ? null : () => _setPinFlow(isChange: true),
              ),

            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: (_busy || !_isMobile) ? null : _disableAllFastLogin,
              icon: const Icon(Icons.lock_reset),
              label: Text(_isAr ? 'إيقاف الدخول السريع نهائياً' : 'Disable Quick Login'),
            ),

            const SizedBox(height: 28),

            FilledButton.icon(
              onPressed: _busy ? null : _saveBase,
              icon: const Icon(Icons.save),
              label: Text(_isAr ? 'حفظ والرجوع' : 'Save & Back'),
            ),
          ],
        ),
      ),
    );
  }
}

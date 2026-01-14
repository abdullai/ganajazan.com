// lib/screens/login_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aqar_user/main.dart'; // themeModeNotifier + langNotifier
import 'package:aqar_user/models.dart'; // AdItem
import 'package:aqar_user/services/auth_service.dart';
import 'package:aqar_user/services/ads_service.dart';

// ✅ L10n
import 'package:aqar_user/l10n/app_localizations.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  static const Color _bankColor = Color(0xFF0F766E);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool rememberMe = false;
  bool fastLogin = false;
  bool obscurePassword = true;
  bool isBusy = false;

  // ✅ CAPTCHA
  bool showCaptcha = false;
  String captchaText = '';
  String userCaptchaInput = '';

  bool loginError = false;
  String loginErrorText = '';

  // Ads
  final PageController _adsController = PageController();
  int _adsIndex = 0;
  List<AdItem> _ads = [];

  // Remember-me masking
  String? _storedUsername; // ✅ هنا نخزن "الهوية/الإقامة" الحقيقية 10 أرقام
  bool _maskedPrefillActive = false;
  bool _usernameEdited = false;

  // brute-force
  Map<String, int> _failedAttempts = {};
  Map<String, DateTime> _lockoutUntil = {};

  // ✅ DB checks for ✅ icons
  Timer? _userCheckDebounce;
  Timer? _credCheckDebounce;
  bool _checkingUsername = false;
  bool _usernameExists = false;
  bool _checkingCreds = false;
  bool _passwordMatches = false;

  // Animation (خفيف)
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulse;

  bool get _isAr => langNotifier.value != 'en';

  ThemeMode get _currentTheme => themeModeNotifier.value;
  bool get _isLight => _currentTheme == ThemeMode.light;

  Color get _pageBg =>
      _isLight ? const Color(0xFFF5F7FA) : const Color(0xFF0E0F13);
  Color get _textPrimary =>
      _isLight ? const Color(0xFF0B1220) : Colors.white;
  Color get _textSecondary =>
      _isLight ? const Color(0xFF5B6475) : const Color(0xFFB8C0D4);

  Color get _fieldFill =>
      _isLight ? Colors.white : const Color(0xFF0F1425);
  Color get _fieldBorder =>
      _isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A);

  Color get _hintColor =>
      _isLight ? const Color(0xFF64748B) : const Color(0xFFCBD5E1);
  Color get _iconColor =>
      _isLight ? const Color(0xFF64748B) : const Color(0xFFCBD5E1);

  Color get _errorColor => const Color(0xFFDC2626);
  Color get _successColor => const Color(0xFF059669);

  @override
  void initState() {
    super.initState();

    // ✅ إذا فيه Session جاهز (تجربة سابقة) روح للداشبورد مباشرة
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (!mounted) return;
      if (uid != null) {
        Navigator.pushReplacementNamed(context, '/userDashboard');
      }
    });

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );
    _pulse = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _pulseCtrl.repeat(reverse: true);

    _generateCaptcha();
    _loadPreferences();
    _loadAds();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _usernameFocus.requestFocus();
    });

    _usernameController.addListener(() {
      if (_maskedPrefillActive && !_usernameEdited) return;

      final normalized = _normalizeNumbers(_usernameController.text);
      if (_usernameController.text != normalized) {
        _usernameController.text = normalized;
        _usernameController.selection =
            TextSelection.collapsed(offset: normalized.length);
      }

      _checkUsernameExistsDebounced();
      _checkCredentialsDebounced();

      setState(() {});
    });

    _passwordController.addListener(() {
      _checkCredentialsDebounced();
      setState(() {});
    });

    _usernameFocus.addListener(() {
      if (_usernameFocus.hasFocus && _maskedPrefillActive && !_usernameEdited) {
        _usernameEdited = true;
        _usernameController.clear();
        _resetDbFlags();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _userCheckDebounce?.cancel();
    _credCheckDebounce?.cancel();

    _pulseCtrl.dispose();
    _adsController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _resetDbFlags() {
    _checkingUsername = false;
    _usernameExists = false;
    _checkingCreds = false;
    _passwordMatches = false;
  }

  bool _looksLikeUsername10Digits(String s) => RegExp(r'^\d{10}$').hasMatch(s);

  Future<void> _checkUsernameExistsDebounced() async {
    _userCheckDebounce?.cancel();

    final u = (_getRealUsername() ?? '').trim();
    if (!_looksLikeUsername10Digits(u)) {
      if (!mounted) return;
      setState(() {
        _checkingUsername = false;
        _usernameExists = false;
      });
      return;
    }

    _userCheckDebounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted) return;
      setState(() => _checkingUsername = true);

      final exists = await AuthService.usernameExists(u);

      if (!mounted) return;
      setState(() {
        _usernameExists = exists;
        _checkingUsername = false;
      });
    });
  }

  Future<void> _checkCredentialsDebounced() async {
    _credCheckDebounce?.cancel();

    final u = (_getRealUsername() ?? '').trim();
    final p = _passwordController.text.trim();

    if (!_looksLikeUsername10Digits(u) || p.isEmpty) {
      if (!mounted) return;
      setState(() {
        _checkingCreds = false;
        _passwordMatches = false;
      });
      return;
    }

    _credCheckDebounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted) return;
      setState(() => _checkingCreds = true);

      // ✅ (واجهة فقط) إذا password النصي غير موجود في DB ممكن ترجع false دائماً
      final ok = await AuthService.credentialsMatch(username: u, password: p);

      if (!mounted) return;
      setState(() {
        _passwordMatches = ok;
        _checkingCreds = false;
      });
    });
  }

  Future<void> _loadAds() async {
    final loaded = await AdsService.loadAds();
    if (!mounted) return;
    setState(() {
      _ads = loaded.where((a) => a.enabled).toList();
      if (_adsIndex >= _ads.length) _adsIndex = 0;
    });
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    rememberMe = prefs.getBool('rememberMe') ?? false;
    fastLogin = prefs.getBool('fastLogin') ?? false;

    // ✅ language + theme
    final savedLang = prefs.getString('language') ?? langNotifier.value;
    langNotifier.value = (savedLang == 'en') ? 'en' : 'ar';

    final savedTheme = prefs.getString('themeMode') ?? ThemeMode.system.name;
    themeModeNotifier.value = ThemeMode.values.firstWhere(
      (e) => e.name == savedTheme,
      orElse: () => ThemeMode.system,
    );

    // ✅ brute-force stored
    final attemptsJson = prefs.getString('failedAttempts') ?? '{}';
    final lockoutJson = prefs.getString('lockoutUntil') ?? '{}';
    try {
      _failedAttempts = Map<String, int>.from(json.decode(attemptsJson));
      final lockoutMap = Map<String, dynamic>.from(json.decode(lockoutJson));
      _lockoutUntil = lockoutMap.map((k, v) => MapEntry(k, DateTime.parse(v)));
    } catch (_) {
      _failedAttempts = {};
      _lockoutUntil = {};
    }

    // ✅ remember username masked
    if (rememberMe) {
      final u = (prefs.getString('username') ?? '').trim();
      _storedUsername = u.isEmpty ? null : u;
      if ((_storedUsername ?? '').isNotEmpty) _applyMaskedUsernamePrefill();
    }

    // ✅ never keep password
    if (prefs.containsKey('password')) {
      await prefs.remove('password');
    }

    if (!mounted) return;
    setState(() {});

    _checkUsernameExistsDebounced();
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('rememberMe', rememberMe);
    await prefs.setBool('fastLogin', fastLogin);

    await prefs.setString('failedAttempts', json.encode(_failedAttempts));
    final lockoutJson =
        _lockoutUntil.map((k, v) => MapEntry(k, v.toIso8601String()));
    await prefs.setString('lockoutUntil', json.encode(lockoutJson));

    if (!rememberMe) {
      await prefs.remove('username');
      if (prefs.containsKey('password')) await prefs.remove('password');
      return;
    }

    // ✅ احفظ الهوية/الإقامة الحقيقية (10 أرقام)
    final real = (_getRealUsername() ?? '').trim();
    if (_looksLikeUsername10Digits(real)) {
      await prefs.setString('username', real);
      _storedUsername = real;
    }

    if (prefs.containsKey('password')) await prefs.remove('password');
  }

  Future<void> _setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    langNotifier.value = (code == 'en') ? 'en' : 'ar';
    await prefs.setString('language', langNotifier.value);

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _setTheme(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    themeModeNotifier.value = mode;
    await prefs.setString('themeMode', mode.name);
    if (!mounted) return;
    setState(() {});
  }

  // ===== Mask helpers =====
  String _maskNationalIdLast4(String s) {
    final v = s.trim();
    if (v.isEmpty) return '';
    if (v.length <= 4) return '*' * v.length;
    final last4 = v.substring(v.length - 4);
    final stars = '*' * (v.length - 4);
    return '$stars$last4';
  }

  void _applyMaskedUsernamePrefill() {
    final u = _storedUsername ?? '';
    _maskedPrefillActive = true;
    _usernameEdited = false;

    if (u.isNotEmpty) {
      _usernameController.text = _maskNationalIdLast4(u);
      _usernameController.selection =
          TextSelection.collapsed(offset: _usernameController.text.length);
    }
  }

  String? _getRealUsername() {
    if (_maskedPrefillActive && !_usernameEdited) {
      return _storedUsername?.trim();
    }
    return _usernameController.text.trim();
  }

  String _normalizeNumbers(String input) => AuthService.normalizeNumbers(input);

  void _generateCaptcha() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = math.Random();
    captchaText = String.fromCharCodes(
      List.generate(6, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
    userCaptchaInput = '';
  }

  Future<String> _getDeviceFingerprint() async {
    final deviceInfo = DeviceInfoPlugin();
    String fingerprint = '';

    try {
      final p = Theme.of(context).platform;
      if (p == TargetPlatform.android) {
        final androidInfo = await deviceInfo.androidInfo;
        fingerprint = '${androidInfo.model}_${androidInfo.id}';
      } else if (p == TargetPlatform.iOS) {
        final iosInfo = await deviceInfo.iosInfo;
        fingerprint = '${iosInfo.model}_${iosInfo.identifierForVendor}';
      } else {
        fingerprint = 'unknown_platform';
      }
    } catch (_) {
      fingerprint = 'unknown_device';
    }

    final bytes = utf8.encode(fingerprint);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  Future<bool> _isAccountLocked(String username) async {
    final now = DateTime.now();
    final lockoutTime = _lockoutUntil[username];

    if (lockoutTime != null && now.isBefore(lockoutTime)) {
      final minutesLeft = lockoutTime.difference(now).inMinutes;
      final secondsLeft = lockoutTime.difference(now).inSeconds % 60;

      setState(() {
        loginError = true;
        loginErrorText = _isAr
            ? 'الحساب مؤقتاً مغلق. حاول بعد $minutesLeft دقيقة و $secondsLeft ثانية'
            : 'Account temporarily locked. Try again in $minutesLeft minutes $secondsLeft seconds';
      });
      return true;
    }
    return false;
  }

  Future<void> _updateFailedAttempts(String username) async {
    final attempts = (_failedAttempts[username] ?? 0) + 1;
    _failedAttempts[username] = attempts;

    if (attempts >= 3) {
      _lockoutUntil[username] = DateTime.now().add(const Duration(minutes: 5));
      setState(() {
        showCaptcha = true;
        _generateCaptcha();
      });
    }
    await _savePreferences();
  }

  Future<void> _resetFailedAttempts(String username) async {
    _failedAttempts.remove(username);
    _lockoutUntil.remove(username);
    await _savePreferences();
  }

  Future<void> _logLoginAttempt(
      String username, bool success, String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toIso8601String();

    final logEntry = {
      'timestamp': now,
      'username': username.length >= 3 ? (username.substring(0, 3) + '*****') : '***',
      'success': success,
      'deviceId': deviceId,
      'ip': 'detected',
    };

    final logsJson = prefs.getString('loginLogs') ?? '[]';
    final decoded = json.decode(logsJson);
    final List logs = decoded is List ? decoded : [];

    logs.add(logEntry);
    while (logs.length > 100) {
      logs.removeAt(0);
    }
    await prefs.setString('loginLogs', json.encode(logs));
  }

  String _generateDemoCode() {
    final r = math.Random();
    return (1000 + r.nextInt(9000)).toString();
  }

  Future<void> _login() async {
    final t = AppLocalizations.of(context)!;

    final username = (_getRealUsername() ?? '').trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() {
        loginError = true;
        loginErrorText = t.allFieldsRequired;
      });
      return;
    }

    final u = _normalizeNumbers(username).trim();
    if (!_looksLikeUsername10Digits(u)) {
      setState(() {
        loginError = true;
        loginErrorText =
            _isAr ? 'اسم المستخدم يجب أن يكون 10 أرقام' : 'Username must be 10 digits';
      });
      await _updateFailedAttempts(u);
      return;
    }

    if (await _isAccountLocked(u)) return;

    if (showCaptcha) {
      if (userCaptchaInput.trim().toUpperCase() != captchaText) {
        setState(() {
          loginError = true;
          loginErrorText = _isAr ? 'رمز التحقق غير صحيح' : 'Incorrect CAPTCHA code';
          _generateCaptcha();
        });
        await _updateFailedAttempts(u);
        return;
      }
    }

    setState(() {
      isBusy = true;
      loginError = false;
      loginErrorText = '';
    });

    await Future.delayed(const Duration(milliseconds: 180));

    final lang = langNotifier.value == 'en' ? 'en' : 'ar';
    final deviceFingerprint = await _getDeviceFingerprint();

    // ✅ هذا أهم سطر: AuthService.login الآن ينشئ Session حقيقي عبر signInWithPassword
    final result = await AuthService.login(
      username: u,
      password: password,
      lang: lang,
    );

    if (!mounted) return;
    setState(() => isBusy = false);

    if (!result.ok) {
      await _updateFailedAttempts(u);
      setState(() {
        loginError = true;
        loginErrorText = result.message;
      });

      if (result.locked) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(t.accountLockedTitle,
                style: const TextStyle(fontWeight: FontWeight.w900)),
            content: Text(t.accountLockedBody,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/forgot');
                },
                child: Text(t.recover,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
              )
            ],
          ),
        );
      }
      return;
    }

    // ✅ تحقق: Session فعلاً صار موجود
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      setState(() {
        loginError = true;
        loginErrorText = _isAr
            ? 'تم التحقق لكن لم يتم إنشاء جلسة دخول (Session). تأكد أن المستخدم موجود في Supabase Auth وكلمة المرور مطابقة.'
            : 'Verified but no session created. Ensure user exists in Supabase Auth and password matches.';
      });
      return;
    }

    await _resetFailedAttempts(u);

    if (rememberMe) {
      _storedUsername = u;
      await _savePreferences();
    }

    TextInput.finishAutofillContext(shouldSave: true);
    await _logLoginAttempt(u, true, deviceFingerprint);

    // ✅ إذا تبغى تتجاوز صفحة verify عندك في الويب/التطوير:
    // انت الآن تقدر لأن الجلسة موجودة
    if (!mounted) return;

    if (fastLogin) {
      Navigator.pushReplacementNamed(context, '/userDashboard');
      return;
    }

    final next = '/userDashboard';
    final code = _generateDemoCode();

    Navigator.pushReplacementNamed(
      context,
      '/verify',
      arguments: {
        'next': next,
        'code': code,
        'username': u,
        'deviceId': deviceFingerprint,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;

    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: themeModeNotifier,
        builder: (context, _, __) {
          return Scaffold(
            backgroundColor: _pageBg,
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  final h = c.maxHeight;

                  final allowVerticalScroll = h < 760;
                  final showAdsSide = w >= 980;

                  if (showAdsSide) {
                    final adsW = (w * 0.52).clamp(520.0, 860.0);
                    final loginW = (w - adsW).clamp(440.0, 640.0);

                    return Row(
                      children: [
                        SizedBox(
                          width: loginW,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(22),
                              child: _loginCard(
                                maxWidth: 600,
                                borderRadius: 20,
                                t: t,
                                allowVerticalScroll: allowVerticalScroll,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: adsW, child: _adsPanelRight(t: t)),
                      ],
                    );
                  }

                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: _loginCard(
                          maxWidth: 600,
                          borderRadius: 18,
                          t: t,
                          allowVerticalScroll: allowVerticalScroll,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _loginCard({
    required double maxWidth,
    required double borderRadius,
    required AppLocalizations t,
    required bool allowVerticalScroll,
  }) {
    final cardColor = _isLight
        ? Colors.white.withOpacity(0.95)
        : const Color(0xFF171A22).withOpacity(0.95);

    final pValid = _passwordMatches;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _topBarOldStyle(t: t),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_user, size: 16, color: _successColor),
            const SizedBox(width: 6),
            Text(
              _isAr ? 'تسجيل دخول آمن' : 'Secure Login',
              style: TextStyle(
                fontSize: 12,
                color: _successColor,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ScaleTransition(
          scale: _pulse,
          child: Image.asset(
            'assets/logo.png',
            height: 160,
            width: 160,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.apartment_rounded, size: 96, color: _textPrimary),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          t.welcomeTrustedAqar,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: _textPrimary,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          t.signInToContinue,
          style: TextStyle(
            fontSize: 14,
            color: _textSecondary,
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        AutofillGroup(
          child: Column(
            children: [
              _buildUsernameField(t: t),
              const SizedBox(height: 10),
              _buildPasswordField(t: t, valid: pValid),
            ],
          ),
        ),
        if (showCaptcha) ...[
          const SizedBox(height: 16),
          _buildCaptchaSection(t: t),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Checkbox(
              value: rememberMe,
              onChanged: (v) async {
                final newVal = v ?? false;
                setState(() => rememberMe = newVal);

                if (!newVal) {
                  _maskedPrefillActive = false;
                  _storedUsername = null;
                  _usernameEdited = false;
                  _usernameController.clear();
                  _resetDbFlags();
                  await _savePreferences();
                  return;
                }

                final curU = (_getRealUsername() ?? '').trim();
                _storedUsername = curU.isEmpty ? null : curU;

                if ((_storedUsername ?? '').isNotEmpty) {
                  _applyMaskedUsernamePrefill();
                }
                await _savePreferences();

                _checkUsernameExistsDebounced();
              },
            ),
            Expanded(
              child: Text(
                t.rememberMe,
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Checkbox(
              value: fastLogin,
              onChanged: (v) async {
                setState(() => fastLogin = v ?? false);
                await _savePreferences();
              },
            ),
            Text(
              t.quickLogin,
              style: TextStyle(
                color: _textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => Navigator.pushNamed(context, '/resetPassword'),
            child: Text(
              t.forgotUsernameOrPassword,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: loginError
              ? Padding(
                  key: const ValueKey('err'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _errorColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _errorColor.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: _errorColor, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            loginErrorText.isEmpty
                                ? t.invalidCredentials
                                : loginErrorText,
                            style: TextStyle(
                              color: _errorColor,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('noerr')),
        ),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _bankColor,
              foregroundColor: Colors.white,
              elevation: 3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: isBusy ? null : _login,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: isBusy
                  ? Row(
                      key: const ValueKey('loading'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _isAr ? 'جارٍ الدخول...' : 'Signing in...',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ],
                    )
                  : Text(
                      t.userSignIn,
                      key: const ValueKey('text'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            try {
              Navigator.pushNamed(context, '/register');
            } catch (_) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_isAr
                      ? 'صفحة إنشاء حساب غير مفعّلة حالياً'
                      : 'Register screen is not enabled yet'),
                ),
              );
            }
          },
          child: Text(
            _isAr ? 'إنشاء حساب جديد' : 'Create new account',
            style: TextStyle(fontWeight: FontWeight.w900, color: _bankColor),
          ),
        ),
      ],
    );

    final child = Padding(
      padding: const EdgeInsets.all(18),
      child: allowVerticalScroll
          ? SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: content,
            )
          : content,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Card(
        elevation: 10,
        shadowColor: Colors.black.withOpacity(0.18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(borderRadius)),
        color: cardColor,
        child: child,
      ),
    );
  }

  Widget _topBarOldStyle({required AppLocalizations t}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            _themeIcon(
              icon: Icons.light_mode,
              selected: _currentTheme == ThemeMode.light,
              tooltip: t.themeLight,
              onTap: () => _setTheme(ThemeMode.light),
            ),
            _themeIcon(
              icon: Icons.dark_mode,
              selected: _currentTheme == ThemeMode.dark,
              tooltip: t.themeDark,
              onTap: () => _setTheme(ThemeMode.dark),
            ),
            _themeIcon(
              icon: Icons.brightness_auto,
              selected: _currentTheme == ThemeMode.system,
              tooltip: t.themeSystem,
              onTap: () => _setTheme(ThemeMode.system),
            ),
          ],
        ),
        Row(
          children: [
            _langButtonStyled(t.languageEnglish, 'en'),
            const SizedBox(width: 8),
            _langButtonStyled(t.languageArabic, 'ar'),
          ],
        ),
      ],
    );
  }

  Widget _themeIcon({
    required IconData icon,
    required bool selected,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, color: selected ? Colors.white : _iconColor),
      style: IconButton.styleFrom(
        backgroundColor: selected ? _bankColor : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Widget _langButtonStyled(String title, String code) {
    final selected = langNotifier.value == code;
    final bg = selected
        ? _bankColor
        : (_isLight ? Colors.grey.shade200 : const Color(0xFF1F2937));
    final fg = selected ? Colors.white : _textPrimary;

    return SizedBox(
      height: 36,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          elevation: selected ? 2 : 0,
          padding: const EdgeInsetsDirectional.fromSTEB(14, 0, 14, 0),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: () => _setLanguage(code),
        child: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildUsernameField({required AppLocalizations t}) {
    final raw = _usernameController.text.trim();
    final normalized = _normalizeNumbers(raw).trim();
    final is10 = _looksLikeUsername10Digits(normalized);

    Widget? suffix;
    if (_checkingUsername) {
      suffix = const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (_usernameExists) {
      suffix = SizedBox(
        width: 44,
        height: 44,
        child: Center(child: Icon(Icons.verified_rounded, color: _successColor)),
      );
    } else if (is10 && raw.isNotEmpty) {
      suffix = SizedBox(
        width: 44,
        height: 44,
        child: Center(child: Icon(Icons.error_outline, color: _errorColor)),
      );
    } else {
      suffix = null;
    }

    return TextField(
      controller: _usernameController,
      focusNode: _usernameFocus,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      maxLength: 10,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _passwordFocus.requestFocus(),
      autofillHints: const [AutofillHints.username],
      style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w900),
      decoration: InputDecoration(
        hintText: _isAr ? 'رقم الهوية/الإقامة (10 أرقام)' : 'Saudi ID/Iqama (10 digits)',
        hintStyle: TextStyle(color: _hintColor, fontWeight: FontWeight.w800),
        counterText: '',
        prefixIcon: Icon(Icons.badge_outlined, color: _iconColor),
        suffixIcon: suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _bankColor, width: 1.6),
        ),
        fillColor: _fieldFill,
        filled: true,
      ),
      onTap: () {
        if (_maskedPrefillActive && !_usernameEdited) {
          _usernameEdited = true;
          _usernameController.clear();
          _resetDbFlags();
          setState(() {});
        }
      },
    );
  }

  Widget _buildPasswordField({required AppLocalizations t, required bool valid}) {
    final showErrorIcon =
        _passwordController.text.isNotEmpty && !valid && !_checkingCreds;

    final statusWidget = _checkingCreds
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : (valid
            ? Icon(Icons.verified_rounded, color: _successColor)
            : (showErrorIcon
                ? Icon(Icons.error_outline, color: _errorColor)
                : const SizedBox.shrink()));

    return TextField(
      controller: _passwordController,
      focusNode: _passwordFocus,
      obscureText: obscurePassword,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _login(),
      autofillHints: const [AutofillHints.password],
      enableSuggestions: false,
      autocorrect: false,
      style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w900),
      decoration: InputDecoration(
        hintText: t.passwordHint,
        hintStyle: TextStyle(color: _hintColor, fontWeight: FontWeight.w800),
        prefixIcon: Icon(Icons.lock_outline, color: _iconColor),
        suffixIcon: SizedBox(
          width: 120,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  icon: Icon(
                    obscurePassword ? Icons.visibility : Icons.visibility_off,
                    color: _iconColor,
                  ),
                  onPressed: () => setState(() => obscurePassword = !obscurePassword),
                  tooltip: obscurePassword ? (_isAr ? 'إظهار' : 'Show') : (_isAr ? 'إخفاء' : 'Hide'),
                ),
              ),
              SizedBox(width: 44, height: 44, child: Center(child: statusWidget)),
            ],
          ),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _fieldBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _bankColor, width: 1.6),
        ),
        fillColor: _fieldFill,
        filled: true,
      ),
    );
  }

  Widget _buildCaptchaSection({required AppLocalizations t}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isLight ? const Color(0xFFFEF3C7) : const Color(0xFF78350F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isLight ? const Color(0xFFF59E0B) : const Color(0xFFD97706),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.security_rounded,
                  color: _isLight ? const Color(0xFF92400E) : Colors.white),
              const SizedBox(width: 8),
              Text(
                _isAr ? 'التحقق من الأمان' : 'Security Verification',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _isLight ? const Color(0xFF92400E) : Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _isAr
                ? 'لإثبات أنك لست روبوتاً، الرجاء إدخال الأحرف التالية:'
                : 'To prove you\'re not a robot, please enter the characters below:',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: _isLight ? const Color(0xFF92400E) : const Color(0xFFFDE68A),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            decoration: BoxDecoration(
              color: _isLight ? Colors.white : const Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _fieldBorder),
            ),
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                for (int i = 0; i < captchaText.length; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _isLight ? const Color(0xFFF3F4F6) : const Color(0xFF374151),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      captchaText[i],
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _textPrimary,
                        fontFamily: 'Courier',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (value) => setState(() => userCaptchaInput = value),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: _textPrimary,
              fontFamily: 'Courier',
            ),
            decoration: InputDecoration(
              hintText: _isAr ? 'أدخل الأحرف أعلاه' : 'Enter characters above',
              hintStyle: TextStyle(color: _hintColor, fontWeight: FontWeight.w800),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () => setState(_generateCaptcha),
                icon: Icon(Icons.refresh, size: 16, color: _iconColor),
                label: Text(
                  _isAr ? 'تحديث الرمز' : 'Refresh',
                  style: TextStyle(color: _iconColor, fontWeight: FontWeight.w900),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => showCaptcha = false),
                icon: Icon(Icons.close, size: 16, color: _errorColor),
                label: Text(
                  _isAr ? 'تخطي' : 'Skip',
                  style: TextStyle(color: _errorColor, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ========= Right Ads Panel =========
  Widget _adsPanelRight({required AppLocalizations t}) {
    final bg1 = _isLight ? const Color(0xFFF2F6FF) : const Color(0xFF0B1020);
    final bg2 = _isLight ? const Color(0xFFEAF0FF) : const Color(0xFF111936);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bg1, bg2],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -120,
            top: -120,
            child: _blurCircle(_isLight ? Colors.blue : Colors.blueAccent),
          ),
          Positioned(
            left: -140,
            bottom: -140,
            child: _blurCircle(_isLight ? Colors.indigo : Colors.indigoAccent),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            t.rightPanelTitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              color: _isLight ? const Color(0xFF0B1220) : Colors.white,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t.rightPanelSubtitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              height: 1.6,
                              color: _isLight ? const Color(0xFF4A5568) : const Color(0xFFCBD5E1),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _dots(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    SizedBox(width: 320, child: _phoneCarousel(t: t)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phoneCarousel({required AppLocalizations t}) {
    if (_ads.isEmpty) {
      return Center(
        child: Text(
          t.noEnabledAds,
          style: TextStyle(
            color: _isLight ? Colors.black54 : Colors.white70,
            fontWeight: FontWeight.w900,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return SizedBox(
      height: 560,
      child: PageView.builder(
        controller: _adsController,
        itemCount: _ads.length,
        onPageChanged: (i) => setState(() => _adsIndex = i),
        itemBuilder: (context, index) {
          final item = _ads[index];
          final title = _isAr ? item.titleAr : item.titleEn;
          final subtitle = _isAr ? item.subtitleAr : item.subtitleEn;

          return _PhoneMockup(
            theme: _currentTheme,
            title: title,
            subtitle: subtitle,
            imageAsset: item.assetImage,
          );
        },
      ),
    );
  }

  Widget _dots() {
    if (_ads.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_ads.length, (i) {
        final active = i == _adsIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 8,
          width: active ? 20 : 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            color: active
                ? _bankColor
                : (_isLight ? const Color(0xFFBFD0FF) : const Color(0xFF2B3A6B)),
          ),
        );
      }),
    );
  }

  Widget _blurCircle(Color color) {
    return Container(
      width: 260,
      height: 260,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.12),
      ),
    );
  }
}

class _PhoneMockup extends StatelessWidget {
  static const Color _bankColor = Color(0xFF0F766E);

  final ThemeMode theme;
  final String title;
  final String subtitle;
  final String imageAsset;

  const _PhoneMockup({
    required this.theme,
    required this.title,
    required this.subtitle,
    required this.imageAsset,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = theme == ThemeMode.light;

    final frame = isLight ? const Color(0xFF111827) : const Color(0xFF0B1220);
    final screen = isLight ? Colors.white : const Color(0xFF0F1425);

    final titleColor = isLight ? const Color(0xFF0B1220) : Colors.white;
    final subColor = isLight ? const Color(0xFF4A5568) : const Color(0xFFCBD5E1);

    return Center(
      child: AspectRatio(
        aspectRatio: 9 / 19.5,
        child: Container(
          decoration: BoxDecoration(
            color: frame,
            borderRadius: BorderRadius.circular(38),
            boxShadow: [
              BoxShadow(
                blurRadius: 30,
                color: Colors.black.withOpacity(0.18),
                offset: const Offset(0, 18),
              ),
            ],
          ),
          padding: const EdgeInsets.all(10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Container(
              color: screen,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 110,
                    height: 16,
                    decoration: BoxDecoration(
                      color: isLight ? const Color(0xFFE5E7EB) : const Color(0xFF1F2A44),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              height: 1.4,
                              color: subColor,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.asset(
                                imageAsset,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, __, ___) => Container(
                                  color: isLight ? const Color(0xFFEFF3FF) : const Color(0xFF101A33),
                                  child: Center(
                                    child: Icon(Icons.image_outlined, size: 36, color: titleColor),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: _bankColor,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                width: 44,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: isLight ? const Color(0xFFE5E7EB) : const Color(0xFF223055),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

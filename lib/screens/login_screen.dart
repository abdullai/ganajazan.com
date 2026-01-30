// lib/screens/login_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  final TextEditingController _usernameController =
      TextEditingController(); // username = national id (10 digits)
  final TextEditingController _passwordController = TextEditingController();

  final FocusNode _usernameFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool rememberMe = false;

  // ✅ ملاحظة: “الدخول السريع” لم يعد Checkbox.
  // صار زر/بلاطة (Tile) يفتح شاشة الدخول السريع.
  // نخزن تفعيل الدخول السريع داخل شاشة الدخول السريع نفسها إن رغبت.
  bool fastLogin = false;

  bool obscurePassword = true;
  bool isBusy = false;

  // ✅ CAPTCHA (محلي فقط، إضافي)
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
  String? _storedUsername; // ✅ username الحقيقي 10 أرقام
  bool _maskedPrefillActive = false;
  bool _usernameEdited = false;

  // brute-force محلي (إضافي)
  Map<String, int> _failedAttempts = {};
  Map<String, DateTime> _lockoutUntil = {};

  // ✅ DB checks for ✅ icons (وجود username)
  Timer? _userCheckDebounce;
  bool _checkingUsername = false;
  bool _usernameExists = false;

  // ✅ show red error icons only after checks
  bool _usernameCheckDone = false;

  // Animation
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

  // ✅ مقياس خطوط للشاشات الصغيرة بدون التفاف (يبقى كما هو على الشاشات الكبيرة)
  bool _isSmallUi(BuildContext context) =>
      MediaQuery.of(context).size.width < 380;

  double _font(BuildContext context, double desktop, double mobile) =>
      _isSmallUi(context) ? mobile : desktop;

  @override
  void initState() {
    super.initState();

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
    _loadAds(); // ✅ مرة واحدة فقط (تم حذف التكرار)

    // ✅ لا تقم بالتنقل تلقائياً من شاشة الدخول عند وجود Session.
    // التوجيه العام يتم عبر GateScreen فقط لتجنب "تنقل مزدوج" يسبب كراش.

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

  // (موجود للاحتياج عندك، حتى لو لم تستخدمه حالياً)
  bool _isRecoveryLinkNow() {
    if (!kIsWeb) return false;
    try {
      final uri = Uri.base;

      final qType = (uri.queryParameters['type'] ?? '').toLowerCase();
      if (qType == 'recovery') return true;

      final frag = uri.fragment;
      if (frag.isNotEmpty) {
        final params = Uri.splitQueryString(frag);
        final fType = (params['type'] ?? '').toLowerCase();
        if (fType == 'recovery') return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _userCheckDebounce?.cancel();

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
    _usernameCheckDone = false;
  }

  bool _looksLikeUsername10Digits(String s) => RegExp(r'^\d{10}$').hasMatch(s);

  /// ✅ فحص وجود username عبر نفس مسار الأمان (RPC get_email_by_national_id خلف AuthService.getEmailByUsername)
  Future<String?> _requestOtpDev(String username) async {
    try {
      final sb = Supabase.instance.client;
      final res =
          await sb.rpc('request_otp_dev', params: {'p_username': username});
      final code = (res ?? '').toString().trim();
      if (code.isEmpty) return null;
      return code;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _usernameExistsRpc(String username) async {
    final email = await AuthService.getEmailByUsername(username);
    return email != null && email.trim().isNotEmpty;
  }

  Future<void> _checkUsernameExistsDebounced() async {
    _userCheckDebounce?.cancel();

    final u = (_getRealUsername() ?? '').trim();
    if (!_looksLikeUsername10Digits(u)) {
      if (!mounted) return;
      setState(() {
        _checkingUsername = false;
        _usernameExists = false;
        _usernameCheckDone = false;
      });
      return;
    }

    _userCheckDebounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted) return;
      setState(() => _checkingUsername = true);

      final exists = await _usernameExistsRpc(u);

      if (!mounted) return;
      setState(() {
        _usernameExists = exists;
        _checkingUsername = false;
        _usernameCheckDone = true;
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

    // ✅ remember username masked (stored as real username; shown masked)
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

    final real = (_getRealUsername() ?? '').trim();
    if (_looksLikeUsername10Digits(real)) {
      await prefs.setString('username', real); // ✅ نخزن الحقيقي
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

  Future<bool> _isAccountLockedLocal(String username) async {
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

  Future<void> _updateFailedAttemptsLocal(String username) async {
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

  Future<void> _resetFailedAttemptsLocal(String username) async {
    _failedAttempts.remove(username);
    _lockoutUntil.remove(username);
    await _savePreferences();
  }

  // ✅ فتح شاشة الدخول السريع (بدلاً من Checkbox)
  Future<void> _openQuickLogin() async {
    final t = AppLocalizations.of(context)!;
    final u = (_getRealUsername() ?? '').trim();
    final normalized = _normalizeNumbers(u).trim();

    // شرط: لازم يكون المستخدم "مسجل" (أي username موجود بالنظام)
    if (!_looksLikeUsername10Digits(normalized)) {
      setState(() {
        loginError = true;
        loginErrorText = _isAr
            ? 'اكتب رقم الهوية/الإقامة (10 أرقام) أولاً'
            : 'Enter ID/Iqama (10 digits) first';
      });
      return;
    }

    final exists = await _usernameExistsRpc(normalized);
    if (!exists) {
      setState(() {
        loginError = true;
        loginErrorText = _isAr
            ? 'لا يوجد حساب مرتبط بهذه الهوية/الإقامة'
            : 'No account linked to this ID/Iqama';
      });
      return;
    }

    // ✅ انتقل لشاشة الدخول السريع
    // ملاحظة: هذه الشاشة يجب أن تنفذ دخول (PIN/Face/Fingerprint) ثم تذهب مباشرة للـ Dashboard
    // بدون المرور على OTP.
    Navigator.pushNamed(
      context,
      '/quickLogin',
      arguments: {'username': normalized},
    );
  }

  Future<void> _login() async {
    if (isBusy) return; // ✅ منع الضغط المزدوج

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
        loginErrorText = _isAr
            ? 'رقم الهوية/الإقامة يجب أن يكون 10 أرقام'
            : 'ID/Iqama must be 10 digits';
      });
      await _updateFailedAttemptsLocal(u);
      return;
    }

    // ✅ قفل محلي (إضافي) فقط
    if (await _isAccountLockedLocal(u)) return;

    if (showCaptcha) {
      if (userCaptchaInput.trim().toUpperCase() != captchaText) {
        setState(() {
          loginError = true;
          loginErrorText =
              _isAr ? 'رمز التحقق غير صحيح' : 'Incorrect CAPTCHA code';
          _generateCaptcha();
        });
        await _updateFailedAttemptsLocal(u);
        return;
      }
    }

    // ✅ تحميل واحد فقط: نبقي isBusy=true طوال العملية وحتى التنقل
    setState(() {
      isBusy = true;
      loginError = false;
      loginErrorText = '';
    });

    final lang = langNotifier.value == 'en' ? 'en' : 'ar';

    // ✅ 1) تسجيل الدخول بكلمة المرور عبر AuthService
    final result = await AuthService.login(
      username: u,
      password: password,
      lang: lang,
    );

    if (!mounted) return;

    if (!result.ok) {
      // ✅ لو الحساب مقفل (من DB status) نظهر رسالة واضحة
      if (result.locked) {
        setState(() {
          isBusy = false;
          loginError = true;
          loginErrorText = result.message.isEmpty
              ? (_isAr
                  ? 'الحساب مقفل، استخدم استعادة كلمة المرور.'
                  : 'Account is locked. Use password recovery.')
              : result.message;
        });
        return;
      }

      await _updateFailedAttemptsLocal(u);
      setState(() {
        isBusy = false;
        loginError = true;
        loginErrorText = result.message.isEmpty
            ? (_isAr ? 'فشل تسجيل الدخول' : 'Login failed')
            : result.message;
      });
      return;
    }

    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      setState(() {
        isBusy = false;
        loginError = true;
        loginErrorText = _isAr
            ? 'تم التحقق لكن لم يتم إنشاء جلسة دخول (Session).'
            : 'Verified but no session created.';
      });
      return;
    }

    await _resetFailedAttemptsLocal(u);

    if (rememberMe) {
      _storedUsername = u;
      await _savePreferences();
    }

    TextInput.finishAutofillContext(shouldSave: true);

    // ✅ 2) فحص الجهاز المعروف عبر RPC
    final known = await AuthService.isDeviceKnown(u);

    // ✅ 3) لو fastLogin + جهاز معروف -> دخول مباشر (بدون OTP)
    // هذا المسار يحقق شرطك: (الدخول السريع/الوجه/البصمة) لا يمر على التحقق
    if (fastLogin && known) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/userDashboard');
      return;
    }

    // ✅ 4) خلاف ذلك -> طلب OTP عبر RPC
    final otpOk = await AuthService.requestOtp(u);

    String? devCode;
    bool ok = otpOk;

    if (!ok && kDebugMode) {
      devCode = await _requestOtpDev(u);
      ok = devCode != null && devCode!.isNotEmpty;
    }

    if (!ok) {
      if (!mounted) return;
      setState(() {
        isBusy = false;
        loginError = true;
        loginErrorText = _isAr
            ? 'تعذر إرسال رمز التحقق (OTP). حاول مرة أخرى.'
            : 'Failed to send OTP. Please try again.';
      });
      return;
    }

    // ✅ 5) انتقل لشاشة التحقق OTP
    // (التسجيل/الربط للجهاز بعد نجاح OTP يتم داخل verify_screen)
    final args = {
      'next': '/userDashboard',
      'username': u,
      'registerDeviceOnSuccess': !known,
      if (devCode != null) 'code': devCode,
    };

    if (!mounted) return;
    Navigator.pushReplacementNamed(
      context,
      '/verify',
      arguments: args,
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

  // ===================== UI helpers =====================
  Widget _loginCard({
    required double maxWidth,
    required double borderRadius,
    required AppLocalizations t,
    required bool allowVerticalScroll,
  }) {
    final cardColor = _isLight
        ? Colors.white.withOpacity(0.95)
        : const Color(0xFF171A22).withOpacity(0.95);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _topBarUnified(t: t),

        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_user, size: 16, color: _successColor),
            const SizedBox(width: 6),
            Text(
              _isAr ? 'تسجيل دخول آمن' : 'Secure Login',
              style: TextStyle(
                fontSize: _font(context, 12, 11),
                color: _successColor,
                fontWeight: FontWeight.w900,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),

        const SizedBox(height: 6),
        ScaleTransition(
          scale: _pulse,
          child: Image.asset(
            'assets/logo.png',
            height: 150,
            width: 150,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.apartment_rounded, size: 96, color: _textPrimary),
          ),
        ),

        const SizedBox(height: 8),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              t.welcomeTrustedAqar,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: _textPrimary,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.visible,
            ),
          ),
        ),

        const SizedBox(height: 8),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              t.signInToContinue,
              style: TextStyle(
                fontSize: 14,
                color: _textSecondary,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
            ),
          ),
        ),

        const SizedBox(height: 16),
        AutofillGroup(
          child: Column(
            children: [
              _buildUsernameField(t: t),
              const SizedBox(height: 10),
              _buildPasswordField(t: t),
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
                  fontSize: _font(context, 13, 12),
                  fontWeight: FontWeight.w900,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // ✅ بديل Checkbox الدخول السريع:
            // بلاطة صغيرة قابلة للنقر تفتح شاشة الدخول السريع
            const SizedBox(width: 10),
            _quickLoginTile(t: t),
          ],
        ),

        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => Navigator.pushNamed(context, '/resetPassword'),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                t.forgotUsernameOrPassword,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: _font(context, 14, 12.2),
                ),
              ),
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
        ),

        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            try {
              Navigator.pushNamed(context, '/passwordSetup');
            } catch (_) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _isAr
                        ? 'صفحة إنشاء حساب غير مفعّلة حالياً'
                        : 'Register screen is not enabled yet',
                  ),
                ),
              );
            }
          },
          child: Text(
            _isAr ? 'إنشاء حساب جديد' : 'Create new account',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: _bankColor,
              fontSize: _font(context, 14, 12.5),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        color: cardColor,
        child: child,
      ),
    );
  }

  Widget _quickLoginTile({required AppLocalizations t}) {
    final bg = _isLight ? Colors.white : const Color(0xFF0F1425);
    final border = _isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A);

    return InkWell(
      onTap: isBusy ? null : _openQuickLogin,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 40,
        padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fingerprint_rounded, color: _bankColor, size: 18),
            const SizedBox(width: 8),
            Text(
              t.quickLogin,
              style: TextStyle(
                color: _textPrimary,
                fontSize: _font(context, 12.8, 11.6),
                fontWeight: FontWeight.w900,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: _iconColor, size: 18),
          ],
        ),
      ),
    );
  }

  // ✅ شريط علوي صغير جداً: مربعين دائماً في سطر واحد
  Widget _topBarUnified({required AppLocalizations t}) {
    return LayoutBuilder(
      builder: (context, c) {
        final langShort = (langNotifier.value == 'en') ? 'EN' : 'AR';

        final themeShort = _currentTheme == ThemeMode.light
            ? '☀'
            : (_currentTheme == ThemeMode.dark ? '🌙' : 'AUTO');

        return Row(
          children: [
            Expanded(
              child: _topChipCompact(
                icon: Icons.language_rounded,
                value: langShort,
                onTap: () => _showLanguageSheet(t: t),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _topChipCompact(
                icon: Icons.color_lens_outlined,
                value: themeShort,
                onTap: () => _showThemeSheet(t: t),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _topChipCompact({
    required IconData icon,
    required String value,
    required VoidCallback onTap,
  }) {
    final bg = _isLight ? Colors.white : const Color(0xFF0F1425);
    final border = _isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 44,
        padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _bankColor.withOpacity(_isLight ? 0.10 : 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _bankColor, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: _font(context, 13, 12.2),
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
            Icon(Icons.expand_more_rounded, color: _iconColor),
          ],
        ),
      ),
    );
  }

  void _showLanguageSheet({required AppLocalizations t}) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ValueListenableBuilder<String>(
            valueListenable: langNotifier,
            builder: (_, __, ___) {
              final isLight = themeModeNotifier.value == ThemeMode.light;
              final bg = isLight ? Colors.white : const Color(0xFF0F1425);
              final border =
                  isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A);

              return ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: border),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 24,
                        color: Colors.black.withOpacity(0.22),
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _sheetHeader(
                          title: t.language,
                          subtitle:
                              _isAr ? 'اختر لغة التطبيق' : 'Choose app language',
                        ),
                        const SizedBox(height: 12),
                        _radioTile(
                          title: t.languageArabic,
                          subtitle: 'العربية',
                          selected: langNotifier.value != 'en',
                          onTap: () async {
                            await _setLanguage('ar');
                            if (mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 8),
                        _radioTile(
                          title: t.languageEnglish,
                          subtitle: 'English',
                          selected: langNotifier.value == 'en',
                          onTap: () async {
                            await _setLanguage('en');
                            if (mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showThemeSheet({required AppLocalizations t}) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          backgroundColor: Colors.transparent,
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (_, __, ___) {
              final isLight = themeModeNotifier.value == ThemeMode.light;
              final bg = isLight ? Colors.white : const Color(0xFF0F1425);
              final border =
                  isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A);

              return ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: border),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 24,
                        color: Colors.black.withOpacity(0.22),
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _sheetHeader(
                          title: t.theme,
                          subtitle: _isAr
                              ? 'اختر مظهر التطبيق'
                              : 'Choose app appearance',
                        ),
                        const SizedBox(height: 12),
                        _radioTile(
                          title: t.themeLight,
                          subtitle: _isAr ? 'نهاري' : 'Light',
                          selected: themeModeNotifier.value == ThemeMode.light,
                          onTap: () async {
                            await _setTheme(ThemeMode.light);
                            if (mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 8),
                        _radioTile(
                          title: t.themeDark,
                          subtitle: _isAr ? 'ليلي' : 'Dark',
                          selected: themeModeNotifier.value == ThemeMode.dark,
                          onTap: () async {
                            await _setTheme(ThemeMode.dark);
                            if (mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 8),
                        _radioTile(
                          title: t.themeSystem,
                          subtitle: _isAr ? 'تلقائي' : 'System',
                          selected: themeModeNotifier.value == ThemeMode.system,
                          onTap: () async {
                            await _setTheme(ThemeMode.system);
                            if (mounted) Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _sheetHeader({required String title, required String subtitle}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: _textSecondary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.close_rounded, color: _iconColor),
          tooltip: _isAr ? 'إغلاق' : 'Close',
        )
      ],
    );
  }

  Widget _radioTile({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final bg = selected
        ? _bankColor.withOpacity(_isLight ? 0.10 : 0.18)
        : Colors.transparent;

    final border = selected
        ? _bankColor.withOpacity(0.6)
        : (_isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: selected ? _bankColor : _iconColor,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: _textSecondary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ✅ حقل الهوية
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
    } else if (_usernameCheckDone && is10 && _usernameExists) {
      suffix = SizedBox(
        width: 44,
        height: 44,
        child: Center(child: Icon(Icons.verified_rounded, color: _successColor)),
      );
    } else if (_usernameCheckDone && is10 && !_usernameExists && raw.isNotEmpty) {
      suffix = SizedBox(
        width: 44,
        height: 44,
        child: Center(child: Icon(Icons.error_outline, color: _errorColor)),
      );
    }

    return TextField(
      controller: _usernameController,
      focusNode: _usernameFocus,
      keyboardType: TextInputType.number,
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      textAlign: _isAr ? TextAlign.right : TextAlign.left,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      maxLength: 10,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _passwordFocus.requestFocus(),
      autofillHints: const [AutofillHints.username],
      style: TextStyle(
        color: _textPrimary,
        fontWeight: FontWeight.w900,
        fontSize: 16,
      ),
      decoration: InputDecoration(
        hintText: _isAr
            ? 'رقم الهوية/الإقامة (10 أرقام)'
            : 'Saudi ID/Iqama (10 digits)',
        hintStyle: TextStyle(
          color: _hintColor,
          fontWeight: FontWeight.w800,
          fontSize: _font(context, 14, 12.0),
        ),
        counterText: '',
        isDense: false,
        contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 16, 14, 16),
        prefixIcon: Icon(Icons.badge_outlined, color: _iconColor),
        prefixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 46),
        suffixIcon: suffix,
        suffixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 46),
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

  // ✅ كلمة المرور
  Widget _buildPasswordField({required AppLocalizations t}) {
    return TextField(
      controller: _passwordController,
      focusNode: _passwordFocus,
      obscureText: obscurePassword,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _login(),
      autofillHints: const [AutofillHints.password],
      enableSuggestions: false,
      autocorrect: false,
      style: TextStyle(
        color: _textPrimary,
        fontWeight: FontWeight.w900,
        fontSize: 16,
      ),
      decoration: InputDecoration(
        hintText: t.passwordHint,
        hintStyle: TextStyle(
          color: _hintColor,
          fontWeight: FontWeight.w800,
          fontSize: _font(context, 14, 12.0),
        ),
        isDense: false,
        contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 16, 14, 16),
        prefixIcon: Icon(Icons.lock_outline, color: _iconColor),
        prefixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 46),
        suffixIcon: IconButton(
          icon: Icon(
            obscurePassword ? Icons.visibility : Icons.visibility_off,
            color: _iconColor,
          ),
          onPressed: () => setState(() => obscurePassword = !obscurePassword),
          tooltip: obscurePassword
              ? (_isAr ? 'إظهار' : 'Show')
              : (_isAr ? 'إخفاء' : 'Hide'),
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 46),
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
              Icon(
                Icons.security_rounded,
                color: _isLight ? const Color(0xFF92400E) : Colors.white,
              ),
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
              color:
                  _isLight ? const Color(0xFF92400E) : const Color(0xFFFDE68A),
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
                      color:
                          _isLight ? const Color(0xFFF3F4F6) : const Color(0xFF374151),
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
                              color: _isLight
                                  ? const Color(0xFF0B1220)
                                  : Colors.white,
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
                              color: _isLight
                                  ? const Color(0xFF4A5568)
                                  : const Color(0xFFCBD5E1),
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
                      color:
                          isLight ? const Color(0xFFE5E7EB) : const Color(0xFF1F2A44),
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subtitle,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
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
                                  color: isLight
                                      ? const Color(0xFFEFF3FF)
                                      : const Color(0xFF101A33),
                                  child: Center(
                                    child: Icon(Icons.image_outlined,
                                        size: 36, color: titleColor),
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
                                  color: isLight
                                      ? const Color(0xFFE5E7EB)
                                      : const Color(0xFF223055),
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

// lib/screens/verify_screen.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aqar_user/l10n/app_localizations.dart';

import 'package:sms_autofill/sms_autofill.dart';
import 'package:pin_code_fields/pin_code_fields.dart';

import 'package:no_screenshot/no_screenshot.dart';

import '../services/fast_login_service.dart';

enum OtpSource { sms, dev }

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen>
    with CodeAutoFill, WidgetsBindingObserver {
  static const Color _bankColor = Color(0xFF0F766E);

  static const int _otpLen = 4;
  static const int _maxSeconds = 60;

  static const int _maxAttempts = 3;
  static const int _lockAfterCycles = 2;

  final NoScreenshot _noScreenshot = NoScreenshot();

  bool _privacyMask = false;

  Timer? _timer;
  int _secondsLeft = _maxSeconds;
  DateTime? _expiresAt;

  int _attemptsLeft = _maxAttempts;
  bool _error = false;
  bool _submitting = false;

  String _expectedCode = '';
  String _otp = '';
  final TextEditingController _otpController = TextEditingController();
  final FocusNode _otpFocus = FocusNode();

  String _nextRoute = '/';
  Map<String, dynamic> _nextArgs = <String, dynamic>{};

  String _fullName = '';
  String _displayName = '';
  DateTime? _lastLogin;
  String _username = '';
  String _deviceId = '';
  bool _argsRead = false;
  bool _expectedFromArgs = false;

  OverlayEntry? _bannerEntry;
  Timer? _bannerTimer;
  bool _bannerPinnedManual = false;
  String? _lastBannerCode;
  int _lastBannerAtMs = 0;

  String _keyExpiresAt() => 'verify_expiresAt_${_username.trim()}';
  String _keyExpectedCode() => 'verify_expectedCode_${_username.trim()}';

  bool get _isAr {
    try {
      final t = AppLocalizations.of(context);
      if (t == null) return Directionality.of(context) == TextDirection.rtl;
      return t.localeName.toLowerCase().startsWith('ar');
    } catch (_) {
      return Directionality.of(context) == TextDirection.rtl;
    }
  }

  double _font(BuildContext context, double desktop, double mobile) {
    final w = MediaQuery.of(context).size.width;
    if (w < 320) return mobile - 1.4;
    if (w < 330) return mobile - 1.0;
    if (w < 380) return mobile;
    return desktop;
  }

  String _genOtp() {
    final r = math.Random();
    final n = r.nextInt(10000);
    return n.toString().padLeft(4, '0');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      _readArgsOnce();

      await _enableScreenProtection();

      await _checkLockedStatusAndExitIfNeeded();

      await _loadProfileFromDbIfNeeded();

      await _loadPersistedOtpState();
      _startOrResumeTimer();

      if (!kIsWeb) {
        try {
          await SmsAutoFill().listenForCode();
        } catch (_) {}
      }

      if (kDebugMode && _expectedCode.trim().isNotEmpty) {
        onIncomingOtp(_expectedCode, source: OtpSource.dev);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _timer?.cancel();
    _removeBanner();

    _safeVoid(() => _noScreenshot.screenshotOn());

    try {
      SmsAutoFill().unregisterListener();
    } catch (_) {}
    cancel();

    _otpController.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  Future<void> _enableScreenProtection() async {
    await _safeAsync(() => _noScreenshot.screenshotOff());
  }

  Future<void> _safeAsync(Future<dynamic> Function() fn) async {
    try {
      await fn();
    } catch (_) {}
  }

  void _safeVoid(void Function() fn) {
    try {
      fn();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      setState(() => _privacyMask = true);
    } else if (state == AppLifecycleState.resumed) {
      setState(() => _privacyMask = false);
      _startOrResumeTimer(recalcOnly: true);
    }
  }

  @override
  void codeUpdated() {
    final c = (code ?? '').trim();
    if (c.isEmpty) return;
    onIncomingOtp(c, source: OtpSource.sms);
  }

  void _readArgsOnce() {
    if (_argsRead) return;
    _argsRead = true;

    final rawArgs = ModalRoute.of(context)?.settings.arguments;
    final args = (rawArgs is Map) ? rawArgs : <String, dynamic>{};

    setState(() {
      final fromArgs = (args['code'] as String?)?.trim();
      _expectedFromArgs = fromArgs != null && fromArgs.isNotEmpty;
      _expectedCode = _expectedFromArgs ? fromArgs! : _genOtp();

      _nextRoute = (args['next'] as String?) ?? '/';
      final na = args['nextArgs'];
      _nextArgs = (na is Map) ? Map<String, dynamic>.from(na) : <String, dynamic>{};

      _fullName = (args['fullName'] as String?) ?? '';
      _lastLogin = args['lastLogin'] as DateTime?;
      _username = (args['username'] as String?) ?? '';
      _deviceId = (args['deviceId'] as String?) ?? '';
    });
  }

  Future<void> _loadPersistedOtpState() async {
    final u = _username.trim();
    if (u.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();

    final expStr = prefs.getString(_keyExpiresAt());
    final codeStr = prefs.getString(_keyExpectedCode());

    final exp = (expStr == null || expStr.trim().isEmpty) ? null : DateTime.tryParse(expStr);

    if (_expectedFromArgs) {
      await prefs.setString(_keyExpectedCode(), _expectedCode.trim());
    } else {
      if (codeStr != null && codeStr.trim().isNotEmpty) {
        _expectedCode = codeStr.trim();
      } else {
        await prefs.setString(_keyExpectedCode(), _expectedCode);
      }
    }

    if (exp != null && exp.isAfter(DateTime.now().toUtc())) {
      _expiresAt = exp;
    } else {
      _expiresAt = DateTime.now().toUtc().add(const Duration(seconds: _maxSeconds));
      await prefs.setString(_keyExpiresAt(), _expiresAt!.toIso8601String());
    }
  }

  Future<void> _persistOtpState() async {
    final u = _username.trim();
    if (u.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    if (_expiresAt != null) {
      await prefs.setString(_keyExpiresAt(), _expiresAt!.toIso8601String());
    }
    if (_expectedCode.trim().isNotEmpty) {
      await prefs.setString(_keyExpectedCode(), _expectedCode.trim());
    }
  }

  void _startOrResumeTimer({bool recalcOnly = false}) {
    _timer?.cancel();

    final exp = _expiresAt;
    if (exp == null) {
      _secondsLeft = _maxSeconds;
      setState(() {});
      if (!recalcOnly) {
        _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      }
      return;
    }

    final diff = exp.difference(DateTime.now().toUtc()).inSeconds;
    _secondsLeft = diff <= 0 ? 0 : diff;

    setState(() {});
    if (recalcOnly) return;

    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final exp = _expiresAt;
    if (exp == null) return;

    final diff = exp.difference(DateTime.now().toUtc()).inSeconds;
    if (diff <= 0) {
      _timer?.cancel();
      setState(() => _secondsLeft = 0);
      return;
    }
    setState(() => _secondsLeft = diff);
  }

  Future<bool> _isLockedInDb() async {
    final u = _username.trim();
    if (u.isEmpty) return false;

    try {
      final sb = Supabase.instance.client;
      final row =
          await sb.from('users_profiles').select('status').eq('username', u).maybeSingle();

      final s = (row?['status'] ?? '').toString().trim().toLowerCase();
      return s == 'locked';
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkLockedStatusAndExitIfNeeded() async {
    final locked = await _isLockedInDb();
    if (!mounted) return;

    if (locked) {
      _toast(_isAr
          ? 'الحساب مقفل. استخدم استعادة كلمة المرور لفتحه.'
          : 'Account locked. Use password recovery to unlock.');
      await _goToLogin();
    }
  }

  Future<Map<String, dynamic>?> _getOtpFailState() async {
    final u = _username.trim();
    if (u.isEmpty) return null;
    try {
      final sb = Supabase.instance.client;
      return await sb
          .from('users_profiles')
          .select('otp_fail_cycles, otp_fail_count')
          .eq('username', u)
          .maybeSingle();
    } catch (_) {
      return null;
    }
  }

  Future<void> _setOtpFailState({
    required int cycles,
    required int count,
    required bool lockNow,
  }) async {
    final u = _username.trim();
    if (u.isEmpty) return;

    try {
      final sb = Supabase.instance.client;
      final data = <String, dynamic>{
        'otp_fail_cycles': cycles,
        'otp_fail_count': count,
        'otp_fail_last_at': DateTime.now().toUtc().toIso8601String(),
      };
      if (lockNow) data['status'] = 'locked';

      await sb.from('users_profiles').update(data).eq('username', u);
    } catch (_) {}
  }

  Future<void> _resetOtpFailStateInDb() async {
    final u = _username.trim();
    if (u.isEmpty) return;
    try {
      final sb = Supabase.instance.client;
      await sb.from('users_profiles').update({
        'otp_fail_cycles': 0,
        'otp_fail_count': 0,
        'otp_fail_last_at': null,
      }).eq('username', u);
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final morning = h < 12;
    if (_isAr) return morning ? 'صباح الخير' : 'مساء الخير';
    return morning ? 'Good morning' : 'Good evening';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _formatDateDDMMYYYY(DateTime d) {
    final v = d.toLocal();
    return '${_two(v.day)}/${_two(v.month)}/${v.year}';
  }

  String _formatTime12(DateTime d) {
    final v = d.toLocal();
    int h = v.hour;
    final m = _two(v.minute);
    final isPm = h >= 12;

    int h12 = h % 12;
    if (h12 == 0) h12 = 12;

    final suffix = _isAr ? (isPm ? 'م' : 'ص') : (isPm ? 'PM' : 'AM');
    return '${_two(h12)}:$m $suffix';
  }

  String _weekdayName(DateTime d) {
    final wd = d.toLocal().weekday;
    if (_isAr) {
      const ar = [
        'الاثنين',
        'الثلاثاء',
        'الأربعاء',
        'الخميس',
        'الجمعة',
        'السبت',
        'الأحد'
      ];
      return ar[wd - 1];
    } else {
      const en = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
      ];
      return (wd >= 1 && wd <= 7) ? en[wd - 1] : 'Day';
    }
  }

  String _todayLine() {
    final now = DateTime.now();
    return '${_weekdayName(now)}  ${_formatDateDDMMYYYY(now)}  •  ${_formatTime12(now)}';
  }

  String _lastLoginLine() {
    final v = _lastLogin;
    if (v == null) return _isAr ? 'غير متوفر' : 'N/A';
    return '${_formatDateDDMMYYYY(v)}  •  ${_formatTime12(v)}';
  }

  void onIncomingOtp(String text, {required OtpSource source}) {
    final only = text.replaceAll(RegExp(r'\D'), '');
    if (only.isEmpty) return;

    final code = only.length >= _otpLen ? only.substring(0, _otpLen) : only;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastBannerCode == code && (now - _lastBannerAtMs) < 1200) return;
    _lastBannerCode = code;
    _lastBannerAtMs = now;

    _showBanner(code: code, source: source);
  }

  // ✅ Banner محسّن جداً للأجهزة الصغيرة جداً:
  // - سطرين (عنوان + الكود) كل واحد maxLines=1
  // - الأزرار أسفل (Scrollable أفقياً) بدون كسر/التفاف
  // - قياسات تتكيف حتى عرض 300
  void _showBanner({required String code, required OtpSource source}) {
    if (!mounted) return;

    _removeBanner();
    _bannerPinnedManual = false;

    final overlay = Overlay.of(context);
    if (overlay == null) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final border = isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.08);
    final titleColor = isDark ? Colors.white : const Color(0xFF0B1220);
    final bodyColor = isDark ? const Color(0xFFD1D5DB) : const Color(0xFF475569);

    final title = _isAr
        ? (source == OtpSource.dev ? 'رمز (DEV)' : 'تم استلام رمز التحقق')
        : (source == OtpSource.dev ? 'DEV code' : 'Verification code received');

    _bannerEntry = OverlayEntry(
      builder: (_) {
        return LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;

            final bool isTiny = w < 360;
            final bool isXTiny = w < 320;

            final double side = (w * 0.04).clamp(8.0, 16.0);
            final double topExtra = (w * 0.02).clamp(4.0, 10.0) + (isTiny ? 2.0 : 4.0);

            final double radius = (w * 0.055).clamp(16.0, 22.0);

            final double titleFs = (w * 0.040).clamp(12.0, 15.0);
            final double bodyFs = (w * 0.036).clamp(12.0, 14.0);
            final double btnFs = (w * 0.034).clamp(11.8, 13.5);

            Widget actionButton({
              required String label,
              required VoidCallback onTap,
              required Color textColor,
              bool primary = false,
            }) {
              return TextButton(
                onPressed: onTap,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: isXTiny ? 10 : 12,
                    vertical: isXTiny ? 6 : 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: primary ? FontWeight.w900 : FontWeight.w800,
                    fontSize: btnFs,
                  ),
                ),
              );
            }

            final actionsRow = Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                actionButton(
                  label: _isAr ? 'لصق' : 'Paste',
                  textColor: titleColor,
                  primary: true,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _removeBanner();
                    _applyIncomingCode(code);
                    _toast(_isAr ? 'تم لصق الرمز' : 'Code pasted');
                  },
                ),
                const SizedBox(width: 6),
                actionButton(
                  label: _isAr ? 'إدخال يدوي' : 'Manual',
                  textColor: bodyColor,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _bannerPinnedManual = true;
                    _bannerTimer?.cancel();
                    _bannerTimer = null;
                    _otpFocus.requestFocus();
                  },
                ),
                const SizedBox(width: 6),
                actionButton(
                  label: _isAr ? 'إغلاق' : 'Close',
                  textColor: bodyColor,
                  onTap: _removeBanner,
                ),
              ],
            );

            return SafeArea(
              top: true,
              bottom: false,
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: side,
                  end: side,
                  top: topExtra,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Material(
                    color: Colors.transparent,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (w * 0.94).clamp(300.0, 560.0),
                      ),
                      child: Container(
                        padding: EdgeInsetsDirectional.fromSTEB(
                          isXTiny ? 10 : 12,
                          isXTiny ? 9 : 10,
                          isXTiny ? 10 : 12,
                          isXTiny ? 8 : 10,
                        ),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(radius),
                          border: Border.all(color: border),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 18,
                              offset: const Offset(0, 10),
                              color: Colors.black.withOpacity(isDark ? 0.35 : 0.12),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: isXTiny ? 34 : 38,
                                  height: isXTiny ? 34 : 38,
                                  decoration: BoxDecoration(
                                    color: (isDark ? Colors.white : Colors.black).withOpacity(0.06),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.sms_outlined,
                                    color: titleColor,
                                    size: isXTiny ? 18 : 20,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: titleColor,
                                          fontWeight: FontWeight.w900,
                                          fontSize: titleFs,
                                          height: 1.1,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        _isAr ? 'رمز التحقق: $code' : 'Your code: $code',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: bodyColor,
                                          fontWeight: FontWeight.w800,
                                          fontSize: bodyFs,
                                          height: 1.1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: isXTiny ? 8 : 10),
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                child: actionsRow,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    overlay.insert(_bannerEntry!);

    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted) return;
      if (_bannerPinnedManual) return;
      _removeBanner();
    });
  }

  void _removeBanner() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    _bannerPinnedManual = false;

    _bannerEntry?.remove();
    _bannerEntry = null;
  }

  void _clear() {
    setState(() {
      _otp = '';
      _otpController.clear();
      _error = false;
      _attemptsLeft = _maxAttempts;
    });
    _otpFocus.requestFocus();
  }

  void _applyIncomingCode(String text) {
    final only = text.replaceAll(RegExp(r'\D'), '');
    if (only.isEmpty) return;

    final take = only.length >= _otpLen ? only.substring(0, _otpLen) : only;

    setState(() {
      _otp = take;
      _otpController.text = take;
      _otpController.selection = TextSelection.collapsed(offset: take.length);
      _error = false;
    });

    if (take.length == _otpLen) {
      _submit();
    } else {
      _otpFocus.requestFocus();
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final entered = _otp.trim();

    if (entered.isEmpty) {
      HapticFeedback.mediumImpact();
      setState(() => _error = true);
      _toast(_isAr ? 'الرجاء تعبئة الحقول بالرمز المرسل' : 'Please enter the sent code');
      _otpFocus.requestFocus();
      return;
    }
    if (entered.length != _otpLen) {
      HapticFeedback.mediumImpact();
      setState(() => _error = true);
      _toast(_isAr ? 'الرجاء إدخال الرمز كاملاً' : 'Please enter the full code');
      _otpFocus.requestFocus();
      return;
    }

    setState(() => _submitting = true);
    try {
      if (entered != _expectedCode) {
        HapticFeedback.vibrate();

        setState(() {
          _attemptsLeft--;
          _error = true;
        });

        final state = await _getOtpFailState();
        int cycles = (state?['otp_fail_cycles'] ?? 0) is int
            ? (state?['otp_fail_cycles'] as int)
            : int.tryParse('${state?['otp_fail_cycles'] ?? 0}') ?? 0;

        int count = (state?['otp_fail_count'] ?? 0) is int
            ? (state?['otp_fail_count'] as int)
            : int.tryParse('${state?['otp_fail_count'] ?? 0}') ?? 0;

        count += 1;

        if (count >= _maxAttempts) {
          count = 0;
          cycles += 1;
        }

        final lockNow = cycles >= _lockAfterCycles;
        await _setOtpFailState(cycles: cycles, count: count, lockNow: lockNow);

        if (lockNow) {
          _toast(_isAr
              ? 'تم قفل الحساب. استعد كلمة المرور لفتحه.'
              : 'Account locked. Use password recovery to unlock.');
          await _goToLogin();
          return;
        }

        if (_attemptsLeft <= 0) {
          _toast(_isAr ? 'تم تجاوز الحد. تم إعادتك لتسجيل الدخول.' : 'Limit reached. Returning to login.');
          await _goToLogin();
          return;
        }

        _toast(_isAr ? 'الرمز غير صحيح. المتبقي: $_attemptsLeft' : 'Invalid code. Left: $_attemptsLeft');
        _otpFocus.requestFocus();
        return;
      }

      await _resetOtpFailStateInDb();

      final rawArgs = ModalRoute.of(context)?.settings.arguments;
      final args = (rawArgs is Map) ? rawArgs : <String, dynamic>{};
      final shouldRegister = (args['registerDeviceOnSuccess'] as bool?) ?? false;

      if (shouldRegister) {
        await _safeAsync(() => Supabase.instance.client.rpc(
              'register_user_device',
              params: {
                'p_username': _username.trim(),
                'p_device_hash': _deviceId.trim(),
              },
            ));
      }

      _timer?.cancel();
      _removeBanner();

      final nextArgs = <String, dynamic>{
        ..._nextArgs,
        'username': _username,
        'deviceId': _deviceId,
        'fullName': _fullName,
        'lastLogin': _lastLogin,
      };

      // ✅ حفظ سياق المستخدم للدخول السريع بعد نجاح التحقق
      try {
        final uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid != null && uid.isNotEmpty) {
          final display = (_fullName.trim().isNotEmpty) ? _fullName.trim() : _username.trim();
          await FastLoginService.saveUserContext(
            uid: uid,
            usernameNationalId: _username.trim(),
            displayName: display,
          );
        }
      } catch (_) {}

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, _nextRoute, arguments: nextArgs);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resendCode() async {
    if (_secondsLeft > 0) {
      _toast(_isAr ? 'لا يمكن الإرسال قبل انتهاء العداد' : 'Resend is available after the timer ends');
      return;
    }

    setState(() {
      _attemptsLeft = _maxAttempts;
      _error = false;
      _otp = '';
      _otpController.clear();

      _expectedCode = _genOtp();
      _expiresAt = DateTime.now().toUtc().add(const Duration(seconds: _maxSeconds));
      _secondsLeft = _maxSeconds;
    });

    await _persistOtpState();
    _startOrResumeTimer();

    _toast(_isAr ? 'تم إرسال رمز جديد' : 'New code sent');

    if (kDebugMode) {
      onIncomingOtp(_expectedCode, source: OtpSource.dev);
    }
  }

  Future<void> _goToLogin() async {
    _timer?.cancel();
    _removeBanner();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  Future<void> _loadProfileFromDbIfNeeded() async {
    final u = _username.trim();
    if (u.isEmpty) return;

    try {
      final sb = Supabase.instance.client;
      final row = await sb
          .from('users_profiles')
          .select(
            'first_name_ar,second_name_ar,third_name_ar,fourth_name_ar,'
            'first_name_en,second_name_en,third_name_en,fourth_name_en,'
            'full_name_ar,full_name_en,full_name,last_login_at',
          )
          .eq('username', u)
          .maybeSingle();

      if (!mounted || row == null) return;

      String pickStr(String k) => (row[k] ?? '').toString().trim();

      final arParts = [
        pickStr('first_name_ar'),
        pickStr('second_name_ar'),
        pickStr('third_name_ar'),
        pickStr('fourth_name_ar'),
      ].where((e) => e.isNotEmpty).toList();

      final enParts = [
        pickStr('first_name_en'),
        pickStr('second_name_en'),
        pickStr('third_name_en'),
        pickStr('fourth_name_en'),
      ].where((e) => e.isNotEmpty).toList();

      final arFull = pickStr('full_name_ar');
      final enFull = pickStr('full_name_en');
      final anyFull = pickStr('full_name');

      final nameFromPartsAr = arParts.join(' ');
      final nameFromPartsEn = enParts.join(' ');

      final display = _isAr
          ? (nameFromPartsAr.isNotEmpty ? nameFromPartsAr : (arFull.isNotEmpty ? arFull : anyFull))
          : (nameFromPartsEn.isNotEmpty ? nameFromPartsEn : (enFull.isNotEmpty ? enFull : anyFull));

      DateTime? last;
      final lastRaw = row['last_login_at'];
      if (lastRaw is DateTime) {
        last = lastRaw;
      } else if (lastRaw != null) {
        last = DateTime.tryParse(lastRaw.toString());
      }

      setState(() {
        _displayName = display;
        if (display.isNotEmpty) _fullName = display;
        if (_lastLogin == null && last != null) _lastLogin = last;
      });
    } catch (_) {}
  }

  Widget _infoRow({
    required IconData icon,
    required String text,
    required Color color,
    required double fontSize,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            softWrap: true,
            overflow: TextOverflow.visible,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: fontSize,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }

  // ✅ OTP حقول قابلة للنقر مباشرة، لا شيء يمنع التركيز
  Widget _otpBoxes({required bool isDark, required double fontSize}) {
    return LayoutBuilder(
      builder: (context, c) {
        final cs = Theme.of(context).colorScheme;

        final maxW = c.maxWidth;
        const len = _otpLen;
        const gap = 10.0;
        final available = (maxW - (gap * (len - 1))).clamp(160.0, 1000.0);
        final raw = available / len;
        final fieldW = raw.clamp(42.0, 62.0);
        final fieldH = (fieldW + 4).clamp(50.0, 66.0);

        final inactiveBorder =
            isDark ? Colors.white.withOpacity(0.18) : Colors.black.withOpacity(0.10);

        final activeBorder = _bankColor.withOpacity(0.65);
        final selectedBorder = _bankColor;
        final errorBorder = cs.error;

        final useInactive = _error ? errorBorder : inactiveBorder;
        final useActive = _error ? errorBorder : activeBorder;
        final useSelected = _error ? errorBorder : selectedBorder;

        final fill = isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04);

        return PinCodeTextField(
          appContext: context,
          length: _otpLen,
          controller: _otpController,
          focusNode: _otpFocus,
          autoDisposeControllers: false,
          autoFocus: true,
          keyboardType: TextInputType.number,
          enableActiveFill: true,
          animationType: AnimationType.fade,
          animationDuration: const Duration(milliseconds: 120),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(_otpLen),
          ],
          mainAxisAlignment: MainAxisAlignment.center,
          pinTheme: PinTheme(
            shape: PinCodeFieldShape.box,
            borderRadius: BorderRadius.circular(12),
            fieldHeight: fieldH,
            fieldWidth: fieldW,
            inactiveColor: useInactive,
            activeColor: useActive,
            selectedColor: useSelected,
            inactiveFillColor: fill,
            selectedFillColor: fill,
            activeFillColor: fill,
            borderWidth: 1.4,
          ),
          textStyle: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: fontSize + 4,
          ),
          onChanged: (v) {
            final only = v.replaceAll(RegExp(r'\D'), '');
            setState(() {
              _otp = only.length > _otpLen ? only.substring(0, _otpLen) : only;
              if (_error) _error = false;
            });
          },
          onCompleted: (_) => _submit(),
          beforeTextPaste: (text) {
            final only = (text ?? '').replaceAll(RegExp(r'\D'), '');
            if (only.isEmpty) return false;
            HapticFeedback.selectionClick();
            _applyIncomingCode(only);
            _toast(_isAr ? 'تم لصق الرمز' : 'Code pasted');
            return false;
          },
        );
      },
    );
  }

  Widget _singleLineGreeting({
    required String greeting,
    required String name,
    required Color color,
    required double fontSize,
  }) {
    // سطر واحد فقط: يتقلص تلقائياً بدون التفاف
    final hasName = name.trim().isNotEmpty;

    final text = hasName ? '$greeting : ${name.trim()}' : greeting;

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          color: color,
          height: 1.1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF0B1220) : const Color(0xFFF5F7FA);
    final card = isDark ? const Color(0xFF121A2A) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF0B1220);
    final subColor = isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569);

    final nameSize = _font(context, 18.0, 15.5);
    final bodySize = _font(context, 13.5, 12.2);

    final displayName = (_displayName.trim().isNotEmpty) ? _displayName.trim() : _fullName.trim();

    final showResend = _secondsLeft <= 0;

    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: PopScope(
        canPop: false,
        onPopInvoked: (_) => _goToLogin(),
        child: Scaffold(
          backgroundColor: bg,
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            child: Stack(
              children: [
                LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    final isSmall = w < 360;
                    final isTiny = w < 320;

                    return Center(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(isTiny ? 12 : 16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Card(
                            color: card,
                            elevation: 10,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(isSmall ? 16 : 22),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      if (!_isAr)
                                        IconButton(
                                          onPressed: _goToLogin,
                                          icon: const Icon(Icons.arrow_back),
                                          tooltip: 'Back',
                                        ),
                                      const Spacer(),
                                      if (_isAr)
                                        IconButton(
                                          onPressed: _goToLogin,
                                          icon: const Icon(Icons.arrow_back),
                                          tooltip: 'رجوع',
                                        ),
                                    ],
                                  ),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: isTiny ? 40 : 44,
                                        height: isTiny ? 40 : 44,
                                        decoration: BoxDecoration(
                                          color: _bankColor.withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: Icon(
                                          Icons.verified_user_rounded,
                                          color: _bankColor,
                                          size: isTiny ? 22 : 24,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // ✅ سطر واحد فقط (بدون Wrap)
                                            _singleLineGreeting(
                                              greeting: _greeting(),
                                              name: displayName,
                                              color: titleColor,
                                              fontSize: nameSize,
                                            ),
                                            const SizedBox(height: 8),
                                            _infoRow(
                                              icon: Icons.calendar_today_rounded,
                                              text: _todayLine(),
                                              color: subColor,
                                              fontSize: bodySize,
                                            ),
                                            const SizedBox(height: 8),
                                            _infoRow(
                                              icon: Icons.login_rounded,
                                              text: (_isAr ? 'آخر تسجيل دخول: ' : 'Last login: ') + _lastLoginLine(),
                                              color: subColor,
                                              fontSize: bodySize,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    t.verifyTitle,
                                    style: TextStyle(
                                      fontSize: _font(context, 18, 16.5),
                                      fontWeight: FontWeight.w900,
                                      color: titleColor,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    t.verifySubtitle,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: subColor,
                                      fontSize: bodySize,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 14),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 10,
                                    runSpacing: 6,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.timer_outlined, size: 18, color: subColor),
                                          const SizedBox(width: 6),
                                          Text(
                                            showResend
                                                ? (_isAr ? 'انتهى الوقت' : 'Time expired')
                                                : (_isAr
                                                    ? 'المتبقي: $_secondsLeft ث'
                                                    : 'Remaining: $_secondsLeft s'),
                                            style: TextStyle(
                                              color: subColor,
                                              fontWeight: FontWeight.w900,
                                              fontSize: bodySize,
                                            ),
                                          ),
                                        ],
                                      ),
                                      TextButton.icon(
                                        onPressed: showResend ? _resendCode : null,
                                        icon: const Icon(Icons.refresh),
                                        label: Text(
                                          _isAr ? 'إعادة إرسال' : 'Resend',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: bodySize,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Directionality(
                                    textDirection: TextDirection.ltr,
                                    child: _otpBoxes(
                                      isDark: isDark,
                                      fontSize: bodySize,
                                    ),
                                  ),
                                  if (_error) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      t.invalidCode,
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.error,
                                        fontWeight: FontWeight.w900,
                                        fontSize: bodySize,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _isAr ? 'المحاولات المتبقية: $_attemptsLeft' : 'Attempts left: $_attemptsLeft',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: bodySize,
                                        color: subColor,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 50,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _bankColor,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                      ),
                                      onPressed: _submitting ? null : _submit,
                                      child: _submitting
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                          : Text(
                                              t.confirm,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: _font(context, 16, 15),
                                              ),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  if (kIsWeb)
                                    TextButton(
                                      onPressed: _clear,
                                      child: Text(_isAr ? 'مسح' : 'Clear'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (_privacyMask)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: Text(
                        _isAr ? 'محتوى محمي' : 'Protected content',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

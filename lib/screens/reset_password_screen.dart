// lib/screens/reset_password_screen.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aqar_user/main.dart'; // themeModeNotifier + langNotifier + recoveryFlowNotifier
import 'package:aqar_user/services/auth_service.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  static const Color _bankColor = Color(0xFF0F766E);

  // Step A: request reset (by username/national id)
  final TextEditingController _usernameCtrl = TextEditingController();
  final FocusNode _usernameFocus = FocusNode();

  // Step B: set new password (recovery session)
  final TextEditingController _p1 = TextEditingController();
  final TextEditingController _p2 = TextEditingController();
  final FocusNode _p1Focus = FocusNode();
  final FocusNode _p2Focus = FocusNode();

  bool _busy = false;
  String? _err;
  String? _ok;

  bool _hasRecoverySession = false;

  // small UX
  bool _obscure1 = true;
  bool _obscure2 = true;

  // to log security events after password change
  String? _recoveryUsername;

  // ✅ NEW: Listen to auth changes to auto-switch UI when recovery session becomes active
  StreamSubscription<AuthState>? _authSub;

  bool get _isAr => langNotifier.value != 'en';
  ThemeMode get _currentTheme => themeModeNotifier.value;
  bool get _isLight => _currentTheme == ThemeMode.light;

  Color get _pageBg =>
      _isLight ? const Color(0xFFF5F7FA) : const Color(0xFF0E0F13);
  Color get _textPrimary =>
      _isLight ? const Color(0xFF0B1220) : Colors.white;
  Color get _textSecondary =>
      _isLight ? const Color(0xFF5B6475) : const Color(0xFFB8C0D4);
  Color get _fieldFill => _isLight ? Colors.white : const Color(0xFF0F1425);
  Color get _fieldBorder =>
      _isLight ? const Color(0xFFE5E7EB) : const Color(0xFF2A355A);
  Color get _hintColor =>
      _isLight ? const Color(0xFF64748B) : const Color(0xFFCBD5E1);
  Color get _iconColor =>
      _isLight ? const Color(0xFF64748B) : const Color(0xFFCBD5E1);

  static const String _kRecoveryUsernameKey = 'recovery_username';

  @override
  void initState() {
    super.initState();

    // ✅ نحن داخل Recovery flow طالما فتحنا هذه الصفحة
    recoveryFlowNotifier.value = true;

    // ✅ NEW: Subscribe early so when web session gets activated from URL
    // the screen automatically flips to "new password" without manual refresh.
    final sb = Supabase.instance.client;
    _authSub = sb.auth.onAuthStateChange.listen((data) async {
      final event = data.event;

      if (event == AuthChangeEvent.passwordRecovery ||
          event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed) {
        await _syncRecoverySessionState();
        if (!mounted) return;
        setState(() {});
        if (_hasRecoverySession) {
          _p1Focus.requestFocus();
        }
      }

      // إذا تم تسجيل الخروج أثناء هذه الشاشة (زر العودة أو غيره)
      if (event == AuthChangeEvent.signedOut) {
        // لا نفعل redirect هنا، main.dart listener يتعامل مع ذلك
        _hasRecoverySession = false;
        if (!mounted) return;
        setState(() {});
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // ✅ 1) Web: فعل Session من الرابط
      await _bootstrapRecoveryFromUrlIfWeb();

      // ✅ 2) ثم حدث حالة الجلسة محلياً
      await _syncRecoverySessionState();

      // ✅ 3) اقرأ username المخزن (لاستخدامه في log_security_event بعد تغيير كلمة المرور)
      await _loadRecoveryUsername();

      if (!mounted) return;
      if (_hasRecoverySession) {
        _p1Focus.requestFocus();
      } else {
        _usernameFocus.requestFocus();
      }
      setState(() {});
    });

    _usernameCtrl.addListener(() {
      final normalized = AuthService.normalizeNumbers(_usernameCtrl.text);
      if (_usernameCtrl.text != normalized) {
        _usernameCtrl.text = normalized;
        _usernameCtrl.selection =
            TextSelection.collapsed(offset: normalized.length);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();

    _usernameCtrl.dispose();
    _usernameFocus.dispose();

    _p1.dispose();
    _p2.dispose();
    _p1Focus.dispose();
    _p2Focus.dispose();
    super.dispose();
  }

  Future<void> _loadRecoveryUsername() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getString(_kRecoveryUsernameKey);
      _recoveryUsername = (v == null || v.trim().isEmpty) ? null : v.trim();
    } catch (_) {
      _recoveryUsername = null;
    }
  }

  Future<void> _saveRecoveryUsername(String username) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kRecoveryUsernameKey, username);
      _recoveryUsername = username;
    } catch (_) {}
  }

  Future<void> _clearRecoveryUsername() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kRecoveryUsernameKey);
    } catch (_) {}
    _recoveryUsername = null;
  }

  Future<void> _logSecurity({
    required String action,
    required bool success,
    String? details,
  }) async {
    final u = _recoveryUsername?.trim();
    if (u == null || u.isEmpty) return;

    try {
      final sb = Supabase.instance.client;
      await sb.rpc(
        'log_security_event',
        params: {
          'p_username': u,
          'p_action': action,
          'p_success': success,
          'p_details': details,
        },
      );
    } catch (_) {}
  }

  Future<void> _syncRecoverySessionState() async {
    final sb = Supabase.instance.client;
    _hasRecoverySession = sb.auth.currentSession != null;
  }

  Future<void> _bootstrapRecoveryFromUrlIfWeb() async {
    if (!kIsWeb) return;

    final sb = Supabase.instance.client;

    // إذا فيه Session أصلاً ما نحتاج
    if (sb.auth.currentSession != null) return;

    try {
      final uri = Uri.base;

      // ✅ تحويل بيانات الرابط إلى Session في Flutter Web
      // هذا سيؤدي لاحقاً لإطلاق AuthChangeEvent.passwordRecovery
      await sb.auth.getSessionFromUrl(uri);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Error activating recovery session: $e');
      }
    }
  }

  bool _looksLikeUsername10(String s) => RegExp(r'^\d{10}$').hasMatch(s);

  Future<void> _requestResetByUsername() async {
    setState(() {
      _busy = true;
      _err = null;
      _ok = null;
    });

    final raw = _usernameCtrl.text.trim();
    final normalized = AuthService.normalizeNumbers(raw).trim();

    if (!_looksLikeUsername10(normalized)) {
      setState(() {
        _busy = false;
        _err = _isAr
            ? 'أدخل رقم الهوية/الإقامة الصحيح (10 أرقام).'
            : 'Enter a valid ID/Iqama (10 digits).';
      });
      return;
    }

    try {
      final lang = langNotifier.value == 'en' ? 'en' : 'ar';

      // ✅ خزّن username لاستعماله لاحقاً في log_security_event بعد تغيير كلمة المرور
      await _saveRecoveryUsername(normalized);

      // ✅ هذا يستدعي داخل AuthService:
      // - get_status_by_username (ضمن منطقك العام)
      // - log_security_event (password_recovery_sent / password_recovery_failed)
      final res = await AuthService.sendResetPasswordEmail(
        username: normalized,
        lang: lang,
        redirectTo: null,
      );

      if (!mounted) return;

      setState(() {
        _busy = false;
        if (!res.ok) {
          _err = res.message.isEmpty
              ? (_isAr
                  ? 'فشل إرسال رابط الاستعادة.'
                  : 'Failed to send recovery link.')
              : res.message;
        } else {
          _ok = _isAr
              ? 'تم إرسال رابط الاستعادة إلى بريدك الإلكتروني. الرجاء فتح أحدث رسالة بريدية واتباع التعليمات.'
              : 'Recovery link has been sent to your email. Please open the latest email message and follow the instructions.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = _isAr
            ? 'حدث خطأ أثناء طلب استعادة كلمة المرور: $e'
            : 'Error while requesting password reset: $e';
      });
    }
  }

  Future<void> _saveNewPassword() async {
    setState(() {
      _busy = true;
      _err = null;
      _ok = null;
    });

    final a = _p1.text.trim();
    final b = _p2.text.trim();

    if (a.isEmpty || b.isEmpty) {
      setState(() {
        _busy = false;
        _err = _isAr
            ? 'الرجاء إدخال كلمة المرور مرتين.'
            : 'Please enter the password twice.';
      });
      return;
    }
    if (a != b) {
      setState(() {
        _busy = false;
        _err = _isAr ? 'كلمتا المرور غير متطابقتين.' : 'Passwords do not match.';
      });
      return;
    }
    if (a.length < 8) {
      setState(() {
        _busy = false;
        _err = _isAr
            ? 'كلمة المرور يجب أن تتكون من 8 أحرف على الأقل.'
            : 'Password must be at least 8 characters long.';
      });
      return;
    }

    try {
      final sb = Supabase.instance.client;

      if (sb.auth.currentSession == null) {
        setState(() {
          _busy = false;
          _err = _isAr
              ? 'لا توجد جلسة استعادة نشطة. الرجاء فتح رابط الاستعادة من البريد الإلكتروني أولاً.'
              : 'No active recovery session. Please open the recovery link from email first.';
        });
        return;
      }

      // ✅ تحديث كلمة المرور ضمن Recovery session
      await sb.auth.updateUser(UserAttributes(password: a));

      // ✅ تسجيل أمني: نجاح تغيير كلمة المرور
      await _logSecurity(
        action: 'password_changed_via_recovery',
        success: true,
      );

      if (!mounted) return;

      setState(() {
        _busy = false;
        _ok = _isAr
            ? 'تم تغيير كلمة المرور بنجاح. يمكنك تسجيل الدخول الآن.'
            : 'Password changed successfully. You can sign in now.';
      });

      // ✅ بعد تغيير كلمة المرور -> تسجيل الخروج ثم العودة لتسجيل الدخول
      await Future.delayed(const Duration(milliseconds: 500));
      await sb.auth.signOut();

      // ✅ انتهى مسار الاستعادة
      recoveryFlowNotifier.value = false;

      // ✅ امسح username المخزن لمسار الاستعادة
      await _clearRecoveryUsername();

      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/', (r) => false);
    } on AuthException catch (e) {
      await _logSecurity(
        action: 'password_change_failed_via_recovery',
        success: false,
        details: e.message,
      );
      setState(() {
        _busy = false;
        _err = _isAr
            ? 'خطأ في المصادقة: ${e.message}'
            : 'Authentication error: ${e.message}';
      });
    } catch (e) {
      await _logSecurity(
        action: 'password_change_failed_via_recovery',
        success: false,
        details: e.toString(),
      );
      setState(() {
        _busy = false;
        _err = _isAr ? 'حدث خطأ غير متوقع: $e' : 'Unexpected error occurred: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  final allowScroll = h < 760;
                  final maxWidth = (w >= 700) ? 560.0 : 600.0;

                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: _card(maxWidth: maxWidth, allowScroll: allowScroll),
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

  Widget _card({required double maxWidth, required bool allowScroll}) {
    final cardColor = _isLight
        ? Colors.white.withOpacity(0.98)
        : const Color(0xFF171A22).withOpacity(0.98);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(),
        const SizedBox(height: 20),
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: _bankColor.withOpacity(0.1),
            border: Border.all(
              color: _bankColor.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              'assets/logo.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, __, ___) => Center(
                child: Icon(
                  Icons.lock_reset_rounded,
                  size: 64,
                  color: _bankColor,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _hasRecoverySession
              ? (_isAr ? 'تعيين كلمة مرور جديدة' : 'Set a new password')
              : (_isAr ? 'استعادة كلمة المرور' : 'Reset password'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: _textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _hasRecoverySession
              ? (_isAr
                  ? 'الرجاء إدخال كلمة مرور جديدة لحسابك'
                  : 'Please enter a new password for your account')
              : (_isAr
                  ? 'سيتم إرسال رابط استعادة إلى البريد الإلكتروني المرتبط برقم الهوية/الإقامة'
                  : 'A recovery link will be sent to the email linked to your ID/Iqama'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: _textSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
        if (_hasRecoverySession) ...[
          _buildNewPasswordField(
            controller: _p1,
            focusNode: _p1Focus,
            label: _isAr ? 'كلمة المرور الجديدة' : 'New password',
            obscure: _obscure1,
            onToggle: () => setState(() => _obscure1 = !_obscure1),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _p2Focus.requestFocus(),
          ),
          const SizedBox(height: 12),
          _buildNewPasswordField(
            controller: _p2,
            focusNode: _p2Focus,
            label: _isAr ? 'تأكيد كلمة المرور' : 'Confirm password',
            obscure: _obscure2,
            onToggle: () => setState(() => _obscure2 = !_obscure2),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveNewPassword(),
          ),
        ] else ...[
          _buildUsernameField(),
        ],
        const SizedBox(height: 16),
        if (_err != null) _messageBox(text: _err!, isError: true),
        if (_ok != null) _messageBox(text: _ok!, isError: false),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _bankColor,
              foregroundColor: Colors.white,
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _busy
                ? null
                : (_hasRecoverySession ? _saveNewPassword : _requestResetByUsername),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _busy
                  ? Row(
                      key: const ValueKey('busy'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _isAr ? 'جاري المعالجة...' : 'Processing...',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      _hasRecoverySession
                          ? (_isAr ? 'حفظ كلمة المرور' : 'Save password')
                          : (_isAr ? 'إرسال رابط الاستعادة' : 'Send recovery link'),
                      key: const ValueKey('text'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      // خروج احترازي لو كان في Recovery Session
                      final sb = Supabase.instance.client;
                      await sb.auth.signOut();
                      recoveryFlowNotifier.value = false;
                      await _clearRecoveryUsername();
                      if (!mounted) return;
                      Navigator.pushNamedAndRemoveUntil(context, '/', (r) => false);
                    },
              child: Text(
                _isAr ? 'العودة لتسجيل الدخول' : 'Back to sign in',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _bankColor,
                  fontSize: 14,
                ),
              ),
            ),
            if (!_hasRecoverySession)
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() {
                          _err = null;
                          _ok = null;
                        });
                        await _bootstrapRecoveryFromUrlIfWeb();
                        await _syncRecoverySessionState();
                        await _loadRecoveryUsername();
                        if (!mounted) return;
                        setState(() {});
                        if (_hasRecoverySession) {
                          _p1Focus.requestFocus();
                        }
                      },
                child: Text(
                  _isAr ? 'تحديث' : 'Refresh',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: _textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
          ],
        ),
      ],
    );

    final child = Padding(
      padding: const EdgeInsets.all(20),
      child: allowScroll
          ? SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: content,
            )
          : content,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Card(
        elevation: 8,
        shadowColor: Colors.black.withOpacity(0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: cardColor,
        child: child,
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isLight ? const Color(0xFFF8FAFC) : const Color(0xFF0F1425),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isLight ? const Color(0xFFE2E8F0) : const Color(0xFF2A355A),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _bankColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.lock_rounded,
              color: _bankColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isAr ? 'أمان الحساب' : 'Account Security',
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isAr ? 'إدارة كلمة المرور' : 'Password Management',
                  style: TextStyle(
                    color: _textSecondary,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageBox({required String text, required bool isError}) {
    final bgColor = isError ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4);
    final borderColor =
        isError ? const Color(0xFFFECACA) : const Color(0xFFBBF7D0);
    final textColor =
        isError ? const Color(0xFF991B1B) : const Color(0xFF166534);
    final iconColor =
        isError ? const Color(0xFFDC2626) : const Color(0xFF16A34A);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
            color: iconColor,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsernameField() {
    return TextField(
      controller: _usernameCtrl,
      focusNode: _usernameFocus,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      maxLength: 10,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _requestResetByUsername(),
      style: TextStyle(
        color: _textPrimary,
        fontWeight: FontWeight.w900,
        fontSize: 15,
      ),
      decoration: InputDecoration(
        hintText:
            _isAr ? 'رقم الهوية/الإقامة (10 أرقام)' : 'Saudi ID/Iqama (10 digits)',
        hintStyle: TextStyle(
          color: _hintColor,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
        counterText: '',
        prefixIcon: Icon(Icons.badge_outlined, color: _iconColor, size: 22),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _fieldBorder, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _bankColor, width: 2.0),
        ),
        fillColor: _fieldFill,
        filled: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _buildNewPasswordField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required bool obscure,
    required VoidCallback onToggle,
    required TextInputAction textInputAction,
    required ValueChanged<String> onSubmitted,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      enableSuggestions: false,
      autocorrect: false,
      style: TextStyle(
        color: _textPrimary,
        fontWeight: FontWeight.w900,
        fontSize: 15,
      ),
      decoration: InputDecoration(
        hintText: label,
        hintStyle: TextStyle(
          color: _hintColor,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
        prefixIcon: Icon(Icons.lock_outline, color: _iconColor, size: 22),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(
            obscure ? Icons.visibility : Icons.visibility_off,
            color: _iconColor,
            size: 22,
          ),
          tooltip:
              obscure ? (_isAr ? 'إظهار' : 'Show') : (_isAr ? 'إخفاء' : 'Hide'),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _fieldBorder, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _bankColor, width: 2.0),
        ),
        fillColor: _fieldFill,
        filled: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}

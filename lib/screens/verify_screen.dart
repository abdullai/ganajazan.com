// lib/screens/verify_screen.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aqar_user/l10n/app_localizations.dart';

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  static const Color _bankColor = Color(0xFF0F766E);

  static const int _otpLen = 4;
  static const int _maxSeconds = 60;
  static const int _maxAttempts = 3;

  final List<TextEditingController> _controllers =
      List.generate(_otpLen, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(_otpLen, (_) => FocusNode());

  Timer? _timer;
  int _secondsLeft = _maxSeconds;

  int _attemptsLeft = _maxAttempts;
  bool _error = false;
  bool _locked = false;

  // Dev OTP
  String _expectedCode = '';

  // ✅ navigation
  String _nextRoute = '/login';
  Map<String, dynamic> _nextArgs = <String, dynamic>{};

  // info
  String _fullName = '';
  DateTime? _lastLogin;
  String _username = ''; // ✅ رقم الهوية/الإقامة
  String _deviceId = '';

  bool _argsRead = false;

  bool get _isAr {
    try {
      final t = AppLocalizations.of(context);
      if (t == null) return Directionality.of(context) == TextDirection.rtl;
      return t.localeName.toLowerCase().startsWith('ar');
    } catch (_) {
      return Directionality.of(context) == TextDirection.rtl;
    }
  }

  @override
  void initState() {
    super.initState();
    _startTimer();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _readArgsOnce();
      _focusStart();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _controllers) c.dispose();
    for (final f in _focusNodes) f.dispose();
    super.dispose();
  }

  String _genOtp() {
    final r = math.Random();
    final n = r.nextInt(10000); // 0..9999
    return n.toString().padLeft(4, '0');
  }

  void _readArgsOnce() {
    if (_argsRead) return;
    _argsRead = true;

    final rawArgs = ModalRoute.of(context)?.settings.arguments;
    final args = (rawArgs is Map) ? rawArgs : <String, dynamic>{};

    setState(() {
      final fromArgs = (args['code'] as String?)?.trim();
      _expectedCode =
          (fromArgs != null && fromArgs.isNotEmpty) ? fromArgs : _genOtp();

      _nextRoute = (args['next'] as String?) ?? '/login';

      // ✅ اختياري: تمرير args جاهزة للشاشة التالية (مثل userId/lang)
      final na = args['nextArgs'];
      _nextArgs = (na is Map) ? Map<String, dynamic>.from(na) : <String, dynamic>{};

      _fullName = (args['fullName'] as String?) ?? '';
      _lastLogin = args['lastLogin'] as DateTime?;
      _username = (args['username'] as String?) ?? ''; // ✅ رقم الهوية/الإقامة
      _deviceId = (args['deviceId'] as String?) ?? '';
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _secondsLeft = _maxSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_secondsLeft <= 0) {
        t.cancel();
        setState(() {});
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  void _focusStart() => _focusNodes[0].requestFocus();

  String _enteredCode() {
    final b = StringBuffer();
    for (int i = 0; i < _otpLen; i++) {
      b.write(_controllers[i].text);
    }
    return b.toString();
  }

  int _filledCount() {
    int c = 0;
    for (int i = 0; i < _otpLen; i++) {
      if (_controllers[i].text.isNotEmpty) c++;
    }
    return c;
  }

  void _clear() {
    for (final c in _controllers) {
      c.clear();
    }
    setState(() => _error = false);
    _focusStart();
  }

  Future<void> _goToLogin() async {
    _timer?.cancel();
    if (!mounted) return;

    try {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
      return;
    } catch (_) {
      Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  void _submit() {
    if (_locked) return;

    final entered = _enteredCode();
    if (entered.length != _otpLen || entered != _expectedCode) {
      setState(() {
        _attemptsLeft--;
        _error = true;
      });

      HapticFeedback.vibrate();

      if (_attemptsLeft <= 0) {
        _locked = true;
        _timer?.cancel();
        _goToLogin();
      }
      return;
    }

    _timer?.cancel();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    // ✅ أهم تعديل: تمرير username (رقم الهوية/الإقامة) للشاشة التالية
    final args = <String, dynamic>{
      ..._nextArgs,
      'username': _username,
      'deviceId': _deviceId,
      'fullName': _fullName,
      'lastLogin': _lastLogin,
    };

    Navigator.pushReplacementNamed(context, _nextRoute, arguments: args);
  }

  // ✅ لصق صحيح: يمسح القديم ثم يعبّي 0..3 دائماً
  void _applyPastedDigits(String text) {
    final only = text.replaceAll(RegExp(r'\D'), '');
    if (only.isEmpty) return;

    final take = only.length >= _otpLen ? only.substring(0, _otpLen) : only;

    for (final c in _controllers) {
      c.clear();
    }

    for (int i = 0; i < take.length; i++) {
      _controllers[i].text = take[i];
      _controllers[i].selection = const TextSelection.collapsed(offset: 1);
    }

    if (take.length == _otpLen) {
      _submit();
      return;
    }

    _focusNodes[take.length].requestFocus();
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (text.isEmpty) return;
      _applyPastedDigits(text);
    } catch (_) {}
  }

  void _onOtpChanged({required int index, required String value}) {
    if (_error) setState(() => _error = false);

    final digitsOnly = value.replaceAll(RegExp(r'\D'), '');

    if (digitsOnly.length >= 2) {
      _applyPastedDigits(digitsOnly);
      return;
    }

    if (digitsOnly.isEmpty) {
      if (index > 0) {
        _focusNodes[index - 1].requestFocus();
        _controllers[index - 1].selection = TextSelection.collapsed(
          offset: _controllers[index - 1].text.length,
        );
      }
      return;
    }

    if (_controllers[index].text != digitsOnly) {
      _controllers[index].text = digitsOnly;
      _controllers[index].selection = const TextSelection.collapsed(offset: 1);
    }

    final next = index + 1;
    if (next < _otpLen) {
      _focusNodes[next].requestFocus();
    } else {
      if (_filledCount() == _otpLen) _submit();
    }
  }

  void _onOtpBackspace({required int index, required KeyEvent event}) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey != LogicalKeyboardKey.backspace) return;

    if (_controllers[index].text.isNotEmpty) return;

    final prev = index - 1;
    if (prev < 0) return;

    _focusNodes[prev].requestFocus();
    _controllers[prev].selection = TextSelection.collapsed(
      offset: _controllers[prev].text.length,
    );
  }

  Future<void> _resendCode() async {
    setState(() {
      _attemptsLeft = _maxAttempts;
      _error = false;
      _locked = false;
      _expectedCode = _genOtp();
    });

    for (final c in _controllers) c.clear();
    _focusStart();
    _startTimer();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(_isAr ? 'تم إرسال رمز جديد' : 'New code sent'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatLastLogin() {
    final v = _lastLogin;
    if (v == null) return _isAr ? 'غير متوفر' : 'N/A';
    final mm = v.minute.toString().padLeft(2, '0');
    return '${v.year}/${v.month}/${v.day}  ${v.hour}:$mm';
  }

  Widget _otpBox({required int index, required bool isDark}) {
    return SizedBox(
      width: 58,
      height: 64,
      child: Focus(
        focusNode: _focusNodes[index],
        onKeyEvent: (_, event) {
          _onOtpBackspace(index: index, event: event);
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: _controllers[index],
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.number,
          maxLength: 1,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(1),
          ],
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: isDark ? Colors.white : const Color(0xFF0B1220),
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor:
                isDark ? Colors.white.withOpacity(0.08) : const Color(0xFFF8FAFC),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: _error
                    ? Colors.red
                    : (isDark ? Colors.white24 : const Color(0xFFE5E7EB)),
                width: 1.2,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: _error ? Colors.red : _bankColor,
                width: 1.8,
              ),
            ),
          ),
          onChanged: (v) => _onOtpChanged(index: index, value: v),
          contextMenuBuilder: (context, editableTextState) {
            final anchors = editableTextState.contextMenuAnchors;
            return AdaptiveTextSelectionToolbar(
              anchors: anchors,
              children: [
                TextSelectionToolbarTextButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    editableTextState.hideToolbar();
                    _pasteFromClipboard();
                  },
                  child: Text(_isAr ? 'لصق' : 'Paste'),
                ),
              ],
            );
          },
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

    final now = DateTime.now();
    final nowMm = now.minute.toString().padLeft(2, '0');
    final nowTxt = '${now.year}/${now.month}/${now.day}  ${now.hour}:$nowMm';

    final showResend = _secondsLeft <= 0;

    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyV):
            const PasteIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyV):
            const PasteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PasteIntent: CallbackAction<PasteIntent>(
            onInvoke: (intent) {
              _pasteFromClipboard();
              return null;
            },
          ),
        },
        child: Directionality(
          textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
          child: PopScope(
            canPop: false,
            onPopInvoked: (_) => _goToLogin(),
            child: Scaffold(
              backgroundColor: bg,
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Card(
                        color: card,
                        elevation: 10,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: _bankColor.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Icon(
                                      Icons.verified_user_rounded,
                                      color: _bankColor,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _isAr ? 'مرحباً' : 'Welcome',
                                          style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w900,
                                            color: titleColor,
                                          ),
                                        ),
                                        if (_fullName.isNotEmpty)
                                          Text(
                                            _fullName,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: subColor,
                                            ),
                                          ),
                                        if (_username.isNotEmpty)
                                          Text(
                                            _isAr
                                                ? 'المستخدم: $_username'
                                                : 'User: $_username',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: subColor,
                                              fontSize: 12.5,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Icon(Icons.schedule_rounded,
                                      size: 18, color: subColor),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      nowTxt,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: subColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.login_rounded,
                                      size: 18, color: subColor),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _isAr
                                          ? 'آخر تسجيل دخول ناجح: ${_formatLastLogin()}'
                                          : 'Last successful login: ${_formatLastLogin()}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: subColor,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),

                              // DEV OTP
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: _bankColor.withOpacity(0.10),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: _bankColor.withOpacity(0.25),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.code_rounded,
                                        color: _bankColor),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _isAr
                                            ? 'رمز التحقق (تطوير): $_expectedCode'
                                            : 'OTP (dev): $_expectedCode',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: titleColor,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        try {
                                          await Clipboard.setData(
                                            ClipboardData(text: _expectedCode),
                                          );
                                        } catch (_) {}
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            behavior: SnackBarBehavior.floating,
                                            content: Text(
                                                _isAr ? 'تم نسخ الرمز' : 'Copied'),
                                            duration: const Duration(milliseconds: 900),
                                          ),
                                        );
                                      },
                                      child: Text(_isAr ? 'نسخ' : 'Copy'),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 14),

                              Text(
                                t.verifyTitle,
                                style: TextStyle(
                                  fontSize: 18,
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
                                ),
                                textAlign: TextAlign.center,
                              ),

                              const SizedBox(height: 14),

                              Wrap(
                                alignment: WrapAlignment.center,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 10,
                                runSpacing: 6,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.timer_outlined,
                                          size: 18, color: subColor),
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
                                        ),
                                      ),
                                    ],
                                  ),
                                  TextButton.icon(
                                    onPressed: _pasteFromClipboard,
                                    icon: const Icon(Icons.content_paste_outlined,
                                        size: 18),
                                    label: Text(
                                      _isAr ? 'لصق' : 'Paste',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900),
                                    ),
                                  ),
                                  if (showResend)
                                    TextButton.icon(
                                      onPressed: _resendCode,
                                      icon: const Icon(Icons.refresh),
                                      label: Text(
                                        _isAr
                                            ? 'إعادة إرسال رمز جديد'
                                            : 'Resend new code',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900),
                                      ),
                                    ),
                                ],
                              ),

                              const SizedBox(height: 10),

                              Directionality(
                                textDirection: TextDirection.ltr,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(_otpLen, (i) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5),
                                      child: _otpBox(index: i, isDark: isDark),
                                    );
                                  }),
                                ),
                              ),

                              if (_error) ...[
                                const SizedBox(height: 12),
                                Text(
                                  t.invalidCode,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w900,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _isAr
                                      ? 'المحاولات المتبقية: $_attemptsLeft'
                                      : 'Attempts left: $_attemptsLeft',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w900),
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
                                  onPressed: _submit,
                                  child: Text(
                                    t.confirm,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(height: 10),

                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: _clear,
                                      child: Text(
                                        t.clear,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextButton(
                                      onPressed: _goToLogin,
                                      child: Text(
                                        _isAr
                                            ? 'العودة لتسجيل الدخول'
                                            : 'Back to Login',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900),
                                      ),
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 6),

                              TextButton(
                                onPressed: () =>
                                    Navigator.pushNamed(context, '/forgot'),
                                child: Text(
                                  t.recover,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w900),
                                ),
                              ),

                              if (kIsWeb) ...[
                                const SizedBox(height: 6),
                                Text(
                                  _isAr
                                      ? 'على الويب: استخدم زر "لصق" أو Ctrl+V.'
                                      : 'On web: use Paste button or Ctrl+V.',
                                  style: TextStyle(
                                    color: subColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PasteIntent extends Intent {
  const PasteIntent();
}

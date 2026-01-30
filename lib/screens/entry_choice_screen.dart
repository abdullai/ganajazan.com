// lib/screens/entry_choice_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../main.dart'; // langNotifier
import 'login_screen.dart';
import 'user_dashboard.dart';
import 'fast_login_screen.dart'; // إن كانت موجودة عندك

class EntryChoiceScreen extends StatefulWidget {
  const EntryChoiceScreen({super.key});

  static const Color primary = Color(0xFF0F766E);

  @override
  State<EntryChoiceScreen> createState() => _EntryChoiceScreenState();
}

class _EntryChoiceScreenState extends State<EntryChoiceScreen> {
  static const String _kPrefEntryMode = 'entry_mode'; // 'guest' | 'user'
  static const String _kPrefFastLoginEnabled = 'fast_login_enabled'; // true/false

  bool _checking = true;

  bool get _isEnglish => langNotifier.value.toLowerCase().startsWith('en');

  Map<String, String> _t(String lang) {
    final ar = <String, String>{
      'app': 'عقار موثوق',
      'title': 'اختر طريقة الدخول',
      'subtitle':
          'في الويب يجب اختيار طريقة الدخول في كل مرة (مستخدم/ضيف).',
      'user': 'الدخول كمستخدم',
      'guest': 'الدخول كضيف',
      'hint':
          'الضيف يستطيع التصفح فقط. عند محاولة استخدام ميزة تتطلب حساب سيتم عرض تنبيه مع خيار تسجيل الدخول.',
      'signedAs': 'مسجل دخول كـ:',
      'continueAsUser': 'متابعة كمستخدم',
    };
    final en = <String, String>{
      'app': 'Aqar Mowthooq',
      'title': 'Choose how to continue',
      'subtitle':
          'On Web, you must choose how to enter every time (User/Guest).',
      'user': 'Sign in',
      'guest': 'Continue as guest',
      'hint':
          'Guest can browse only. When you try a feature that requires an account, you will be prompted to sign in.',
      'signedAs': 'Signed in as:',
      'continueAsUser': 'Continue as user',
    };
    return (lang.toLowerCase().startsWith('en')) ? en : ar;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // شرطك: على الويب لابد المرور على هذه الصفحة دائماً
    // حتى لو كان فيه جلسة Supabase محفوظة وحتى لو تم إغلاق وفتح التطبيق.
    if (kIsWeb) {
      if (mounted) setState(() => _checking = false);
      return;
    }

    // على الجوال/الديسكتوب: نفس منطقنا السابق
    final u = Supabase.instance.client.auth.currentUser;
    if (u != null && mounted) {
      _goDashboard();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final lastMode = prefs.getString(_kPrefEntryMode);

    // إذا آخر اختيار "ضيف" -> لا نسمح بأي تخطي
    if (lastMode == 'guest') {
      if (mounted) setState(() => _checking = false);
      return;
    }

    // إذا الدخول السريع مفعّل -> توجيه مباشر للدخول السريع
    final fastEnabled = prefs.getBool(_kPrefFastLoginEnabled) ?? false;
    if (fastEnabled && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const FastLoginScreen()),
      );
      return;
    }

    if (mounted) setState(() => _checking = false);
  }

  Future<void> _setEntryMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefEntryMode, mode);
  }

  void _goDashboard() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => UserDashboard(
          key: const ValueKey('dashboard'),
          lang: langNotifier.value,
        ),
      ),
    );
  }

  Future<void> _goUser() async {
    await _setEntryMode('user');

    final u = Supabase.instance.client.auth.currentUser;

    // إذا على الويب وكان مسجل دخول بالفعل -> يدخل للداشبورد بعد الضغط
    if (u != null) {
      if (!mounted) return;
      _goDashboard();
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _goGuest() async {
    // حفظ اختيار الضيف حتى لا يتم تجاوزه لاحقاً (خصوصاً على الجوال)
    await _setEntryMode('guest');

    if (!mounted) return;
    _goDashboard();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final tr = _t(langNotifier.value);

    final bgTop = isDark ? const Color(0xFF0B1220) : const Color(0xFFF4FAF9);
    final bgBottom = isDark ? const Color(0xFF070A10) : const Color(0xFFF7F7F7);

    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email ?? '';

    return Directionality(
      textDirection: _isEnglish ? TextDirection.ltr : TextDirection.rtl,
      child: Scaffold(
        backgroundColor: isDark ? Colors.black : Colors.white,
        body: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [bgTop, bgBottom],
              ),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _checking
                        ? Card(
                            elevation: 0,
                            color: cs.surface.withOpacity(0.85),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(22),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  SizedBox(width: 12),
                                  Text('...'),
                                ],
                              ),
                            ),
                          )
                        : Card(
                            elevation: 0,
                            color:
                                cs.surface.withOpacity(isDark ? 0.88 : 0.92),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // شعار التطبيق (حسب مسارك الفعلي)
                                  Container(
                                    width: 92,
                                    height: 92,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: EntryChoiceScreen.primary
                                            .withOpacity(0.18),
                                      ),
                                      color: EntryChoiceScreen.primary
                                          .withOpacity(0.06),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Image.asset(
                                      'assets/logo.png',
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) {
                                        return const Icon(
                                          Icons.home_work_outlined,
                                          size: 46,
                                          color: EntryChoiceScreen.primary,
                                        );
                                      },
                                    ),
                                  ),

                                  const SizedBox(height: 14),
                                  Text(
                                    tr['app']!,
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      color: cs.onSurface,
                                      letterSpacing: 0.2,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    tr['title']!,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: cs.onSurface,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    tr['subtitle']!,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),

                                  // على الويب: لو مسجل دخول بالفعل، نظهر معلومة + زر "متابعة كمستخدم"
                                  if (kIsWeb && user != null) ...[
                                    const SizedBox(height: 14),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: EntryChoiceScreen.primary
                                            .withOpacity(0.08),
                                        borderRadius:
                                            BorderRadius.circular(14),
                                        border: Border.all(
                                          color: EntryChoiceScreen.primary
                                              .withOpacity(0.18),
                                        ),
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Icon(
                                            Icons.verified_user_outlined,
                                            size: 18,
                                            color: EntryChoiceScreen.primary,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  tr['signedAs']!,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight.w800,
                                                    color: cs.onSurface,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  email.isEmpty ? '-' : email,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        cs.onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],

                                  const SizedBox(height: 18),

                                  // زر مستخدم: إذا مسجل دخول بالفعل يدخل للداشبورد، وإلا يذهب للّوجن
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            EntryChoiceScreen.primary,
                                        minimumSize:
                                            const Size.fromHeight(50),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                      ),
                                      onPressed: _goUser,
                                      icon: Icon(
                                        (kIsWeb && user != null)
                                            ? Icons.arrow_forward
                                            : Icons.login,
                                      ),
                                      label: Text(
                                        (kIsWeb && user != null)
                                            ? tr['continueAsUser']!
                                            : tr['user']!,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),

                                  // زر ضيف
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        minimumSize:
                                            const Size.fromHeight(50),
                                        side: BorderSide(
                                          color: EntryChoiceScreen.primary
                                              .withOpacity(0.55),
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                      ),
                                      onPressed: _goGuest,
                                      icon: const Icon(Icons.person_outline),
                                      label: Text(
                                        tr['guest']!,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 14),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: EntryChoiceScreen.primary
                                          .withOpacity(0.08),
                                      borderRadius:
                                          BorderRadius.circular(14),
                                      border: Border.all(
                                        color: EntryChoiceScreen.primary
                                            .withOpacity(0.18),
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          Icons.info_outline,
                                          size: 18,
                                          color: EntryChoiceScreen.primary,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            tr['hint']!,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: cs.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
    );
  }
}

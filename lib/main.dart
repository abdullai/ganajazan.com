// lib/main.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Provider
import 'package:provider/provider.dart';

// ✅ Session
import 'core/session/app_session.dart';

// ✅ L10n
import 'package:aqar_user/l10n/app_localizations.dart';

import 'shared/core/supabase_config.dart';
import 'screens/login_screen.dart';
import 'screens/user_dashboard.dart';
import 'screens/verify_screen.dart';
import 'screens/settings_page.dart';
import 'screens/reset_password_screen.dart';
import 'screens/gate_screen.dart';
import 'screens/fast_login_screen.dart';
import 'screens/password_setup.dart';
import 'screens/entry_choice_screen.dart';

import 'services/inactivity_service.dart';
import 'theme.dart';

final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

// ✅ مصدر واحد للغة في كل التطبيق
final ValueNotifier<String> langNotifier = ValueNotifier<String>('ar');

// ✅ فلاغ عالمي يمنع أي Redirect للداشبورد أثناء Recovery
final ValueNotifier<bool> recoveryFlowNotifier = ValueNotifier<bool>(false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final savedLang = prefs.getString('language') ?? 'ar';
  final savedTheme = prefs.getString('themeMode') ?? ThemeMode.system.name;

  langNotifier.value = (savedLang == 'en') ? 'en' : 'ar';
  themeModeNotifier.value = ThemeMode.values.firstWhere(
    (e) => e.name == savedTheme,
    orElse: () => ThemeMode.system,
  );

  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.supabaseAnonKey,
  );

  // ✅ عند فتح رابط Recovery على الويب (قبل listener)
  recoveryFlowNotifier.value = _isRecoveryUrlOrCode();

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppSession(),
      child: const AqarUserApp(),
    ),
  );
}

class AqarUserApp extends StatefulWidget {
  const AqarUserApp({super.key});

  @override
  State<AqarUserApp> createState() => _AqarUserAppState();
}

class _AqarUserAppState extends State<AqarUserApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  StreamSubscription<AuthState>? _sub;

  late final InactivityService _inactivity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final Duration idle;
    final Duration countdown;

    if (kIsWeb) {
      idle = const Duration(minutes: 10);
      countdown = const Duration(minutes: 2);
    } else {
      idle = const Duration(minutes: 5);
      countdown = const Duration(minutes: 1);
    }

    _inactivity = InactivityService(
      navigatorKey: _navKey,
      idleBeforePrompt: idle,
      promptCountdown: countdown,
    );
    _inactivity.start();

    _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final event = data.event;

      if (event == AuthChangeEvent.passwordRecovery) {
        recoveryFlowNotifier.value = true;
        _navKey.currentState?.pushNamedAndRemoveUntil(
          '/resetPassword',
          (r) => false,
        );
        return;
      }

      if (event == AuthChangeEvent.signedOut) {
        recoveryFlowNotifier.value = false;

        final ctx = _navKey.currentContext;
        if (ctx != null) {
          ctx.read<AppSession>().logout();
        }

        // ✅ بعد تسجيل الخروج:
        // - على الويب: لازم يرجع لشاشة اختيار (مستخدم/ضيف)
        // - على غير الويب: يرجع للـ Gate
        _navKey.currentState?.pushNamedAndRemoveUntil(
          kIsWeb ? '/entryChoice' : '/gate',
          (r) => false,
        );
        return;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isRecoveryUrlOrCode()) {
        recoveryFlowNotifier.value = true;
        _navKey.currentState?.pushNamedAndRemoveUntil(
          '/resetPassword',
          (r) => false,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _inactivity.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (recoveryFlowNotifier.value == true) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _inactivity.lockNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<String>(
          valueListenable: langNotifier,
          builder: (context, lang, __) {
            final isRtl = (lang == 'ar');

            return MaterialApp(
              navigatorKey: _navKey,
              debugShowCheckedModeBanner: false,

              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale(lang),

              onGenerateTitle: (context) =>
                  AppLocalizations.of(context)?.appTitle ?? 'Aqar User',

              theme: AppTheme.lightTheme,
              darkTheme: AppTheme.darkTheme,
              themeMode: mode,

              // ✅ نقطة البداية:
              // - Recovery: /resetPassword
              // - Web: /entryChoice (إجباري المرور عليها كل مرة)
              // - Others: /gate
              onGenerateInitialRoutes: (String initialRouteName) {
                final bool isRecovery = _isRecoveryUrlOrCode();

                final String startRoute = isRecovery
                    ? '/resetPassword'
                    : (kIsWeb ? '/entryChoice' : '/gate');

                final Widget startWidget = isRecovery
                    ? const ResetPasswordScreen()
                    : (kIsWeb
                        ? const EntryChoiceScreen()
                        : const GateScreen());

                return [
                  MaterialPageRoute(
                    settings: RouteSettings(name: startRoute),
                    builder: (_) => startWidget,
                  ),
                ];
              },

              builder: (context, child) {
                Widget wrapped = child ?? const SizedBox.shrink();

                wrapped = Focus(
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    _inactivity.userActivity();
                    return KeyEventResult.ignored;
                  },
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (_) => _inactivity.userActivity(),
                    onPointerMove: (_) => _inactivity.userActivity(),
                    onPointerSignal: (_) => _inactivity.userActivity(),
                    child: wrapped,
                  ),
                );

                return Directionality(
                  textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                  child: wrapped,
                );
              },

              routes: {
                // ✅ Gate
                '/gate': (context) => const GateScreen(),

                // ✅ اجعل / يطابق نقطة البداية المنطقية (خصوصاً لو تم استخدام routes مباشرة)
                '/': (context) => _isRecoveryUrlOrCode()
                    ? const ResetPasswordScreen()
                    : (kIsWeb ? const EntryChoiceScreen() : const GateScreen()),

                // ✅ شاشة اختيار دخول (مستخدم/ضيف)
                '/entryChoice': (context) => const EntryChoiceScreen(),

                // ✅ Auth flow
                '/login': (context) => const LoginScreen(),
                '/verify': (context) => const VerifyScreen(),
                '/resetPassword': (context) => const ResetPasswordScreen(),
                '/passwordSetup': (context) => const PasswordSetupScreen(),

                // ✅ Dashboard
                '/userDashboard': (context) => UserDashboard(
                      key: const ValueKey('dashboard'),
                      lang: lang,
                    ),

                // ✅ Settings
                '/settings': (context) => SettingsPage(lang: lang),

                // ✅ Fast Login
                '/fastLogin': (context) => const FastLoginScreen(),
              },
            );
          },
        );
      },
    );
  }
}

/// ✅ فحص: type=recovery أو وجود code (PKCE) أو access_token في fragment
bool _isRecoveryUrlOrCode() {
  if (!kIsWeb) return false;

  try {
    final uri = Uri.base;

    final qType = (uri.queryParameters['type'] ?? '').toLowerCase();
    if (qType == 'recovery') return true;

    if (uri.queryParameters.containsKey('code')) return true;

    final frag = uri.fragment;
    if (frag.isNotEmpty) {
      final fragParams = Uri.splitQueryString(frag);
      final fType = (fragParams['type'] ?? '').toLowerCase();
      if (fType == 'recovery') return true;

      if (fragParams.containsKey('access_token')) return true;
    }

    return false;
  } catch (_) {
    return false;
  }
}

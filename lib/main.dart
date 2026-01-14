// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ L10n
import 'package:aqar_user/l10n/app_localizations.dart';

import 'shared/core/supabase_config.dart';
import 'screens/login_screen.dart';
import 'screens/user_dashboard.dart';
import 'screens/verify_screen.dart';
import 'screens/settings_page.dart';
import 'screens/reset_password_screen.dart';
import 'theme.dart';

final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

// ✅ مصدر واحد للغة في كل التطبيق
final ValueNotifier<String> langNotifier = ValueNotifier<String>('ar');

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

  runApp(const AqarUserApp());
}

class AqarUserApp extends StatelessWidget {
  const AqarUserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // ✅ اعتمد على snapshot عند توفره، وإلا fallback على currentSession
        final session = snapshot.data?.session ??
            Supabase.instance.client.auth.currentSession;
        final isLoggedIn = session != null;

        return ValueListenableBuilder<ThemeMode>(
          valueListenable: themeModeNotifier,
          builder: (context, mode, _) {
            return ValueListenableBuilder<String>(
              valueListenable: langNotifier,
              builder: (context, lang, __) {
                final isRtl = (lang == 'ar');

                return MaterialApp(
                  debugShowCheckedModeBanner: false,

                  // ✅ L10n setup
                  localizationsDelegates: AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  locale: Locale(lang),

                  onGenerateTitle: (context) =>
                      AppLocalizations.of(context)?.appTitle ?? 'Aqar User',

                  theme: AppTheme.lightTheme,
                  darkTheme: AppTheme.darkTheme,
                  themeMode: mode,

                  // ✅ تثبيت اتجاه الواجهة حسب اللغة
                  builder: (context, child) {
                    return Directionality(
                      textDirection:
                          isRtl ? TextDirection.rtl : TextDirection.ltr,
                      child: child ?? const SizedBox.shrink(),
                    );
                  },

                  // ✅ إن وصل رابط recovery من Supabase (reset password) سيتم فتح الصفحة تلقائياً
                  initialRoute: _initialRouteForRecovery(),

                  routes: {
                    '/': (context) => isLoggedIn
                        ? UserDashboard(
                            key: const ValueKey('dashboard'),
                            lang: lang,
                          )
                        : const LoginScreen(),

                    '/verify': (context) => const VerifyScreen(),

                    '/userDashboard': (context) => UserDashboard(
                          key: const ValueKey('dashboard'),
                          lang: lang,
                        ),

                    '/settings': (context) => SettingsPage(lang: lang),

                    // ✅ Reset Password Screen
                    '/resetPassword': (context) => const ResetPasswordScreen(),
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// يقرأ رابط الويب الحالي:
  /// http://127.0.0.1:8000/#access_token=...&type=recovery
  /// لو type=recovery نفتح صفحة تغيير كلمة المرور مباشرة.
  String _initialRouteForRecovery() {
    try {
      final uri = Uri.base;

      // Supabase يضع القيم داخل الـ fragment بعد #
      final frag = uri.fragment; // access_token=...&type=recovery...
      if (frag.isEmpty) return '/';

      final params = Uri.splitQueryString(frag);
      final type = (params['type'] ?? '').toLowerCase();

      if (type == 'recovery') {
        return '/resetPassword';
      }
      return '/';
    } catch (_) {
      return '/';
    }
  }
}

// lib/screens/gate_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/fast_login_service.dart';

import 'fast_login_screen.dart';
import 'user_dashboard.dart';

class GateScreen extends StatefulWidget {
  const GateScreen({super.key});

  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final sb = Supabase.instance.client;

    // 1) إذا فيه جلسة Supabase فعلية => إما AppLock (FastLogin) أو دخول مباشر للداشبورد
    final hasSession = sb.auth.currentSession != null && sb.auth.currentUser != null;

    if (!mounted) return;

    if (hasSession) {
      // FastLogin عندك هو "قفل" على نفس الجلسة (ليس تسجيل دخول بدون جلسة)
      final hasFastLock = await FastLoginService.hasAnyLockEnabled();

      if (!mounted) return;

      if (hasFastLock) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const FastLoginScreen()),
        );
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const UserDashboard(
            key: ValueKey('dashboard'),
            lang: 'ar',
          ),
        ),
      );
      return;
    }

    // 2) لا توجد جلسة => Guest Mode
    // (لا تفتح FastLogin بدون جلسة لأنه عندك يعتمد على session أصلاً)
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => const UserDashboard(
          key: ValueKey('dashboard'),
          lang: 'ar',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

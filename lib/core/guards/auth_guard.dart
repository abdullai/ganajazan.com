import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../session/app_session.dart';
import '../../screens/login_screen.dart';

Future<bool> requireAuth(
  BuildContext context, {
  required String reason,
  VoidCallback? onAuthed,
}) async {
  final session = context.read<AppSession>();
  if (session.isLoggedIn) {
    onAuthed?.call();
    return true;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('تسجيل الدخول مطلوب'),
      content: Text(reason),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('تسجيل الدخول'),
        ),
      ],
    ),
  );

  if (go == true) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LoginScreen(),
      ),
    );
    if (context.mounted && context.read<AppSession>().isLoggedIn) {
      onAuthed?.call();
      return true;
    }
  }
  return false;
}

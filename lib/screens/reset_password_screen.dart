import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  bool _busy = false;
  String? _err;
  String? _ok;

  @override
  void initState() {
    super.initState();
    _bootstrapRecoveryFromUrl();
  }

  Future<void> _bootstrapRecoveryFromUrl() async {
    final sb = Supabase.instance.client;

    // لو الجلسة موجودة أصلاً لا تسوي شيء
    if (sb.auth.currentSession != null) return;

    try {
      final uri = Uri.base;

      // لو الرابط فيه خطأ (مثل otp_expired) أظهره مباشرة
      if (uri.fragment.contains('error=') || uri.queryParameters.containsKey('error')) {
        // مثال: #error=access_denied&error_code=otp_expired&error_description=...
        final frag = uri.fragment;
        if (frag.contains('otp_expired')) {
          setState(() {
            _err = 'رابط الاستعادة منتهي أو تم استخدامه. أعد طلب استعادة كلمة المرور مرة أخرى.';
          });
          return;
        }
      }

      // ✅ الأهم: تحويل بيانات الرابط إلى Session (خصوصًا في Flutter Web)
      // هذه الدالة تتعامل مع access_token/refresh_token الموجودة في الـ fragment أو query حسب نوع التدفق
      await sb.auth.getSessionFromUrl(uri);

      if (sb.auth.currentSession == null) {
        setState(() {
          _err = 'لا توجد جلسة استعادة. افتح أحدث رابط في البريد (type=recovery) بدون إعادة تحميل الصفحة.';
        });
      }
    } catch (e) {
      setState(() {
        _err = 'تعذر تفعيل جلسة الاستعادة من الرابط: $e';
      });
    }
  }

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
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
        _err = 'اكتب كلمة المرور مرتين';
      });
      return;
    }
    if (a != b) {
      setState(() {
        _busy = false;
        _err = 'كلمتا المرور غير متطابقتين';
      });
      return;
    }
    if (a.length < 8) {
      setState(() {
        _busy = false;
        _err = 'كلمة المرور يجب أن تكون 8 أحرف على الأقل';
      });
      return;
    }

    try {
      final sb = Supabase.instance.client;

      if (sb.auth.currentSession == null) {
        setState(() {
          _busy = false;
          _err = 'لا توجد جلسة. افتح رابط الاستعادة من البريد (type=recovery) أولاً.';
        });
        return;
      }

      await sb.auth.updateUser(
        UserAttributes(password: a),
      );

      setState(() {
        _busy = false;
        _ok = 'تم تغيير كلمة المرور بنجاح';
      });

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/');
    } on AuthException catch (e) {
      setState(() {
        _busy = false;
        _err = e.message;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _err = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset Password')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _p1,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _p2,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            const SizedBox(height: 14),
            if (_err != null)
              Text(
                _err!,
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            if (_ok != null)
              Text(
                _ok!,
                style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save password'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:aqar_user/services/auth_service.dart';

class ForgotScreen extends StatefulWidget {
  const ForgotScreen({super.key});

  @override
  State<ForgotScreen> createState() => _ForgotScreenState();
}

class _ForgotScreenState extends State<ForgotScreen> {
  final usernameController = TextEditingController();

  String msg = '';
  bool isError = false;
  bool isLoading = false;

  @override
  void dispose() {
    usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ✅ هذه الشاشة أصبحت "طلب رابط استعادة كلمة المرور" عبر Supabase Auth
    // - توحيد username (هوية/إقامة 10 أرقام)
    // - استدعاء RPC get_status_by_username ضمن AuthService.login / sendResetPasswordEmail
    // - تسجيل الأحداث الأمنية ضمن AuthService (password_recovery_sent / password_recovery_failed / login_blocked ...)

    return Scaffold(
      appBar: AppBar(
        title: const Text('استعادة الحساب'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            Text(
              'استعادة الحساب',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).primaryColor,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'أدخل رقم الهوية/الإقامة وسيتم إرسال رابط لإعادة تعيين كلمة المرور إلى بريدك المرتبط بالحساب.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 30),

            TextField(
              controller: usernameController,
              keyboardType: TextInputType.number,
              maxLength: 10,
              decoration: const InputDecoration(
                labelText: 'رقم الهوية / الإقامة',
                hintText: 'أدخل 10 أرقام',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
                counterText: '',
              ),
              onChanged: (v) {
                // ✅ توحيد الأرقام العربية/الفارسية تلقائياً
                final normalized = AuthService.normalizeNumbers(v);
                if (normalized != v) {
                  final sel = usernameController.selection;
                  usernameController.value = TextEditingValue(
                    text: normalized,
                    selection: sel,
                  );
                }
              },
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: isLoading ? null : _handleSendLink,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'إرسال رابط الاستعادة',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 10),

            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('العودة لتسجيل الدخول'),
            ),

            const SizedBox(height: 20),
            if (msg.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isError ? Colors.red.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isError ? Colors.red.shade100 : Colors.green.shade100,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isError ? Icons.error_outline : Icons.check_circle,
                      color: isError ? Colors.red : Colors.green,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        msg,
                        style: TextStyle(
                          color: isError ? Colors.red : Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
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

  Future<void> _handleSendLink() async {
    final username = AuthService.normalizeNumbers(usernameController.text).trim();

    if (username.isEmpty) {
      setState(() {
        msg = 'الرجاء إدخال رقم الهوية/الإقامة';
        isError = true;
      });
      return;
    }

    if (username.length != 10) {
      setState(() {
        msg = 'رقم الهوية يجب أن يكون 10 أرقام';
        isError = true;
      });
      return;
    }

    if (!RegExp(r'^\d{10}$').hasMatch(username)) {
      setState(() {
        msg = 'رقم الهوية يجب أن يكون أرقام فقط';
        isError = true;
      });
      return;
    }

    setState(() {
      isLoading = true;
      msg = '';
      isError = false;
    });

    // ✅ ملاحظة مهمة:
    // redirectTo يجب أن يطابق إعدادات Supabase Auth (Redirect URLs).
    // إذا عندك Web: http://127.0.0.1:8000/ أو دومين الإنتاج
    // وإذا عندك Deep Link للتطبيق (aqar://...) ضعه هنا لاحقاً.
    final res = await AuthService.sendResetPasswordEmail(
      username: username,
      lang: 'ar',
      redirectTo: null, // اتركها null الآن إذا إعداداتك تعتمد الافتراضي
    );

    setState(() {
      isLoading = false;
      if (res.ok) {
        msg = res.message.isEmpty
            ? 'تم إرسال رابط إعادة تعيين كلمة المرور إلى بريدك.'
            : res.message;
        isError = false;
      } else {
        msg = res.message.isEmpty ? 'تعذر إرسال رابط الاستعادة.' : res.message;
        isError = true;
      }
    });
  }
}

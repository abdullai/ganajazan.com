import 'package:flutter/material.dart';
import 'package:aqar_user/services/auth_service.dart';

class ForgotScreen extends StatefulWidget {
  const ForgotScreen({super.key});

  @override
  State<ForgotScreen> createState() => _ForgotScreenState();
}

class _ForgotScreenState extends State<ForgotScreen> {
  final usernameController = TextEditingController();
  final codeController = TextEditingController();
  final newPasswordController = TextEditingController();

  String msg = '';
  bool isError = false;
  bool isLoading = false;
  bool obscureNewPassword = true;

  @override
  void dispose() {
    usernameController.dispose();
    codeController.dispose();
    newPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ملاحظة: النصوص عندك طالعة "ط..." بسبب ترميز/ملف غير UTF-8
    // الكود يعمل، لكن الأفضل لاحقًا حفظ الملف UTF-8 وإعادة كتابة النصوص العربية.
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
              'أدخل رقم الهوية ورمز الاستعادة ثم اختر كلمة مرور جديدة (الرمز الافتراضي: 0000)',
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
            ),
            const SizedBox(height: 15),

            TextField(
              controller: codeController,
              decoration: const InputDecoration(
                labelText: 'رمز الاستعادة',
                hintText: '0000',
                prefixIcon: Icon(Icons.lock_reset),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 15),

            TextField(
              controller: newPasswordController,
              obscureText: obscureNewPassword,
              decoration: InputDecoration(
                labelText: 'كلمة مرور جديدة',
                hintText: 'مثال: New@12345',
                prefixIcon: const Icon(Icons.password),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(obscureNewPassword ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => obscureNewPassword = !obscureNewPassword),
                ),
              ),
            ),

            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: isLoading ? null : _handleRecovery,
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
                        'فتح الحساب',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 15),

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

  Future<void> _handleRecovery() async {
    final username = usernameController.text.trim();
    final code = codeController.text.trim();
    final newPassword = newPasswordController.text;

    if (username.isEmpty || code.isEmpty || newPassword.isEmpty) {
      setState(() {
        msg = 'الرجاء تعبئة جميع الحقول';
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

    if (newPassword.length < 6) {
      setState(() {
        msg = 'كلمة المرور الجديدة يجب ألا تقل عن 6 أحرف';
        isError = true;
      });
      return;
    }

    setState(() {
      isLoading = true;
      msg = '';
      isError = false;
    });

    await Future.delayed(const Duration(milliseconds: 600));

    final result = await AuthService.verifyAndReset(
      username: username,
      recoveryCode: code,
      newPassword: newPassword,
      lang: 'ar',
    );

    setState(() {
      isLoading = false;

      if (result.ok) {
        msg = result.message.isEmpty
            ? 'تم فتح الحساب وتحديث كلمة المرور بنجاح. يمكنك تسجيل الدخول الآن.'
            : result.message;
        isError = false;

        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      } else {
        msg = result.message.isEmpty ? 'اسم المستخدم أو رمز الاستعادة غير صحيح.' : result.message;
        isError = true;
      }
    });
  }
}


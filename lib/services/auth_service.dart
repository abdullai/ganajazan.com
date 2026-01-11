// lib/services/auth_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqar_user/models.dart';

class LoginResult {
  final bool ok;
  final String message;
  final bool locked;
  final AppUser? user;

  const LoginResult({
    required this.ok,
    required this.message,
    required this.locked,
    this.user,
  });
}

class AuthService {
  static SupabaseClient get _sb => Supabase.instance.client;

  static const int _maxAttempts = 5;

  static Future<void> ensureDefaultAdmin() async {
    // no-op
  }

  // ✅ تحويل الأرقام العربية/الفارسية إلى 0-9
  static String normalizeNumbers(String input) {
    const arabicIndic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const easternArabicIndic = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    var out = input;
    for (int i = 0; i < 10; i++) {
      out = out.replaceAll(arabicIndic[i], i.toString());
      out = out.replaceAll(easternArabicIndic[i], i.toString());
    }
    return out;
  }

  static bool _isValidSaudiIdLikeUsername(String v) {
    final s = normalizeNumbers(v.trim());
    if (s.length != 10) return false;
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 48 || c > 57) return false;
    }
    return true;
  }

  // ✅ متوافق مع lib/models/user_model.dart: user/admin/manager
  static UserRole _roleFromDb(dynamic v) => AppUser.roleFromDb(v);

  // ✅ متوافق مع lib/models/user_model.dart: user/admin/manager
  static String _roleToDb(UserRole r) => AppUser.roleToDb(r);

  static AppUser _userFromDb(Map<String, dynamic> j) {
    return AppUser(
      username: (j['username'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      password: (j['password'] ?? '').toString(),
      recoveryCode: (j['recovery_code'] ?? '').toString(),
      role: _roleFromDb(j['role']),
    );
  }

  static Future<void> _audit({
    required String action,
    String? username,
    String? email,
    required bool success,
    String? message,
    String? details,
  }) async {
    try {
      await _sb.from('auth_audit').insert({
        'action': action,
        'username': username,
        'email': email,
        'success': success,
        'message': message,
        'details': details,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // ignore audit failure
    }
  }

  // =========================
  // ✅ Used by LoginScreen (DB checks for ✅)
  // =========================
  static Future<bool> usernameExists(String username) async {
    final u = normalizeNumbers(username).trim();
    if (!_isValidSaudiIdLikeUsername(u)) return false;

    try {
      final row = await _sb.from('app_users').select('username').eq('username', u).maybeSingle();
      return row != null;
    } catch (_) {
      return false;
    }
  }

  // ⚠️ هذا يعتمد على أن كلمة المرور مخزنة كنص (كما في جدولك حالياً).
  // لاحقاً الأفضل Hash.
  static Future<bool> credentialsMatch({
    required String username,
    required String password,
  }) async {
    final u = normalizeNumbers(username).trim();
    final pIn = normalizeNumbers(password).trim();
    if (!_isValidSaudiIdLikeUsername(u)) return false;
    if (pIn.isEmpty) return false;

    try {
      final row = await _sb.from('app_users').select('password').eq('username', u).maybeSingle();
      if (row == null) return false;

      final dbPassRaw = (row['password'] ?? '').toString();
      final dbPass = normalizeNumbers(dbPassRaw).trim();
      return dbPass == pIn;
    } catch (_) {
      return false;
    }
  }

  // =========================
  // Login
  // =========================
  static Future<LoginResult> login({
    required String username,
    required String password,
    String lang = 'ar',
  }) async {
    final isAr = lang == 'ar';

    final uName = normalizeNumbers(username).trim();
    final passIn = normalizeNumbers(password).trim();

    if (!_isValidSaudiIdLikeUsername(uName)) {
      return LoginResult(
        ok: false,
        locked: false,
        message: isAr
            ? 'اسم المستخدم يجب أن يكون رقم الهوية/الإقامة (10 أرقام فقط).'
            : 'Username must be a 10-digit National ID / Iqama number.',
      );
    }

    if (passIn.isEmpty) {
      return LoginResult(
        ok: false,
        locked: false,
        message: isAr ? 'كلمة المرور مطلوبة.' : 'Password is required.',
      );
    }

    try {
      final row = await _sb
          .from('app_users')
          .select('username,email,password,recovery_code,role,failed_attempts,locked')
          .eq('username', uName)
          .maybeSingle();

      if (row == null) {
        await _audit(
          action: 'login',
          username: uName,
          success: false,
          message: 'user_not_found',
        );
        return LoginResult(
          ok: false,
          locked: false,
          message: isAr ? 'الحساب غير موجود.' : 'Account not found.',
        );
      }

      final isLocked = (row['locked'] ?? false) as bool;
      final failedAttempts = (row['failed_attempts'] ?? 0) as int;

      if (isLocked) {
        await _audit(
          action: 'login',
          username: uName,
          email: (row['email'] ?? '').toString(),
          success: false,
          message: 'account_locked',
        );
        return LoginResult(
          ok: false,
          locked: true,
          message: isAr
              ? 'الحساب مقفل. افتحه عبر "نسيت اسم المستخدم/كلمة المرور".'
              : 'Account is locked. Unlock via "Forgot username/password".',
        );
      }

      final dbPassRaw = (row['password'] ?? '').toString();
      final dbPass = normalizeNumbers(dbPassRaw).trim();
      final passOk = dbPass == passIn;

      if (!passOk) {
        final newFailed = failedAttempts + 1;
        final remaining = _maxAttempts - newFailed;
        final willLock = newFailed >= _maxAttempts;

        await _sb.from('app_users').update({
          'failed_attempts': newFailed,
          'locked': willLock,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('username', uName);

        await _audit(
          action: 'login',
          username: uName,
          email: (row['email'] ?? '').toString(),
          success: false,
          message: willLock ? 'locked_after_max_attempts' : 'invalid_password',
          details: 'failed_attempts=$newFailed',
        );

        if (willLock) {
          return LoginResult(
            ok: false,
            locked: true,
            message: isAr
                ? 'تم قفل الحساب بعد $_maxAttempts محاولات خاطئة. استخدم "نسيت اسم المستخدم/كلمة المرور".'
                : 'Account locked after $_maxAttempts failed attempts. Use "Forgot username/password".',
          );
        }

        return LoginResult(
          ok: false,
          locked: false,
          message: isAr
              ? 'بيانات الدخول غير صحيحة. المتبقي $remaining محاولات.'
              : 'Invalid credentials. $remaining attempts remaining.',
        );
      }

      await _sb.from('app_users').update({
        'failed_attempts': 0,
        'locked': false,
        'last_login_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('username', uName);

      final user = _userFromDb(row);

      await _audit(
        action: 'login',
        username: uName,
        email: user.email,
        success: true,
        message: 'ok',
      );

      return LoginResult(
        ok: true,
        locked: false,
        message: '',
        user: user,
      );
    } catch (e) {
      await _audit(
        action: 'login',
        username: uName,
        success: false,
        message: 'exception',
        details: e.toString(),
      );
      return LoginResult(
        ok: false,
        locked: false,
        message: isAr ? 'حدث خطأ أثناء تسجيل الدخول.' : 'An error occurred during login.',
      );
    }
  }

  // =========================
  // Verify + Reset Password
  // =========================
  static Future<LoginResult> verifyAndReset({
    String? username,
    String? email,
    required String recoveryCode,
    required String newPassword,
    String lang = 'ar',
  }) async {
    final isAr = lang == 'ar';
    final uName = normalizeNumbers((username ?? '')).trim();
    final em = (email ?? '').trim();

    try {
      Map<String, dynamic>? row;

      if (uName.isNotEmpty) {
        row = await _sb
            .from('app_users')
            .select('username,email,password,recovery_code,role,failed_attempts,locked')
            .eq('username', uName)
            .maybeSingle();
      } else if (em.isNotEmpty) {
        row = await _sb
            .from('app_users')
            .select('username,email,password,recovery_code,role,failed_attempts,locked')
            .eq('email', em.toLowerCase())
            .maybeSingle();
      }

      if (row == null) {
        await _audit(
          action: 'reset_password',
          username: uName.isNotEmpty ? uName : null,
          email: em.isNotEmpty ? em : null,
          success: false,
          message: 'user_not_found',
        );
        return LoginResult(
          ok: false,
          locked: false,
          message: isAr ? 'الحساب غير موجود.' : 'Account not found.',
        );
      }

      final dbRecovery = normalizeNumbers((row['recovery_code'] ?? '').toString()).trim();
      final rcIn = normalizeNumbers(recoveryCode).trim();

      if (dbRecovery != rcIn) {
        await _audit(
          action: 'reset_password',
          username: (row['username'] ?? '').toString(),
          email: (row['email'] ?? '').toString(),
          success: false,
          message: 'invalid_recovery_code',
        );
        return LoginResult(
          ok: false,
          locked: (row['locked'] ?? false) as bool,
          message: isAr ? 'رمز الاستعادة غير صحيح.' : 'Invalid recovery code.',
        );
      }

      await _sb.from('app_users').update({
        'password': newPassword,
        'failed_attempts': 0,
        'locked': false,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('username', (row['username'] ?? '').toString());

      final updated = await _sb
          .from('app_users')
          .select('username,email,password,recovery_code,role,failed_attempts,locked')
          .eq('username', (row['username'] ?? '').toString())
          .maybeSingle();

      await _audit(
        action: 'reset_password',
        username: (row['username'] ?? '').toString(),
        email: (row['email'] ?? '').toString(),
        success: true,
        message: 'password_updated_unlocked',
      );

      return LoginResult(
        ok: true,
        locked: false,
        message: isAr ? 'تم تحديث كلمة المرور وفتح الحساب.' : 'Password updated and account unlocked.',
        user: updated == null ? null : _userFromDb(updated),
      );
    } catch (e) {
      await _audit(
        action: 'reset_password',
        username: uName.isNotEmpty ? uName : null,
        email: em.isNotEmpty ? em : null,
        success: false,
        message: 'exception',
        details: e.toString(),
      );
      return LoginResult(
        ok: false,
        locked: false,
        message: isAr ? 'حدث خطأ أثناء إعادة تعيين كلمة المرور.' : 'An error occurred while resetting the password.',
      );
    }
  }

  // =========================
  // Manual Unlock (اختياري)
  // =========================
  static Future<void> unlockAccount(String username) async {
    final uName = normalizeNumbers(username).trim();
    try {
      await _sb.from('app_users').update({
        'failed_attempts': 0,
        'locked': false,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('username', uName);

      await _audit(
        action: 'unlock_account',
        username: uName,
        success: true,
        message: 'unlocked',
      );
    } catch (e) {
      await _audit(
        action: 'unlock_account',
        username: uName,
        success: false,
        message: 'exception',
        details: e.toString(),
      );
    }
  }

  // =========================
  // Create/Update user (اختياري للإدارة)
  // =========================
  static Future<void> upsertUser({
    required String username,
    required String email,
    required String password,
    required String recoveryCode,
    required UserRole role,
  }) async {
    final uName = normalizeNumbers(username).trim();
    await _sb.from('app_users').upsert({
      'username': uName,
      'email': email.trim().toLowerCase(),
      'password': password,
      'recovery_code': recoveryCode,
      'role': _roleToDb(role),
      'failed_attempts': 0,
      'locked': false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'username');
  }
}

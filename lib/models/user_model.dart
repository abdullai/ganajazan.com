// lib/models/user_model.dart

enum UserRole { user, admin, manager }

class AppUser {
  final String username; // رقم الهوية/الإقامة
  final String email;
  final String password; // ملاحظة: حاليا نص صريح - الأفضل لاحقا hash
  final String recoveryCode;
  final UserRole role;

  const AppUser({
    required this.username,
    required this.email,
    required this.password,
    required this.recoveryCode,
    required this.role,
  });

  bool get isAdmin => role == UserRole.admin;
  bool get isManager => role == UserRole.manager;

  static UserRole roleFromDb(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    switch (s) {
      case 'admin':
        return UserRole.admin;
      case 'manager':
        return UserRole.manager;
      case 'user':
      default:
        return UserRole.user;
    }
  }

  static String roleToDb(UserRole r) {
    switch (r) {
      case UserRole.admin:
        return 'admin';
      case UserRole.manager:
        return 'manager';
      case UserRole.user:
      default:
        return 'user';
    }
  }
}

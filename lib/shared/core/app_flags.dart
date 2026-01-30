// lib/shared/core/app_flags.dart
const bool kIsAdminApp = bool.fromEnvironment('IS_ADMIN_APP', defaultValue: false);
const bool kIsProd = bool.fromEnvironment('PROD', defaultValue: false);

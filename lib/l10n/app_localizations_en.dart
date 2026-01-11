// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Aqar User';

  @override
  String get welcomeTitle => 'Welcome';

  @override
  String get welcomeTrustedAqar => 'Welcome to Trusted Aqar';

  @override
  String get signInToContinue => 'Sign in to continue';

  @override
  String get userSignIn => 'Sign In';

  @override
  String get allFieldsRequired => 'Please fill in all fields';

  @override
  String get usernameMustBe10Digits => 'Username must be 10 digits';

  @override
  String get passwordTooShort => 'Password is too short';

  @override
  String get invalidCredentials => 'Invalid credentials';

  @override
  String get rememberMe => 'Remember me';

  @override
  String get quickLogin => 'Quick login';

  @override
  String get forgotUsernameOrPassword => 'Forgot username or password?';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeSystem => 'System';

  @override
  String get languageArabic => 'العربية';

  @override
  String get languageEnglish => 'English';

  @override
  String get settings => 'Settings';

  @override
  String get usernameHint10Digits => 'National ID / Iqama (10 digits)';

  @override
  String get passwordHint => 'Password';

  @override
  String get rightPanelTitle => 'Verify your property easily';

  @override
  String get rightPanelSubtitle =>
      'Browse listings, chat, and view ads inside the app.';

  @override
  String get noEnabledAds => 'No enabled ads right now';

  @override
  String get accountLockedTitle => 'Account locked';

  @override
  String get accountLockedBody =>
      'Your account is locked due to multiple attempts. Use recovery.';

  @override
  String get recover => 'Recover';

  @override
  String get verifyTitle => 'Verification';

  @override
  String get verifySubtitle => 'Enter the verification code';

  @override
  String get confirm => 'Confirm';

  @override
  String get clear => 'Clear';

  @override
  String get securityAlert => 'Security alert';

  @override
  String get verifyTimeout => 'Verification timed out';

  @override
  String get invalidCode => 'Invalid verification code';

  @override
  String get accountLocked => 'Account locked';
}

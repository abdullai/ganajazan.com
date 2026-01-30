// lib/services/fast_login_service.dart
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Biometrics (يتطلب إضافة local_auth في pubspec.yaml إذا لم يكن موجوداً)
import 'package:local_auth/local_auth.dart';

class FastLoginService {
  FastLoginService._();

  /// ✅ لتوافق GateScreen الذي يستخدم FastLoginService.instance
  static final FastLoginService instance = FastLoginService._();

  // -----------------------------
  // Keys
  // -----------------------------
  static const _kPinEnabled = 'fast_pin_enabled';
  static const _kPinHash = 'fast_pin_hash';
  static const _kBioEnabled = 'fast_bio_enabled';
  static const _kPromptState = 'fast_prompt_state'; // never / later / done / (null)

  static const _kCtxUid = 'fast_ctx_uid';
  static const _kCtxDisplayName = 'fast_ctx_display_name';
  static const _kCtxLang = 'fast_ctx_lang';

  // ✅ جديد لتوافق verify_screen.dart (usernameNationalId)
  static const _kCtxUsernameNationalId = 'fast_ctx_username_national_id';

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  // -----------------------------
  // Helpers
  // -----------------------------
  static String normalizeDigits(String input) {
    final s = input.trim();
    if (s.isEmpty) return s;

    const ar = '٠١٢٣٤٥٦٧٨٩';
    const fa = '۰۱۲۳۴۵۶۷۸۹';

    final buf = StringBuffer();
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      final ai = ar.indexOf(c);
      if (ai >= 0) {
        buf.write(ai);
        continue;
      }
      final fi = fa.indexOf(c);
      if (fi >= 0) {
        buf.write(fi);
        continue;
      }
      buf.write(c);
    }
    return buf.toString();
  }

  static String _hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  // -----------------------------
  // Prompt state
  // -----------------------------
  static Future<String?> promptState() async {
    final p = await _prefs();
    return p.getString(_kPromptState);
  }

  static Future<void> setPromptState(String state) async {
    final p = await _prefs();
    await p.setString(_kPromptState, state);
  }

  // -----------------------------
  // PIN
  // -----------------------------
  static Future<bool> isPinEnabled() async {
    final p = await _prefs();
    return p.getBool(_kPinEnabled) ?? false;
  }

  static Future<void> setPinEnabled(bool enabled) async {
    final p = await _prefs();
    await p.setBool(_kPinEnabled, enabled);
  }

  static Future<void> setPin(String pinRaw) async {
    final pin = normalizeDigits(pinRaw);
    if (pin.length < 4) {
      throw Exception('PIN_TOO_SHORT');
    }
    final p = await _prefs();
    await p.setString(_kPinHash, _hashPin(pin));
    await p.setBool(_kPinEnabled, true);
  }

  static Future<bool> verifyPin(String pinRaw) async {
    final pin = normalizeDigits(pinRaw);
    final p = await _prefs();
    final hash = p.getString(_kPinHash);
    if (hash == null || hash.isEmpty) return false;
    return _hashPin(pin) == hash;
  }

  // -----------------------------
  // Biometrics
  // -----------------------------
  static final LocalAuthentication _auth = LocalAuthentication();

  static Future<bool> canCheckBiometrics() async {
    try {
      final can = await _auth.canCheckBiometrics;
      final supported = await _auth.isDeviceSupported();
      return can && supported;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isBiometricEnabled() async {
    final p = await _prefs();
    return p.getBool(_kBioEnabled) ?? false;
  }

  static Future<void> setBiometricEnabled(bool enabled) async {
    final p = await _prefs();
    await p.setBool(_kBioEnabled, enabled);
  }

  static Future<bool> authenticateBiometric({required bool isAr}) async {
    try {
      final can = await canCheckBiometrics();
      if (!can) return false;

      final ok = await _auth.authenticate(
        localizedReason: isAr ? 'تأكيد الهوية لتسجيل الدخول' : 'Confirm your identity to sign in',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  // -----------------------------
  // Combined
  // -----------------------------
  static Future<bool> hasAnyLockEnabled() async {
    final pin = await isPinEnabled();
    final bio = await isBiometricEnabled();
    return pin || bio;
  }

  // -----------------------------
  // User context (اختياري لعرض الاسم في شاشة الدخول السريع)
  // -----------------------------
  /// ✅ تم توسيع التوقيع لدعم:
  /// verify_screen.dart: usernameNationalId: ...
  /// وأيضاً لدعم الاستدعاءات القديمة: uid / displayName / lang
  static Future<void> saveUserContext({
    required String uid,
    String? displayName,
    String? lang,

    // ✅ الجديد
    String? usernameNationalId,
  }) async {
    final p = await _prefs();
    await p.setString(_kCtxUid, uid);

    if (displayName != null) {
      final v = displayName.trim();
      if (v.isNotEmpty) {
        await p.setString(_kCtxDisplayName, v);
      } else {
        await p.remove(_kCtxDisplayName);
      }
    }

    if (lang != null) {
      final v = lang.trim();
      if (v.isNotEmpty) {
        await p.setString(_kCtxLang, v);
      } else {
        await p.remove(_kCtxLang);
      }
    }

    if (usernameNationalId != null) {
      final v = normalizeDigits(usernameNationalId).trim();
      if (v.isNotEmpty) {
        await p.setString(_kCtxUsernameNationalId, v);
      } else {
        await p.remove(_kCtxUsernameNationalId);
      }
    }
  }

  static Future<String?> getDisplayName() async {
    final p = await _prefs();
    return p.getString(_kCtxDisplayName);
  }

  static Future<String?> getCtxUid() async {
    final p = await _prefs();
    return p.getString(_kCtxUid);
  }

  static Future<String?> getCtxLang() async {
    final p = await _prefs();
    return p.getString(_kCtxLang);
  }

  static Future<String?> getUsernameNationalId() async {
    final p = await _prefs();
    return p.getString(_kCtxUsernameNationalId);
  }

  // -----------------------------
  // Instance helpers (لتوافق GateScreen)
  // -----------------------------
  /// ✅ يستخدمه GateScreen لتحديد هل يفتح شاشة الدخول السريع أو لا
  Future<bool> hasValidUser() async {
    final uid = await getCtxUid();
    if (uid == null || uid.trim().isEmpty) return false;

    // يجب وجود أي قفل (PIN أو بصمة) حتى يعتبر الدخول السريع مفعلاً
    final hasLock = await hasAnyLockEnabled();
    if (!hasLock) return false;

    return true;
  }

  // -----------------------------
  // Clear
  // -----------------------------
  static Future<void> clearAll() async {
    final p = await _prefs();
    await p.remove(_kPinEnabled);
    await p.remove(_kPinHash);
    await p.remove(_kBioEnabled);
    await p.remove(_kPromptState);

    await p.remove(_kCtxUid);
    await p.remove(_kCtxDisplayName);
    await p.remove(_kCtxLang);
    await p.remove(_kCtxUsernameNationalId);
  }

  // -----------------------------
  // Debug hint (اختياري)
  // -----------------------------
  static void debugPrintState() async {
    if (!kDebugMode) return;
    final pin = await isPinEnabled();
    final bio = await isBiometricEnabled();
    final st = await promptState();
    final uid = await getCtxUid();
    final name = await getDisplayName();
    final nid = await getUsernameNationalId();
    // ignore: avoid_print
    print('FastLogin: uid=$uid name=$name nid=$nid pin=$pin bio=$bio prompt=$st');
  }
}

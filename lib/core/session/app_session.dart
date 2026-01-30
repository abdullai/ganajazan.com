import 'package:flutter/foundation.dart';

class AppSession extends ChangeNotifier {
  bool _isLoggedIn = false;
  String? _userId;

  bool get isLoggedIn => _isLoggedIn;
  bool get isGuest => !_isLoggedIn;
  String? get userId => _userId;

  void login(String userId) {
    _isLoggedIn = true;
    _userId = userId;
    notifyListeners();
  }

  void logout() {
    _isLoggedIn = false;
    _userId = null;
    notifyListeners();
  }
}

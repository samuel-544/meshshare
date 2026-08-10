import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the app lock state, PIN storage, and biometric authentication.
///
/// PIN storage: SHA-256(pin || salt) stored as JSON in the app documents dir.
/// Biometric: via [LocalAuthentication] (Android / iOS / Windows / macOS only).
class AuthService extends ChangeNotifier {
  static const _fileName = 'auth.json';

  final _localAuth = LocalAuthentication();
  final _rng = math.Random.secure();

  bool _isLocked = true;
  bool _isPinSet = false;

  bool get isLocked => _isLocked;
  bool get isPinSet => _isPinSet;

  /// Call once at app startup — reads stored PIN state from disk.
  Future<void> init() async {
    final file = await _authFile();
    _isPinSet = await file.exists();
    _isLocked = _isPinSet;
    notifyListeners();
  }

  // ── PIN ───────────────────────────────────────────────────────────────────

  /// Set a new PIN. Hashes it with a random salt and persists to disk.
  Future<void> setPin(String pin) async {
    final salt = _secureRandomBytes(16);
    final hash = await _hashPin(pin, salt);
    final file = await _authFile();
    await file.writeAsString(
      jsonEncode({'salt': base64Encode(salt), 'hash': base64Encode(hash)}),
    );
    _isPinSet = true;
    _isLocked = false;
    notifyListeners();
  }

  /// Returns true if [pin] matches the stored hash.
  Future<bool> verifyPin(String pin) async {
    final file = await _authFile();
    if (!await file.exists()) return false;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final salt = base64Decode(data['salt'] as String);
    final stored = Uint8List.fromList(base64Decode(data['hash'] as String));
    final computed = await _hashPin(pin, salt);
    return _constantTimeEquals(computed, stored);
  }

  // ── Biometric ─────────────────────────────────────────────────────────────

  /// Whether biometric auth is available and enrolled on this device.
  Future<bool> canUseBiometric() async {
    // local_auth has no Linux implementation.
    if (Platform.isLinux) return false;
    try {
      if (!await _localAuth.isDeviceSupported()) return false;
      final enrolled = await _localAuth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Prompt the OS biometric dialog. Returns true on success.
  Future<bool> authenticateWithBiometric() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Unlock MeshShare',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  // ── Lock / unlock ─────────────────────────────────────────────────────────

  void unlock() {
    _isLocked = false;
    notifyListeners();
  }

  /// Lock the app. No-op when no PIN is set (first-launch state).
  void lock() {
    if (_isPinSet) {
      _isLocked = true;
      notifyListeners();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<File> _authFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<Uint8List> _hashPin(String pin, List<int> salt) async {
    final sha256 = Sha256();
    final input = [...utf8.encode(pin), ...salt];
    final hash = await sha256.hash(input);
    return Uint8List.fromList(hash.bytes);
  }

  Uint8List _secureRandomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _rng.nextInt(256)));

  bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

/// Manages cryptographic keys for MeshShare.
///
/// Responsibilities:
/// - Generate and **persist** the device's long-term Noise static keypair.
///   The keypair survives app restarts and is stored as a 64-byte file
///   (32-byte private key || 32-byte public key) in the app documents dir.
/// - Derive a **stable peer identity** string from the public key.
///   Identity = hex(SHA-256(public_key_bytes)), 64 hex chars.
///   Stable even when the Android BLE MAC address rotates.
/// - Store and retrieve **per-session transport keys** (from Noise handshake).
///   Session keys are in-memory only — cleared on disconnect.
///
/// Usage:
/// ```dart
/// final km = await KeyManager.instance();
/// final keyPair = await km.getOrCreateStaticKeyPair();
/// final myId    = await km.localPeerId();
/// km.storeSession('peer-hex-id', sendKey, receiveKey);
/// final sk = km.sessionSendKey('peer-hex-id');
/// ```
class KeyManager {
  static const String _keyFileName = 'meshshare_static_key.bin';

  static final _x25519 = X25519();
  static final _sha256 = Sha256();
  static final _transferHkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final Directory _dir;

  // Cached in-memory keypair (avoid re-reading the file every time).
  SimpleKeyPairData? _cachedKeyPair;

  // Per-session transport keys keyed by peer identity string.
  final Map<String, SecretKey> _sessionSendKeys = {};
  final Map<String, SecretKey> _sessionReceiveKeys = {};

  // Peer static (long-term) public keys, keyed by 16-char shortId. Kept so a
  // transfer key can be re-derived after the Noise session is re-negotiated.
  final Map<String, SimplePublicKey> _peerStaticKeys = {};

  // Derived transfer keys, cached by "<peerShortId>:<fileId>" so the X25519 +
  // HKDF runs once per transfer, not once per chunk.
  final Map<String, SecretKey> _transferKeys = {};

  KeyManager._(this._dir);

  // ── Factory ────────────────────────────────────────────────────────────────

  static KeyManager? _instance;

  /// Return the singleton [KeyManager] backed by the app's documents directory.
  ///
  /// Use [KeyManager.forTesting] in tests to inject a temporary directory.
  static Future<KeyManager> instance() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    _instance = KeyManager._(dir);
    return _instance!;
  }

  /// Create a [KeyManager] backed by [dir] — for unit testing only.
  factory KeyManager.forTesting(Directory dir) => KeyManager._(dir);

  // ── Static keypair ─────────────────────────────────────────────────────────

  /// Return the device's Noise static keypair, generating it if it does not
  /// exist yet. The keypair is persisted to disk and cached in memory.
  Future<SimpleKeyPairData> getOrCreateStaticKeyPair() async {
    if (_cachedKeyPair != null) return _cachedKeyPair!;

    final keyFile = File('${_dir.path}/$_keyFileName');

    if (await keyFile.exists()) {
      _cachedKeyPair = await _loadKeyPair(keyFile);
    } else {
      _cachedKeyPair = await _generateAndSaveKeyPair(keyFile);
    }

    return _cachedKeyPair!;
  }

  /// The stable local peer identity: `hex(SHA-256(static_public_key))`.
  Future<String> localPeerId() async {
    final keyPair = await getOrCreateStaticKeyPair();
    return _identityFromPublicKey(keyPair.publicKey);
  }

  /// Raw 32-byte SHA-256 hash of the local static public key — passed to [BleMeshService.start].
  Future<Uint8List> localIdentityBytes() async {
    final keyPair = await getOrCreateStaticKeyPair();
    final hash = await _sha256.hash(keyPair.publicKey.bytes);
    return Uint8List.fromList(hash.bytes);
  }

  /// Derive a peer identity string from any Curve25519 public key.
  Future<String> identityFor(SimplePublicKey publicKey) =>
      _identityFromPublicKey(publicKey);

  // ── Session keys ───────────────────────────────────────────────────────────

  /// Store the transport keys derived from a completed Noise_XX handshake.
  ///
  /// [peerId] should be the hex identity string of the remote peer.
  void storeSession(String peerId, SecretKey sendKey, SecretKey receiveKey) {
    _sessionSendKeys[peerId] = sendKey;
    _sessionReceiveKeys[peerId] = receiveKey;
  }

  /// The key used to ENCRYPT outgoing chunks sent to [peerId].
  /// Returns `null` if no session exists for that peer.
  SecretKey? sessionSendKey(String peerId) => _sessionSendKeys[peerId];

  /// The key used to DECRYPT incoming chunks received from [peerId].
  SecretKey? sessionReceiveKey(String peerId) => _sessionReceiveKeys[peerId];

  /// Remove session keys for [peerId] (call on disconnect).
  void clearSession(String peerId) {
    _sessionSendKeys.remove(peerId);
    _sessionReceiveKeys.remove(peerId);
  }

  /// Whether an active session exists for [peerId].
  bool hasSession(String peerId) => _sessionSendKeys.containsKey(peerId);

  // ── Transfer keys ──────────────────────────────────────────────────────────

  /// Remember a peer's long-term Noise static public key (from a completed
  /// handshake). Needed to derive transfer keys that outlive the session.
  void storePeerStaticKey(String peerShortId, SimplePublicKey publicKey) {
    _peerStaticKeys[peerShortId] = publicKey;
  }

  /// Derive the symmetric key used to encrypt every chunk of transfer
  /// [fileId] with peer [peerShortId] (a 16-char [MeshNode.shortId]).
  ///
  /// The key is `HKDF-SHA256(X25519(myStatic, peerStatic), salt=fileId)`.
  /// Because it is anchored to the two devices' **static** keys, it stays
  /// valid even if the live Noise session is torn down and re-negotiated
  /// mid-transfer — so chunks queued before a reconnect still decrypt.
  ///
  /// Returns null if we have never completed a handshake with this peer.
  Future<SecretKey?> deriveTransferKey(
    String peerShortId,
    String fileId,
  ) async {
    final cacheKey = '$peerShortId:$fileId';
    final cached = _transferKeys[cacheKey];
    if (cached != null) return cached;

    final peerStatic = _peerStaticKeys[peerShortId];
    if (peerStatic == null) return null;

    final myKeyPair = await getOrCreateStaticKeyPair();
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: peerStatic,
    );
    final key = await _transferHkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode(fileId),
      info: utf8.encode('meshshare-transfer-v1'),
    );
    _transferKeys[cacheKey] = key;
    return key;
  }

  /// Drop the cached transfer key for a finished/failed transfer.
  void clearTransferKey(String peerShortId, String fileId) {
    _transferKeys.remove('$peerShortId:$fileId');
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<SimpleKeyPairData> _generateAndSaveKeyPair(File keyFile) async {
    final keyPair = await _x25519.newKeyPair();
    final data = await keyPair.extract();

    // Store: 32-byte private key || 32-byte public key
    final bytes = Uint8List(64);
    bytes.setAll(0, data.bytes);
    bytes.setAll(32, data.publicKey.bytes);
    await keyFile.writeAsBytes(bytes, flush: true);

    return data;
  }

  Future<SimpleKeyPairData> _loadKeyPair(File keyFile) async {
    final bytes = await keyFile.readAsBytes();
    if (bytes.length != 64) {
      throw StateError(
        'Key file is corrupt (expected 64 bytes, got ${bytes.length}).',
      );
    }
    final privateBytes = bytes.sublist(0, 32);
    final publicBytes = bytes.sublist(32, 64);
    return SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  Future<String> _identityFromPublicKey(SimplePublicKey publicKey) async {
    final hash = await _sha256.hash(publicKey.bytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

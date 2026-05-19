import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// ── Result ─────────────────────────────────────────────────────────────────

/// The output of a completed Noise_XX handshake.
///
/// Both peers agree on the same pair of transport keys (one for each
/// direction). These keys are then used by [AeadCipher] for all subsequent
/// file chunks and messages.
class HandshakeResult {
  /// Key used by the INITIATOR to encrypt outgoing transport messages,
  /// and by the RESPONDER to decrypt incoming messages.
  final SecretKey sendKey;

  /// Key used by the RESPONDER to encrypt outgoing transport messages,
  /// and by the INITIATOR to decrypt incoming messages.
  final SecretKey receiveKey;

  /// The remote peer's long-term static public key (Curve25519, 32 bytes).
  final SimplePublicKey remoteStaticPublicKey;

  const HandshakeResult({
    required this.sendKey,
    required this.receiveKey,
    required this.remoteStaticPublicKey,
  });
}

// ── Shared state ───────────────────────────────────────────────────────────

/// Internal Noise_XX symmetric state (shared between initiator and responder).
///
/// Protocol: Noise_XX_25519_ChaChaPoly_SHA256
///
/// Reference: https://noiseprotocol.org/noise.html (revision 34)
class _NoiseState {
  // Protocol identifier — determines the initial hash/chaining-key values.
  static const String _protocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';

  static final _sha256 = Sha256();
  static final _hmac   = Hmac(Sha256());
  static final _aead   = Chacha20.poly1305Aead();
  static final _x25519 = X25519();

  late Uint8List _h;   // handshake hash (32 bytes) — MixHash accumulates into this
  late Uint8List _ck;  // chaining key (32 bytes) — MixKey derives new keys from this
  SecretKey? _k;       // current symmetric key — null until first MixKey call
  int _n = 0;          // nonce counter for AEAD during handshake

  // ── Initialise ─────────────────────────────────────────────────────────────

  /// Called once at the start of the handshake.
  Future<void> init() async {
    // len("Noise_XX_25519_ChaChaPoly_SHA256") = 33 > HASHLEN (32)
    // → h = SHA-256(protocol_name)
    final nameBytes = utf8.encode(_protocolName);
    final hash = await _sha256.hash(nameBytes);
    _h  = Uint8List.fromList(hash.bytes);
    _ck = Uint8List.fromList(hash.bytes); // ck starts equal to h
  }

  // ── Primitive operations ───────────────────────────────────────────────────

  /// h = SHA-256(h || data)
  Future<void> mixHash(List<int> data) async {
    final hash = await _sha256.hash([..._h, ...data]);
    _h = Uint8List.fromList(hash.bytes);
  }

  /// Derive new chaining key and symmetric key from [inputKeyMaterial].
  ///
  /// Uses Noise's two-output HKDF:
  ///   temp_key   = HMAC-SHA256(ck, ikm)
  ///   new_ck     = HMAC-SHA256(temp_key, 0x01)
  ///   new_k      = HMAC-SHA256(temp_key, new_ck || 0x02)
  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final tempKeyMac = await _hmac.calculateMac(
      inputKeyMaterial,
      secretKey: SecretKey(_ck),
    );
    final tempKey = Uint8List.fromList(tempKeyMac.bytes);

    final ck1Mac = await _hmac.calculateMac([0x01], secretKey: SecretKey(tempKey));
    final newCk  = Uint8List.fromList(ck1Mac.bytes);

    final k2Mac = await _hmac.calculateMac(
      [...newCk, 0x02],
      secretKey: SecretKey(tempKey),
    );
    final newK = Uint8List.fromList(k2Mac.bytes);

    _ck = newCk;
    _k  = SecretKey(newK);
    _n  = 0; // reset nonce counter after each key rotation
  }

  /// Encrypt [plaintext] and update h.
  ///
  /// If no key is established yet (before first MixKey), returns [plaintext]
  /// unmodified and still mixes it into h (used for message 1 ephemeral key).
  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    if (_k == null) {
      await mixHash(plaintext);
      return Uint8List.fromList(plaintext);
    }

    final secretBox = await _aead.encrypt(
      plaintext,
      secretKey: _k!,
      nonce: _noiseNonce(_n++),
      aad: _h, // h is the AAD — binds ciphertext to the handshake transcript
    );

    final ciphertext = Uint8List(secretBox.cipherText.length + 16);
    ciphertext.setAll(0, secretBox.cipherText);
    ciphertext.setAll(secretBox.cipherText.length, secretBox.mac.bytes);

    await mixHash(ciphertext);
    return ciphertext;
  }

  /// Decrypt [ciphertext] and update h.
  ///
  /// If no key is established yet, returns [ciphertext] unmodified.
  /// Throws [SecretBoxAuthenticationError] if the MAC tag is invalid.
  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    if (_k == null) {
      await mixHash(ciphertext);
      return Uint8List.fromList(ciphertext);
    }

    final ct      = ciphertext.sublist(0, ciphertext.length - 16);
    final macBytes = ciphertext.sublist(ciphertext.length - 16);
    final box = SecretBox(ct, nonce: _noiseNonce(_n++), mac: Mac(macBytes));

    final plaintext = await _aead.decrypt(box, secretKey: _k!, aad: _h);

    await mixHash(ciphertext);
    return Uint8List.fromList(plaintext);
  }

  /// Derive the final transport key pair after all three messages.
  ///
  ///   temp_key = HMAC-SHA256(ck, "")
  ///   k1       = HMAC-SHA256(temp_key, 0x01)       — initiator → responder
  ///   k2       = HMAC-SHA256(temp_key, k1 || 0x02) — responder → initiator
  Future<(SecretKey, SecretKey)> split() async {
    final tempKeyMac = await _hmac.calculateMac([], secretKey: SecretKey(_ck));
    final tempKey    = Uint8List.fromList(tempKeyMac.bytes);

    final k1Mac = await _hmac.calculateMac([0x01], secretKey: SecretKey(tempKey));
    final k1    = Uint8List.fromList(k1Mac.bytes);

    final k2Mac = await _hmac.calculateMac([...k1, 0x02], secretKey: SecretKey(tempKey));
    final k2    = Uint8List.fromList(k2Mac.bytes);

    return (SecretKey(k1.toList()), SecretKey(k2.toList()));
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Perform a Curve25519 DH and return the 32-byte shared secret.
  Future<Uint8List> dh(SimpleKeyPairData keyPair, SimplePublicKey remotePublic) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublic,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// Build the 12-byte Noise nonce: 4 zero bytes || 8-byte little-endian n.
  static List<int> _noiseNonce(int n) {
    return [
      0, 0, 0, 0,
      n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff,
      0, 0, 0, 0,
    ];
  }
}

// ── Initiator ──────────────────────────────────────────────────────────────

/// Handles the initiator side of a Noise_XX handshake.
///
/// ```
/// final initiator = await NoiseInitiator.create(myStaticKeyPair);
/// final msg1 = await initiator.writeMessage1();          // → send to responder
/// final msg3 = await initiator.readMsg2WriteMsg3(msg2);  // ← receive, → send
/// final result = initiator.result;                        // transport keys
/// ```
class NoiseInitiator {
  final _NoiseState _state = _NoiseState();
  final SimpleKeyPairData _s;   // local static keypair
  late SimpleKeyPairData _e;    // local ephemeral keypair
  HandshakeResult? _result;

  NoiseInitiator._(this._s);

  /// Create and initialise a new initiator with [staticKeyPair].
  static Future<NoiseInitiator> create(SimpleKeyPairData staticKeyPair) async {
    final i = NoiseInitiator._(staticKeyPair);
    await i._state.init();
    i._e = await _NoiseState._x25519.newKeyPair()
        .then((kp) => kp.extract());
    return i;
  }

  // ── Message 1: → e ─────────────────────────────────────────────────────────

  /// Build and return message 1 bytes (32-byte ephemeral public key).
  ///
  /// Call this first. Send the returned bytes to the responder.
  Future<Uint8List> writeMessage1() async {
    final ePub = _e.publicKey.bytes;
    // MixHash(e.pub) — no encryption yet, k is null
    final msg = await _state.encryptAndHash(ePub);
    return msg;
  }

  // ── Message 2 (receive) + Message 3 (send): ← e, ee, s, es  →  s, se ──────

  /// Process message 2 from the responder, then build and return message 3.
  ///
  /// [msg2] is the 80-byte message received from the responder:
  ///   32 bytes e_r_pub + 48 bytes enc(s_r_pub)
  ///
  /// Returns the 48-byte message 3: enc(s_i_pub)
  Future<Uint8List> readMsg2WriteMsg3(Uint8List msg2) async {
    // ── Parse and process message 2: ← e, ee, s, es ──────────────────────────

    // Token `e`: read responder's ephemeral public key (32 bytes, plaintext)
    final rePubBytes = msg2.sublist(0, 32);
    final rePub = SimplePublicKey(rePubBytes, type: KeyPairType.x25519);
    await _state.mixHash(rePubBytes); // no encryption yet — k still null

    // Token `ee`: MixKey(DH(e_i, e_r))
    final ee = await _state.dh(_e, rePub);
    await _state.mixKey(ee);

    // Token `s`: decrypt responder's static public key (32-byte plaintext + 16-byte tag = 48 bytes)
    final encSr = msg2.sublist(32, 80);
    final srPubBytes = await _state.decryptAndHash(encSr);
    final rsPub = SimplePublicKey(srPubBytes, type: KeyPairType.x25519);

    // Token `es`: MixKey(DH(e_i, s_r))
    // Initiator uses their ephemeral with responder's static.
    final es = await _state.dh(_e, rsPub);
    await _state.mixKey(es);

    // ── Build message 3: → s, se ──────────────────────────────────────────────

    // Token `s`: encrypt initiator's static public key
    final sPubBytes = _s.publicKey.bytes;
    final encSi = await _state.encryptAndHash(sPubBytes);

    // Token `se`: MixKey(DH(s_i, e_r))
    // Initiator uses their static with responder's ephemeral.
    final se = await _state.dh(_s, rePub);
    await _state.mixKey(se);

    // ── Derive transport keys ─────────────────────────────────────────────────
    final (k1, k2) = await _state.split();
    _result = HandshakeResult(
      sendKey: k1,    // initiator → responder
      receiveKey: k2, // responder → initiator
      remoteStaticPublicKey: rsPub,
    );

    return encSi;
  }

  /// The transport keys — only available after [readMsg2WriteMsg3] completes.
  HandshakeResult get result {
    assert(_result != null, 'Handshake not complete yet.');
    return _result!;
  }
}

// ── Responder ──────────────────────────────────────────────────────────────

/// Handles the responder side of a Noise_XX handshake.
///
/// ```
/// final responder = await NoiseResponder.create(myStaticKeyPair);
/// final msg2 = await responder.readMsg1WriteMsg2(msg1);  // ← receive, → send
/// await responder.readMessage3(msg3);                    // ← receive
/// final result = responder.result;                        // transport keys
/// ```
class NoiseResponder {
  final _NoiseState _state = _NoiseState();
  final SimpleKeyPairData _s;
  late SimpleKeyPairData _e;
  HandshakeResult? _result;

  NoiseResponder._(this._s);

  /// Create and initialise a new responder with [staticKeyPair].
  static Future<NoiseResponder> create(SimpleKeyPairData staticKeyPair) async {
    final r = NoiseResponder._(staticKeyPair);
    await r._state.init();
    r._e = await _NoiseState._x25519.newKeyPair()
        .then((kp) => kp.extract());
    return r;
  }

  // ── Message 1 (receive) + Message 2 (send): → e  ←  e, ee, s, es ──────────

  /// Process message 1 from the initiator, then build and return message 2.
  ///
  /// [msg1] is the 32-byte ephemeral public key sent by the initiator.
  ///
  /// Returns the 80-byte message 2: e_r_pub (32) + enc(s_r_pub) (48)
  Future<Uint8List> readMsg1WriteMsg2(Uint8List msg1) async {
    // ── Process message 1: → e ────────────────────────────────────────────────

    // Token `e`: read initiator's ephemeral (plaintext, 32 bytes)
    final iePubBytes = msg1.sublist(0, 32);
    final iePub = SimplePublicKey(iePubBytes, type: KeyPairType.x25519);
    await _state.mixHash(iePubBytes);

    // ── Build message 2: ← e, ee, s, es ──────────────────────────────────────

    // Token `e`: send responder's ephemeral public key (plaintext)
    final ePubBytes = _e.publicKey.bytes;
    await _state.mixHash(ePubBytes); // no key yet — plaintext

    // Token `ee`: MixKey(DH(e_r, e_i))
    final ee = await _state.dh(_e, iePub);
    await _state.mixKey(ee);

    // Token `s`: encrypt and send responder's static public key
    final sPubBytes = _s.publicKey.bytes;
    final encSr = await _state.encryptAndHash(sPubBytes);

    // Token `es`: MixKey(DH(s_r, e_i))
    // Responder uses their static with initiator's ephemeral.
    final es = await _state.dh(_s, iePub);
    await _state.mixKey(es);

    // Message 2 = e_r_pub (32 bytes) || enc(s_r_pub) (48 bytes)
    final msg2 = Uint8List(32 + encSr.length);
    msg2.setAll(0, ePubBytes);
    msg2.setAll(32, encSr);
    return msg2;
  }

  // ── Message 3 (receive): → s, se ─────────────────────────────────────────

  /// Process message 3 from the initiator and finalise the handshake.
  ///
  /// [msg3] is the 48-byte encrypted initiator static public key.
  /// After this call, [result] is available.
  Future<void> readMessage3(Uint8List msg3) async {
    // Token `s`: decrypt initiator's static public key
    final isPubBytes = await _state.decryptAndHash(msg3);
    final risPub = SimplePublicKey(isPubBytes, type: KeyPairType.x25519);

    // Token `se`: MixKey(DH(e_r, s_i))
    // Responder uses their ephemeral with initiator's static.
    final se = await _state.dh(_e, risPub);
    await _state.mixKey(se);

    // ── Derive transport keys ─────────────────────────────────────────────────
    final (k1, k2) = await _state.split();
    _result = HandshakeResult(
      sendKey: k2,    // responder → initiator (k2 is the responder send key)
      receiveKey: k1, // initiator → responder (k1 is initiator's send key)
      remoteStaticPublicKey: risPub,
    );
  }

  /// The transport keys — only available after [readMessage3] completes.
  HandshakeResult get result {
    assert(_result != null, 'Handshake not complete yet.');
    return _result!;
  }
}

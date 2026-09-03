import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class PeerContact {
  final String peerId;
  final String displayName;
  final String? deviceName;
  final int firstSeenMs;
  final int lastSeenMs;

  /// When true, this device silently drops every message and file this peer
  /// sends to us (see [TransferManager]). It has **no effect on mesh
  /// relaying** — a blocked peer's traffic bound for other nodes is still
  /// forwarded, and the peer stays a full neighbour in the mesh topology.
  final bool blocked;

  const PeerContact({
    required this.peerId,
    required this.displayName,
    this.deviceName,
    required this.firstSeenMs,
    required this.lastSeenMs,
    this.blocked = false,
  });

  factory PeerContact.fromJson(Map<String, dynamic> json) => PeerContact(
    peerId: json['peerId'] as String,
    displayName: json['displayName'] as String,
    deviceName: json['deviceName'] as String?,
    firstSeenMs: json['firstSeenMs'] as int,
    lastSeenMs: json['lastSeenMs'] as int,
    blocked: json['blocked'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'displayName': displayName,
    'deviceName': deviceName,
    'firstSeenMs': firstSeenMs,
    'lastSeenMs': lastSeenMs,
    'blocked': blocked,
  };

  PeerContact copyWith({
    String? displayName,
    String? deviceName,
    int? lastSeenMs,
    bool? blocked,
  }) => PeerContact(
    peerId: peerId,
    displayName: displayName ?? this.displayName,
    deviceName: deviceName ?? this.deviceName,
    firstSeenMs: firstSeenMs,
    lastSeenMs: lastSeenMs ?? this.lastSeenMs,
    blocked: blocked ?? this.blocked,
  );
}

class PeerContactStore extends ChangeNotifier {
  static const _fileName = 'meshshare_contacts.json';

  final Map<String, PeerContact> _contacts = {};

  /// Fixed backing directory. Null in production (resolved lazily via
  /// path_provider); set by [PeerContactStore.forTesting] so unit tests can
  /// run without the platform channel.
  final Directory? _overrideDir;

  PeerContactStore() : _overrideDir = null;

  /// Test-only constructor backed by [dir] instead of the app documents dir.
  @visibleForTesting
  PeerContactStore.forTesting(Directory dir) : _overrideDir = dir;

  List<PeerContact> get contacts {
    final list = _contacts.values.toList();
    list.sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return List.unmodifiable(list);
  }

  PeerContact? contactFor(String peerId) => _contacts[peerId];

  /// Whether this peer is blocked. Accepts either the 16-char short id or a
  /// longer identity hex — matching is done on the stored key and on a
  /// short-id prefix so callers don't have to normalise first.
  bool isBlocked(String peerId) {
    final direct = _contacts[peerId];
    if (direct != null) return direct.blocked;
    for (final entry in _contacts.entries) {
      if (entry.value.blocked &&
          (peerId.startsWith(entry.key) || entry.key.startsWith(peerId))) {
        return true;
      }
    }
    return false;
  }

  /// Block or unblock [peerId]. Creates a contact row if none exists yet
  /// (e.g. blocking a peer only seen via mesh gossip). [displayName] is only
  /// used for a freshly created row so the block doesn't wipe a nicer name
  /// the peer was already showing under.
  Future<void> setBlocked(
    String peerId,
    bool blocked, {
    String? displayName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _contacts[peerId];
    if (existing == null && !blocked) return;

    final shortLabel = peerId.length >= 8 ? peerId.substring(0, 8) : peerId;
    final name = _cleanName(displayName) ?? 'Peer $shortLabel';
    _contacts[peerId] = existing == null
        ? PeerContact(
            peerId: peerId,
            displayName: name,
            firstSeenMs: now,
            lastSeenMs: now,
            blocked: blocked,
          )
        : existing.copyWith(blocked: blocked);

    await _persist();
    notifyListeners();
  }

  String nameFor(String peerId, {String? fallback}) {
    final saved = _contacts[peerId]?.displayName;
    if (saved != null && saved.trim().isNotEmpty) return saved;
    if (fallback != null && fallback.trim().isNotEmpty) return fallback;
    return 'Peer ${peerId.substring(0, 8)}';
  }

  Future<void> init() async {
    final file = await _contactsFile();
    if (!await file.exists()) return;

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) return;

    _contacts
      ..clear()
      ..addEntries(
        decoded
            .whereType<Map>()
            .map(
              (item) => PeerContact.fromJson(Map<String, dynamic>.from(item)),
            )
            .map((contact) => MapEntry(contact.peerId, contact)),
      );
    notifyListeners();
  }

  Future<void> saveHandshakePeer({
    required String peerId,
    String? deviceName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _contacts[peerId];
    final cleanDeviceName = _cleanName(deviceName);

    _contacts[peerId] = existing == null
        ? PeerContact(
            peerId: peerId,
            displayName: cleanDeviceName ?? 'Peer ${peerId.substring(0, 8)}',
            deviceName: cleanDeviceName,
            firstSeenMs: now,
            lastSeenMs: now,
          )
        : existing.copyWith(
            deviceName: cleanDeviceName ?? existing.deviceName,
            lastSeenMs: now,
          );

    await _persist();
    notifyListeners();
  }

  Future<void> rename(String peerId, String displayName) async {
    final cleanName = displayName.trim();
    if (cleanName.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _contacts[peerId];
    _contacts[peerId] = existing == null
        ? PeerContact(
            peerId: peerId,
            displayName: cleanName,
            firstSeenMs: now,
            lastSeenMs: now,
          )
        : existing.copyWith(displayName: cleanName);

    await _persist();
    notifyListeners();
  }

  Future<File> _contactsFile() async {
    final dir = _overrideDir ?? await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _persist() async {
    final file = await _contactsFile();
    final encoded = jsonEncode(contacts.map((c) => c.toJson()).toList());
    await file.writeAsString(encoded, flush: true);
  }

  String? _cleanName(String? name) {
    final clean = name?.trim();
    if (clean == null || clean.isEmpty) return null;
    return clean;
  }
}

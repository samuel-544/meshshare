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

  const PeerContact({
    required this.peerId,
    required this.displayName,
    this.deviceName,
    required this.firstSeenMs,
    required this.lastSeenMs,
  });

  factory PeerContact.fromJson(Map<String, dynamic> json) => PeerContact(
    peerId: json['peerId'] as String,
    displayName: json['displayName'] as String,
    deviceName: json['deviceName'] as String?,
    firstSeenMs: json['firstSeenMs'] as int,
    lastSeenMs: json['lastSeenMs'] as int,
  );

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'displayName': displayName,
    'deviceName': deviceName,
    'firstSeenMs': firstSeenMs,
    'lastSeenMs': lastSeenMs,
  };

  PeerContact copyWith({
    String? displayName,
    String? deviceName,
    int? lastSeenMs,
  }) => PeerContact(
    peerId: peerId,
    displayName: displayName ?? this.displayName,
    deviceName: deviceName ?? this.deviceName,
    firstSeenMs: firstSeenMs,
    lastSeenMs: lastSeenMs ?? this.lastSeenMs,
  );
}

class PeerContactStore extends ChangeNotifier {
  static const _fileName = 'meshshare_contacts.json';

  final Map<String, PeerContact> _contacts = {};

  List<PeerContact> get contacts {
    final list = _contacts.values.toList();
    list.sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return List.unmodifiable(list);
  }

  PeerContact? contactFor(String peerId) => _contacts[peerId];

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
    final dir = await getApplicationDocumentsDirectory();
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

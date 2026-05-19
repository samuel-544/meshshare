import 'dart:math';
import 'dart:typed_data';

/// Generates a random UUID v4 string (used for transfer session IDs).
String generateUuid() {
  final rng = Random.secure();
  final bytes = Uint8List(16);
  for (int i = 0; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  // Set version 4 bits
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  // Set variant bits
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');
  return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}-'
      '${hex(bytes[4])}${hex(bytes[5])}-'
      '${hex(bytes[6])}${hex(bytes[7])}-'
      '${hex(bytes[8])}${hex(bytes[9])}-'
      '${hex(bytes[10])}${hex(bytes[11])}${hex(bytes[12])}${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
}

/// Fixed-capacity LRU (Least Recently Used) cache.
///
/// When the cache is full, the oldest-accessed entry is evicted.
/// Used by the relay layer to deduplicate forwarded chunks.
class LruCache<K> {
  final int maxSize;
  final _map = <K, bool>{};

  LruCache(this.maxSize) : assert(maxSize > 0);

  /// Returns true if [key] is present in the cache.
  bool contains(K key) => _map.containsKey(key);

  /// Insert [key]. Evicts the oldest entry if the cache is full.
  /// If [key] already exists, it is refreshed (moved to most-recent).
  void put(K key) {
    if (_map.containsKey(key)) {
      _map.remove(key); // re-insert to refresh order
    } else if (_map.length >= maxSize) {
      _map.remove(_map.keys.first); // evict oldest
    }
    _map[key] = true;
  }

  int get length => _map.length;
}

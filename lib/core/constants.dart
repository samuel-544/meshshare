/// Global constants for MeshShare.
///
/// BLE MTU is typically 23 bytes; 3 bytes are consumed by ATT overhead,
/// leaving 20 bytes of usable payload per write-without-response packet.
library;

// ── BLE ──────────────────────────────────────────────────────────────────────

/// Usable payload per BLE ATT write (MTU 23 − 3 overhead).
const int kBleChunkPayloadBytes = 20;

/// Default mesh TTL — maximum hop count before a packet is dropped.
const int kDefaultTtl = 7;

/// How often to send a keepalive byte on an idle connection (ms).
const int kKeepaliveIntervalMs = 15000;

/// Missed keepalive count before a peer is considered disconnected.
const int kKeepaliveMaxMissed = 3;

/// Active scanning interval when peers are expected nearby (ms).
const int kScanIntervalActiveMs = 5000;

/// Idle scanning interval when no new peers found for 60 s (ms).
const int kScanIntervalIdleMs = 30000;

/// Re-advertise interval to survive screen-off (ms).
const int kAdvertiseRefreshMs = 60000;

/// Maximum entries in the per-node chunk deduplication LRU cache.
const int kDedupCacheMaxSize = 1000;

// ── File Transfer ─────────────────────────────────────────────────────────────

/// Maximum file size supported in the MVP (50 MB).
const int kMaxFileSizeBytes = 50 * 1024 * 1024;

/// Milliseconds before an unACKed chunk is retransmitted.
const int kChunkRetransmitTimeoutMs = 2000;

// ── GATT UUIDs ────────────────────────────────────────────────────────────────
// Use a base UUID in the Bluetooth SIG "private" range (128-bit custom UUIDs).

/// Primary MeshShare GATT service UUID.
const String kServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

/// RX characteristic — Central writes file chunks to Peripheral.
const String kRxCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

/// TX characteristic — Peripheral notifies ACKs / chunk requests to Central.
const String kTxCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// Identity characteristic — exchange Noise static public-key hash (32 bytes).
const String kIdentityCharUuid = '6e400004-b5a3-f393-e0a9-e50e24dcca9e';

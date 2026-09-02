/// Global constants for MeshShare.
///
/// BLE MTU is typically 23 bytes; 3 bytes are consumed by ATT overhead,
/// leaving 20 bytes of usable payload per write-without-response packet.
library;

// ── BLE ──────────────────────────────────────────────────────────────────────

/// Fallback plaintext payload per chunk when the negotiated ATT MTU is
/// unknown (e.g. before MTU negotiation, or on a link we did not open).
/// Safe on any BLE stack (MTU 23 − 3 overhead).
const int kBleChunkPayloadBytes = 20;

/// MTU we ask each GATT link for. Android caps this at 517; most modern
/// phones grant 512, mid-range devices often 247. The actual chunk size is
/// derived from whatever gets granted — see [BleMeshService.maxChunkPayloadBytes].
const int kRequestedMtu = 512;

/// Fixed per-chunk serialisation overhead (fixed header 99 B incl. checksum,
/// AEAD tag 16 B, mesh type byte 1 B, ATT overhead 3 B) plus an 80 B budget
/// for the file-name field. Subtracted from the negotiated MTU to get the
/// safe plaintext payload size per chunk.
const int kChunkFixedOverheadBytes = 200;

/// Hard cap on plaintext payload per chunk, regardless of MTU — keeps a
/// relay able to forward without exceeding a smaller onward link's MTU.
const int kMaxChunkPayloadBytes = 240;

/// Delay between consecutive write-without-response chunk sends (ms).
/// Write-without-response has no flow control; without a small gap the OS
/// BLE buffer overruns and chunks are silently dropped.
const int kChunkSendSpacingMs = 6;

/// Default mesh TTL — maximum hop count before a packet is dropped.
const int kDefaultTtl = 7;

/// How often to send a keepalive byte on an idle connection (ms).
const int kKeepaliveIntervalMs = 12000;

/// Missed keepalive count before a peer is considered disconnected. Combined
/// with the interval this is ~a minute of total silence — but ANY inbound
/// traffic from the peer (a chunk, an ACK, a notification) resets the
/// counter, so an active transfer never trips it.
const int kKeepaliveMaxMissed = 5;

/// A peer is only declared unreachable if we have neither heard from it nor
/// received a keepalive echo within this window (ms).
const int kPeerUnreachableMs = 45000;

/// Active scanning interval when peers are expected nearby (ms).
const int kScanIntervalActiveMs = 5000;

/// Idle scanning interval when no new peers found for 60 s (ms).
const int kScanIntervalIdleMs = 30000;

/// Re-advertise interval to survive screen-off (ms).
const int kAdvertiseRefreshMs = 60000;

/// Maximum entries in the per-node chunk deduplication LRU cache.
const int kDedupCacheMaxSize = 1000;

// ── Multi-hop mesh routing ───────────────────────────────────────────────────

/// How often each node floods a presence announcement for itself (ms).
const int kAnnounceIntervalMs = 15000;

/// Drop a gossiped (indirect) peer if it hasn't been re-announced within
/// this many ms — roughly 3x the announce interval.
const int kIndirectPeerExpiryMs = 45000;

/// How long to wait for a routed (multi-hop) handshake response before
/// giving up. Longer than the direct handshake timeout to allow for flood
/// propagation across several hops.
const int kRoutedHandshakeTimeoutMs = 12000;

// ── File Transfer ─────────────────────────────────────────────────────────────

/// Maximum file size supported in the MVP (50 MB).
const int kMaxFileSizeBytes = 50 * 1024 * 1024;

/// Milliseconds before an individual unACKed chunk is retransmitted. Only
/// chunks that have actually been silent this long are resent — not the
/// whole transfer.
const int kChunkRetransmitTimeoutMs = 3000;

/// Abandon a transfer only after this many ms of zero forward progress
/// (no new ACKs at all) *while the peer is connected*. A transfer whose peer
/// has dropped is paused, not failed — see [kTransferPeerReconnectMs].
const int kTransferStallTimeoutMs = 45000;

/// How long a paused transfer waits for its peer to come back before it is
/// abandoned (ms). Covers a walk through a dead spot or a quick BT toggle.
const int kTransferPeerReconnectMs = 180000;

/// Number of chunks kept in flight at once (sent but not yet ACKed).
/// ~32 × 240 B ≈ 7.5 KB — enough to saturate a BLE link without overrunning
/// the write-without-response buffer.
const int kTransferWindowSize = 32;

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

import 'package:flutter/foundation.dart';

/// Lightweight diagnostic logging for the mesh / transfer layers.
///
/// No-ops in release builds, so leaving call sites in place costs nothing in
/// production while keeping the wire-level trace available during development
/// (`flutter run`, `adb logcat | grep MeshShare`).
void meshLog(String message) {
  if (kDebugMode) debugPrint('[MeshShare] $message');
}

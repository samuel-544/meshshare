import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// The MeshShare mark — chat bubble fused with the Bluetooth glyph, steel→
/// copper gradient. Backed by the shipped asset so it matches the launcher
/// icon exactly.
class MeshLogo extends StatelessWidget {
  final double size;

  /// When true, sits the mark on a dark rounded-square tile like the app icon.
  final bool tile;

  const MeshLogo({super.key, this.size = 40, this.tile = false});

  @override
  Widget build(BuildContext context) {
    final mark = Image.asset(
      'assets/logo/meshshare_mark.png',
      width: tile ? size * 0.72 : size,
      height: tile ? size * 0.72 : size,
      filterQuality: FilterQuality.high,
    );
    if (!tile) return mark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: MeshColors.surfaceHigh,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: MeshColors.outline),
      ),
      alignment: Alignment.center,
      child: mark,
    );
  }
}

/// Wordmark: the mark tile + "MeshShare" set tight and bold. Used in app bars.
class MeshWordmark extends StatelessWidget {
  final double markSize;
  const MeshWordmark({super.key, this.markSize = 26});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MeshLogo(size: markSize),
        const SizedBox(width: 9),
        const Text(
          'MeshShare',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: MeshColors.text,
          ),
        ),
      ],
    );
  }
}

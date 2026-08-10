import 'package:flutter/material.dart';

import '../file_transfer/transfer_progress.dart';

/// Reusable widget for displaying a single transfer's progress.
class TransferProgressWidget extends StatelessWidget {
  final TransferProgress progress;

  const TransferProgressWidget({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final status = progress.status;
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusIcon(status: status),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value:
                    (status == TransferStatus.sending ||
                        status == TransferStatus.receiving)
                    ? progress.progress
                    : status == TransferStatus.complete
                    ? 1.0
                    : 0.0,
                minHeight: 8,
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: status == TransferStatus.failed
                    ? colorScheme.error
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _statusLabel(status, progress.progress),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(TransferStatus status, double p) {
    switch (status) {
      case TransferStatus.sending:
        return 'Sending… ${(p * 100).toStringAsFixed(0)}%';
      case TransferStatus.receiving:
        return 'Receiving… ${(p * 100).toStringAsFixed(0)}%';
      case TransferStatus.complete:
        return 'Complete';
      case TransferStatus.failed:
        return 'Failed — transfer timed out';
    }
  }
}

class _StatusIcon extends StatelessWidget {
  final TransferStatus status;

  const _StatusIcon({required this.status});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (status) {
      case TransferStatus.sending:
      case TransferStatus.receiving:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case TransferStatus.complete:
        return Icon(
          Icons.check_circle_outline,
          color: colorScheme.primary,
          size: 20,
        );
      case TransferStatus.failed:
        return Icon(Icons.error_outline, color: colorScheme.error, size: 20);
    }
  }
}

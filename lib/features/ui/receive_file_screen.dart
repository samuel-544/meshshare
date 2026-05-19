import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../file_transfer/chunk_model.dart';
import '../file_transfer/transfer_manager.dart';
import '../file_transfer/transfer_progress.dart';
import 'transfer_progress_screen.dart';

class ReceiveFileScreen extends StatefulWidget {
  const ReceiveFileScreen({super.key});

  @override
  State<ReceiveFileScreen> createState() => _ReceiveFileScreenState();
}

class _ReceiveFileScreenState extends State<ReceiveFileScreen> {
  final List<TransferProgress> _activeTransfers = [];
  final List<SavedFile> _completedFiles = [];
  StreamSubscription<TransferProgress>? _progressSub;
  StreamSubscription<SavedFile>? _savedSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _subscribe() {
    final tm = context.read<TransferManager>();

    _progressSub = tm.progress.listen((p) {
      if (!mounted) return;
      if (p.type != PayloadType.file) return;
      setState(() {
        final idx =
            _activeTransfers.indexWhere((t) => t.transferId == p.transferId);
        if (p.status == TransferStatus.receiving) {
          if (idx >= 0) {
            _activeTransfers[idx] = p;
          } else {
            _activeTransfers.add(p);
          }
        } else {
          // complete or failed — remove from active list
          if (idx >= 0) _activeTransfers.removeAt(idx);
        }
      });
    });

    _savedSub = tm.savedFiles.listen((file) {
      if (!mounted) return;
      setState(() => _completedFiles.insert(0, file));
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _savedSub?.cancel();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Received Files')),
      body: CustomScrollView(
        slivers: [
          // Active incoming transfers
          if (_activeTransfers.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Incoming',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) =>
                      TransferProgressWidget(progress: _activeTransfers[i]),
                  childCount: _activeTransfers.length,
                ),
              ),
            ),
          ],
          // Completed files header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Received',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
          ),
          // Completed files list or empty state
          _completedFiles.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 64,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(77),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No files received yet',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withAlpha(128),
                                  ),
                        ),
                      ],
                    ),
                  ),
                )
              : SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final f = _completedFiles[i];
                        return Card(
                          child: ListTile(
                            leading:
                                const Icon(Icons.insert_drive_file_outlined),
                            title: Text(f.name),
                            subtitle: Text(
                              '${_formatBytes(f.sizeBytes)} · '
                              'from ${f.senderPeerId.substring(0, 8)}',
                            ),
                            trailing: Text(
                              _formatTime(f.receivedAt),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        );
                      },
                      childCount: _completedFiles.length,
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
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
    setState(() {
      _completedFiles
        ..clear()
        ..addAll(tm.receivedFiles);
    });

    _progressSub = tm.progress.listen((p) {
      if (!mounted) return;
      if (p.type != PayloadType.file) return;
      setState(() {
        final idx = _activeTransfers.indexWhere(
          (t) => t.transferId == p.transferId,
        );
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

  bool _isImageFile(String path) {
    const imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};
    return imageExtensions.contains(p.extension(path).toLowerCase());
  }

  void _showFilePreview(SavedFile file) {
    if (!_isImageFile(file.path)) return;
    showDialog<void>(
      context: context,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: size.width,
            height: size.height * 0.75,
            child: Column(
              children: [
                AppBar(
                  title: Text(file.name, overflow: TextOverflow.ellipsis),
                  automaticallyImplyLeading: false,
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                Expanded(
                  child: InteractiveViewer(
                    child: Image.file(
                      File(file.path),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Image preview failed.'),
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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
                child: Text(
                  'Incoming',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
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
              child: Text(
                'Received',
                style: Theme.of(context).textTheme.titleSmall,
              ),
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
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(77),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No files received yet',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withAlpha(128),
                              ),
                        ),
                      ],
                    ),
                  ),
                )
              : SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((_, i) {
                      final f = _completedFiles[i];
                      final isImage = _isImageFile(f.path);
                      return Card(
                        child: ListTile(
                          leading: isImage
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.file(
                                    File(f.path),
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            const Icon(
                                              Icons.broken_image_outlined,
                                            ),
                                  ),
                                )
                              : const Icon(Icons.insert_drive_file_outlined),
                          title: Text(f.name),
                          subtitle: Text(
                            '${_formatBytes(f.sizeBytes)} · '
                            'from ${f.senderPeerId.substring(0, 8)}',
                          ),
                          trailing: Text(
                            _formatTime(f.receivedAt),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          onTap: isImage ? () => _showFilePreview(f) : null,
                        ),
                      );
                    }, childCount: _completedFiles.length),
                  ),
                ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../bluetooth/mesh_node.dart';
import '../file_transfer/chunk_model.dart';
import '../file_transfer/transfer_manager.dart';
import '../file_transfer/transfer_progress.dart';
import 'transfer_progress_screen.dart';

class SendFileScreen extends StatefulWidget {
  final MeshNode target;

  const SendFileScreen({super.key, required this.target});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  PlatformFile? _selectedFile;
  TransferProgress? _progress;
  StreamSubscription<TransferProgress>? _progressSub;
  bool _sending = false;

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || !mounted) return;
    setState(() {
      _selectedFile = result.files.first;
      _progress = null;
    });
  }

  Future<void> _sendFile() async {
    final file = _selectedFile;
    if (file?.path == null) return;

    final tm = context.read<TransferManager>();
    setState(() => _sending = true);

    _progressSub?.cancel();
    _progressSub = tm.progress.listen((p) {
      if (!mounted) return;
      if (p.peerId == widget.target.shortId) {
        setState(() => _progress = p);
      }
    });

    try {
      if (!Platform.isAndroid && !Platform.isIOS) {
        // Demo mode: animate a fake transfer progress without real BLE.
        final transferId = 'demo-${DateTime.now().millisecondsSinceEpoch}';
        for (int step = 1; step <= 10; step++) {
          await Future.delayed(const Duration(milliseconds: 250));
          if (!mounted) return;
          setState(() => _progress = TransferProgress(
                transferId: transferId,
                label: file!.name,
                progress: step / 10,
                status: step < 10
                    ? TransferStatus.sending
                    : TransferStatus.complete,
                type: PayloadType.file,
                peerId: widget.target.shortId,
              ));
        }
        return;
      }
      await tm.sendFile(filePath: file!.path!, target: widget.target);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final isDone = p?.status == TransferStatus.complete;
    final isFailed = p?.status == TransferStatus.failed;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Send to ${widget.target.displayName ?? widget.target.shortId.substring(0, 8)}',
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // File selector card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('File',
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    if (_selectedFile == null)
                      OutlinedButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Choose File'),
                      )
                    else
                      Row(
                        children: [
                          const Icon(Icons.insert_drive_file_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _selectedFile!.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  _formatBytes(_selectedFile!.size),
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () =>
                                setState(() => _selectedFile = null),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Recipient card
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(
                    widget.target.displayName ?? 'Unknown Device'),
                subtitle: Text(widget.target.shortId),
              ),
            ),
            const SizedBox(height: 24),
            // Transfer progress
            if (p != null) ...[
              TransferProgressWidget(progress: p),
              const SizedBox(height: 16),
            ],
            // Action button
            if (isFailed)
              OutlinedButton.icon(
                onPressed: _sendFile,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              )
            else if (isDone)
              FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.check),
                label: const Text('Done'),
              )
            else
              FilledButton.icon(
                onPressed:
                    (_selectedFile != null && !_sending) ? _sendFile : null,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send),
                label: Text(_sending ? 'Sending…' : 'Send'),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshshare/features/file_transfer/chunk_model.dart';
import 'package:meshshare/features/file_transfer/transfer_progress.dart';
import 'package:meshshare/features/ui/transfer_progress_screen.dart';

void main() {
  testWidgets(
    'TransferProgressWidget shows label and percentage while sending',
    (WidgetTester tester) async {
      const progress = TransferProgress(
        transferId: 'abc123',
        label: 'photo.jpg',
        progress: 0.4,
        status: TransferStatus.sending,
        type: PayloadType.file,
        peerId: 'peer001',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TransferProgressWidget(progress: progress)),
        ),
      );

      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('Sending… 40%'), findsOneWidget);
    },
  );

  testWidgets('TransferProgressWidget shows "Complete" when done', (
    WidgetTester tester,
  ) async {
    const progress = TransferProgress(
      transferId: 'abc123',
      label: 'report.pdf',
      progress: 1.0,
      status: TransferStatus.complete,
      type: PayloadType.file,
      peerId: 'peer001',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TransferProgressWidget(progress: progress)),
      ),
    );

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('Complete'), findsOneWidget);
  });
}

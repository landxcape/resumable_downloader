import 'package:example/widgets/adaptive_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resumable_downloader/resumable_downloader.dart';

void main() {
  testWidgets('uses one segment for a single-stream task', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AdaptiveProgressBar(
          ranges: <DownloadRangeUpdate>[
            DownloadRangeUpdate(
              startByte: 0,
              endByte: 99,
              receivedBytes: 40,
              status: DownloadStatus.downloading,
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('1 transfer segment'), findsOneWidget);
  });

  testWidgets('uses multiple segments for a multipart task', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AdaptiveProgressBar(
          ranges: <DownloadRangeUpdate>[
            DownloadRangeUpdate(
              startByte: 0,
              endByte: 24,
              receivedBytes: 25,
              status: DownloadStatus.completed,
            ),
            DownloadRangeUpdate(
              startByte: 25,
              endByte: 49,
              receivedBytes: 12,
              status: DownloadStatus.downloading,
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('2 transfer segments'), findsOneWidget);
  });
}

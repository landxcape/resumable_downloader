import 'package:flutter/material.dart';
import 'package:resumable_downloader/resumable_downloader.dart';

class AdaptiveProgressBar extends StatelessWidget {
  const AdaptiveProgressBar({required this.ranges, super.key});

  final List<DownloadRangeUpdate> ranges;

  @override
  Widget build(BuildContext context) {
    final count = ranges.length;
    return Semantics(
      label: '$count transfer segment${count == 1 ? '' : 's'}',
      child: SizedBox(
        height: 8,
        width: double.infinity,
        child: CustomPaint(
          painter: _AdaptiveProgressPainter(
            ranges: ranges,
            colorScheme: Theme.of(context).colorScheme,
          ),
        ),
      ),
    );
  }
}

class _AdaptiveProgressPainter extends CustomPainter {
  const _AdaptiveProgressPainter({
    required this.ranges,
    required this.colorScheme,
  });

  final List<DownloadRangeUpdate> ranges;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (ranges.isEmpty) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = colorScheme.surfaceContainerHighest,
      );
      return;
    }
    final totalBytes = ranges.fold<int>(
      0,
      (sum, range) => sum + range.totalBytes,
    );
    var offset = 0.0;
    for (var index = 0; index < ranges.length; index++) {
      final range = ranges[index];
      final width = size.width * range.totalBytes / totalBytes;
      final rect = Rect.fromLTWH(offset, 0, width, size.height);
      canvas.drawRect(
        rect,
        Paint()..color = colorScheme.surfaceContainerHighest,
      );
      canvas.drawRect(
        Rect.fromLTWH(offset, 0, width * range.progress, size.height),
        Paint()..color = _colorFor(range.status),
      );
      if (index < ranges.length - 1) {
        canvas.drawRect(
          Rect.fromLTWH(offset + width - 1, 0, 1, size.height),
          Paint()..color = colorScheme.surface,
        );
      }
      offset += width;
    }
  }

  Color _colorFor(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.completed ||
      DownloadStatus.downloading => colorScheme.primary,
      DownloadStatus.retrying => colorScheme.tertiary,
      DownloadStatus.failed => colorScheme.error,
      DownloadStatus.cancelled => colorScheme.outline,
      DownloadStatus.queued ||
      DownloadStatus.preparing => colorScheme.outlineVariant,
    };
  }

  @override
  bool shouldRepaint(_AdaptiveProgressPainter oldDelegate) {
    return oldDelegate.ranges != ranges ||
        oldDelegate.colorScheme != colorScheme;
  }
}

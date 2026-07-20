import '../download_configuration.dart';
import '../transport/transfer_probe.dart';
import 'byte_range.dart';

/// The validated byte ranges selected for one file transfer.
class TransferPlan {
  const TransferPlan._(this.ranges);

  final List<ByteRange> ranges;

  bool get isMultipart => ranges.length > 1;

  factory TransferPlan.create({
    required int totalBytes,
    required TransferProbeResult probe,
    required DownloadConfiguration configuration,
  }) {
    if (!probe.supportsRanges ||
        totalBytes < configuration.minimumBytesPerPart * 2) {
      return TransferPlan._(<ByteRange>[ByteRange(0, totalBytes - 1)]);
    }
    final partCount = (totalBytes ~/ configuration.minimumBytesPerPart)
        .clamp(1, configuration.maxConnectionsPerDownload);
    if (partCount < 2) {
      return TransferPlan._(<ByteRange>[ByteRange(0, totalBytes - 1)]);
    }
    final ranges = <ByteRange>[];
    final baseLength = totalBytes ~/ partCount;
    final remainder = totalBytes % partCount;
    var start = 0;
    for (var index = 0; index < partCount; index++) {
      final length = baseLength + (index < remainder ? 1 : 0);
      final end = start + length - 1;
      ranges.add(ByteRange(start, end));
      start = end + 1;
    }
    return TransferPlan._(List.unmodifiable(ranges));
  }
}

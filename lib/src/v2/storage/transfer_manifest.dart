import '../transfers/byte_range.dart';
import '../transfers/transfer_key.dart';

/// V2 resume metadata stored separately from the final output file.
class TransferManifest {
  TransferManifest({
    required this.key,
    required this.sourceUri,
    required this.outputFileName,
    required this.totalBytes,
    required List<TransferRangeCheckpoint> ranges,
    this.entityTag,
    this.lastModified,
  }) : ranges = List.unmodifiable(ranges) {
    if (totalBytes <= 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'must be positive');
    }
    if (outputFileName.isEmpty ||
        outputFileName.contains('/') ||
        outputFileName.contains('\\')) {
      throw ArgumentError.value(
        outputFileName,
        'outputFileName',
        'must be a file name',
      );
    }
    final plannedRanges =
        this.ranges.map((checkpoint) => checkpoint.range).toSet();
    if (plannedRanges.length != this.ranges.length ||
        this.ranges.any((checkpoint) => checkpoint.range.end >= totalBytes)) {
      throw ArgumentError.value(
        ranges,
        'ranges',
        'must be unique and in bounds',
      );
    }
  }

  static const int formatVersion = 2;

  final TransferKey key;
  final Uri sourceUri;
  final String outputFileName;
  final int totalBytes;
  final String? entityTag;
  final String? lastModified;
  final List<TransferRangeCheckpoint> ranges;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': formatVersion,
    'key': key.value,
    'sourceUri': sourceUri.toString(),
    'outputFileName': outputFileName,
    'totalBytes': totalBytes,
    'entityTag': entityTag,
    'lastModified': lastModified,
    'ranges': ranges
        .map((checkpoint) => checkpoint.toJson())
        .toList(growable: false),
  };

  factory TransferManifest.fromJson(Map<String, Object?> json) {
    if (json['version'] != formatVersion ||
        json['key'] is! String ||
        json['sourceUri'] is! String ||
        json['outputFileName'] is! String ||
        json['totalBytes'] is! int ||
        json['ranges'] is! List<Object?>) {
      throw const FormatException('Invalid V2 transfer manifest');
    }
    final totalBytes = json['totalBytes']! as int;
    if (totalBytes <= 0) {
      throw const FormatException('Invalid V2 transfer manifest length');
    }
    final sourceUri = Uri.tryParse(json['sourceUri']! as String);
    if (sourceUri == null || !sourceUri.hasScheme) {
      throw const FormatException('Invalid V2 transfer manifest source URI');
    }
    final ranges = <TransferRangeCheckpoint>[];
    for (final value in json['ranges']! as List<Object?>) {
      if (value is! Map<Object?, Object?>) {
        throw const FormatException('Invalid V2 transfer manifest range');
      }
      final checkpoint = TransferRangeCheckpoint.fromJson(value);
      if (checkpoint.range.end >= totalBytes) {
        throw const FormatException('Out-of-bounds V2 transfer manifest range');
      }
      ranges.add(checkpoint);
    }
    try {
      return TransferManifest(
        key: TransferKey(json['key']! as String),
        sourceUri: sourceUri,
        outputFileName: json['outputFileName']! as String,
        totalBytes: totalBytes,
        entityTag: json['entityTag'] as String?,
        lastModified: json['lastModified'] as String?,
        ranges: ranges,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid V2 transfer manifest: $error');
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! TransferManifest ||
        other.key != key ||
        other.sourceUri != sourceUri ||
        other.outputFileName != outputFileName ||
        other.totalBytes != totalBytes ||
        other.entityTag != entityTag ||
        other.lastModified != lastModified ||
        other.ranges.length != ranges.length) {
      return false;
    }
    for (var index = 0; index < ranges.length; index++) {
      if (other.ranges[index] != ranges[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    key,
    sourceUri,
    outputFileName,
    totalBytes,
    entityTag,
    lastModified,
    Object.hashAll(ranges),
  );
}

/// Durable progress for one planned range. It may be incomplete after a pause.
class TransferRangeCheckpoint {
  TransferRangeCheckpoint({required this.range, required this.receivedBytes}) {
    if (receivedBytes < 0 || receivedBytes > range.length) {
      throw ArgumentError.value(
        receivedBytes,
        'receivedBytes',
        'must be within the assigned range',
      );
    }
  }

  final ByteRange range;
  final int receivedBytes;

  bool get isComplete => receivedBytes == range.length;

  Map<String, int> toJson() => <String, int>{
    'start': range.start,
    'end': range.end,
    'receivedBytes': receivedBytes,
  };

  factory TransferRangeCheckpoint.fromJson(Map<Object?, Object?> json) {
    if (json['start'] is! int ||
        json['end'] is! int ||
        json['receivedBytes'] is! int) {
      throw const FormatException('Invalid V2 transfer range checkpoint');
    }
    try {
      return TransferRangeCheckpoint(
        range: ByteRange(json['start']! as int, json['end']! as int),
        receivedBytes: json['receivedBytes']! as int,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid V2 transfer range checkpoint: $error');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TransferRangeCheckpoint &&
      other.range == range &&
      other.receivedBytes == receivedBytes;

  @override
  int get hashCode => Object.hash(range, receivedBytes);
}

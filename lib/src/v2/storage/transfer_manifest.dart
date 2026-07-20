import '../transfers/byte_range.dart';
import '../transfers/transfer_key.dart';

/// V2 resume metadata stored separately from the final output file.
class TransferManifest {
  const TransferManifest({
    required this.key,
    required this.outputPath,
    required this.totalBytes,
    required this.completedRanges,
    this.entityTag,
    this.lastModified,
  })  : assert(totalBytes > 0),
        assert(completedRanges.length >= 0);

  static const int formatVersion = 1;

  final TransferKey key;
  final String outputPath;
  final int totalBytes;
  final String? entityTag;
  final String? lastModified;
  final List<ByteRange> completedRanges;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        'key': key.value,
        'outputPath': outputPath,
        'totalBytes': totalBytes,
        'entityTag': entityTag,
        'lastModified': lastModified,
        'completedRanges': completedRanges
            .map((range) => <String, int>{'start': range.start, 'end': range.end})
            .toList(growable: false),
      };

  factory TransferManifest.fromJson(Map<String, Object?> json) {
    if (json['version'] != formatVersion ||
        json['key'] is! String ||
        json['outputPath'] is! String ||
        json['totalBytes'] is! int ||
        json['completedRanges'] is! List<Object?>) {
      throw const FormatException('Invalid V2 transfer manifest');
    }
    final totalBytes = json['totalBytes']! as int;
    if (totalBytes <= 0) {
      throw const FormatException('Invalid V2 transfer manifest length');
    }
    final ranges = <ByteRange>[];
    for (final value in json['completedRanges']! as List<Object?>) {
      if (value is! Map<Object?, Object?> ||
          value['start'] is! int ||
          value['end'] is! int) {
        throw const FormatException('Invalid V2 transfer manifest range');
      }
      final range = ByteRange(value['start']! as int, value['end']! as int);
      if (range.end >= totalBytes) {
        throw const FormatException('Out-of-bounds V2 transfer manifest range');
      }
      ranges.add(range);
    }
    return TransferManifest(
      key: TransferKey(json['key']! as String),
      outputPath: json['outputPath']! as String,
      totalBytes: totalBytes,
      entityTag: json['entityTag'] as String?,
      lastModified: json['lastModified'] as String?,
      completedRanges: List.unmodifiable(ranges),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! TransferManifest ||
        other.key != key ||
        other.outputPath != outputPath ||
        other.totalBytes != totalBytes ||
        other.entityTag != entityTag ||
        other.lastModified != lastModified ||
        other.completedRanges.length != completedRanges.length) {
      return false;
    }
    for (var index = 0; index < completedRanges.length; index++) {
      if (other.completedRanges[index] != completedRanges[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        key,
        outputPath,
        totalBytes,
        entityTag,
        lastModified,
        Object.hashAll(completedRanges),
      );
}

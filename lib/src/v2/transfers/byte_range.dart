/// An inclusive byte range used by one V2 range worker.
class ByteRange {
  const ByteRange(this.start, this.end)
      : assert(start >= 0),
        assert(end >= start);

  final int start;
  final int end;

  int get length => end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

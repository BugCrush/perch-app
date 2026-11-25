// Hybrid logical clock: the version of every board record group
// (docs/superpowers/specs/2026-11-24-projects-first-board-design.md, 4.2). A version is
// (milliseconds, counter, writer); every writer keeps its clock moving forward past
// anything it has seen, so "newer" stays newer between devices whose clocks disagree.
//
// Encoded as `<ms, 15 digits>-<counter, 6 digits>-<writer>`, so comparing the strings
// orders them like the clocks (the relay compares the strings, never reads anything else).

final _encoded = RegExp(r'^(\d{15})-(\d{6})-([^-]+)$');

String _cleanWriter(String w) => w.replaceAll('-', '_');

class Hlc implements Comparable<Hlc> {
  final int ms;
  final int counter;
  final String writer;

  Hlc(this.ms, this.counter, String writer) : writer = _cleanWriter(writer);
  const Hlc._(this.ms, this.counter, this.writer);

  /// Older than every real version.
  static const zero = Hlc._(0, 0, '0');

  String encode() => '${ms.toString().padLeft(15, '0')}-${counter.toString().padLeft(6, '0')}-$writer';

  static Hlc? parse(String s) {
    final m = _encoded.firstMatch(s);
    if (m == null) return null;
    return Hlc._(int.parse(m.group(1)!), int.parse(m.group(2)!), m.group(3)!);
  }

  @override
  int compareTo(Hlc other) {
    if (ms != other.ms) return ms.compareTo(other.ms);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return writer.compareTo(other.writer);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is Hlc && other.ms == ms && other.counter == counter && other.writer == writer;
  @override
  int get hashCode => Object.hash(ms, counter, writer);
  @override
  String toString() => encode();
}

/// One writer's clock.
class HlcClock {
  final String writer;
  final DateTime Function() _now;
  Hlc _last;

  HlcClock(String writer, {DateTime Function()? now})
      : writer = _cleanWriter(writer),
        _now = now ?? DateTime.now,
        _last = Hlc.zero;

  Hlc get last => _last;

  /// A version newer than anything this clock has made or seen.
  Hlc tick() {
    final wall = _now().millisecondsSinceEpoch;
    final ms = wall > _last.ms ? wall : _last.ms;
    final counter = ms == _last.ms ? _last.counter + 1 : 0;
    return _last = Hlc(ms, counter, writer);
  }

  /// Takes note of a version seen elsewhere: the next tick goes past it.
  void observe(Hlc seen) {
    if (seen > _last) _last = Hlc._(seen.ms, seen.counter, seen.writer);
  }
}

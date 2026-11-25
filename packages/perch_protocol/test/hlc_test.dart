import 'dart:math';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('tick_is_strictly_increasing_even_when_the_wall_clock_goes_back', () {
    var now = 1000;
    final c = HlcClock('phone', now: () => DateTime.fromMillisecondsSinceEpoch(now));
    final a = c.tick();
    now = 900;
    final b = c.tick();
    expect(a.ms, 1000);
    expect(a.counter, 0);
    expect(b.ms, 1000);
    expect(b.counter, 1);
    expect(b.compareTo(a), greaterThan(0));
    now = 2000;
    final d = c.tick();
    expect(d.ms, 2000);
    expect(d.counter, 0);
  });

  test('observe_moves_past_a_faster_device', () {
    final c = HlcClock('pc', now: () => DateTime.fromMillisecondsSinceEpoch(1000));
    final seen = Hlc(5000, 3, 'phone');
    c.observe(seen);
    final t = c.tick();
    expect(t.compareTo(seen), greaterThan(0));
    expect(t.writer, 'pc');
    expect(c.last, t);
  });

  test('ties_break_on_writer', () {
    expect(Hlc(1, 1, 'a').compareTo(Hlc(1, 1, 'b')), lessThan(0));
    expect(Hlc(1, 1, 'b').compareTo(Hlc(1, 1, 'a')), greaterThan(0));
    expect(Hlc(1, 1, 'a').compareTo(Hlc(1, 1, 'a')), 0);
    expect(Hlc(1, 1, 'a'), Hlc(1, 1, 'a'));
  });

  test('encode_parse_roundtrip_and_string_order_equals_clock_order', () {
    final r = Random(7);
    Hlc rnd() => Hlc(r.nextInt(1 << 31) * (r.nextBool() ? 1000 : 1), r.nextInt(5), 'w${r.nextInt(3)}');
    for (var i = 0; i < 100; i++) {
      final a = rnd(), b = rnd();
      expect(Hlc.parse(a.encode()), a);
      expect(a.compareTo(b).sign, a.encode().compareTo(b.encode()).sign, reason: '$a vs $b');
    }
    expect(Hlc.zero.encode().compareTo(Hlc(1, 0, 'a').encode()), lessThan(0));
  });

  test('writer_dashes_become_underscores', () {
    final h = Hlc(5, 0, 'a-b-c');
    expect(h.writer, 'a_b_c');
    expect(Hlc.parse(h.encode()), h);
    expect(HlcClock('x-y').tick().writer, 'x_y');
  });

  test('parse_rejects_garbage', () {
    expect(Hlc.parse('x'), isNull);
    expect(Hlc.parse(''), isNull);
    expect(Hlc.parse('000000000001000-000001'), isNull);
    expect(Hlc.parse('000000000001000--w'), isNull);
    expect(Hlc.parse('abc-000001-w'), isNull);
    expect(Hlc.parse('000000000001000-000001-'), isNull);
  });
}

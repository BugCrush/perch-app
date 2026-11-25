import 'dart:convert';
import 'dart:math';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

HlcClock clockAt(String writer, int ms) => HlcClock(writer, now: () => DateTime.fromMillisecondsSinceEpoch(ms));

const day = 24 * 60 * 60 * 1000;

void main() {
  test('per_group_newest_wins', () {
    final phone = Board(), machine = Board();
    final pc = clockAt('phone', 1000), mc = clockAt('win', 2000);
    phone.put(RecordKinds.task, 't1', {'content': {'title': 'From phone'}}, pc);
    machine.put(RecordKinds.task, 't1', {'run': {'report': {'text': 'done'}}}, mc);
    for (final r in phone.records.toList()) {
      machine.merge(r);
    }
    for (final r in machine.records.toList()) {
      phone.merge(r);
    }
    for (final b in [phone, machine]) {
      final r = b.get(RecordKinds.task, 't1')!;
      expect(r.groups['content']!.value['title'], 'From phone');
      expect((r.groups['run']!.value['report'] as Map)['text'], 'done');
    }
    expect(jsonEncode(phone.toJson()), jsonEncode(machine.toJson()));
  });

  test('older_group_never_overwrites_newer', () {
    final b = Board();
    b.put(RecordKinds.task, 't', {'content': {'title': 'new'}}, clockAt('a', 5000));
    final old = BoardRecord(RecordKinds.task, 't', {'content': BoardGroup({'title': 'old'}, Hlc(4000, 0, 'b'))});
    expect(b.merge(old), isFalse);
    expect(b.get(RecordKinds.task, 't')!.groups['content']!.value['title'], 'new');
    // A slower clock that has seen the newer version still wins afterwards.
    final slow = clockAt('slow', 1000);
    expect(b.merge(old, clock: slow), isFalse);
    slow.observe(b.get(RecordKinds.task, 't')!.newest);
    final later = b.put(RecordKinds.task, 't', {'content': {'title': 'later on the slow device'}}, slow);
    expect(later.groups['content']!.value['title'], 'later on the slow device');
    expect(later.groups['content']!.version.ms, 5000);
  });

  test('merge_observes_the_incoming_clock', () {
    final b = Board();
    final c = clockAt('pc', 1000);
    b.merge(BoardRecord(RecordKinds.task, 't', {'content': BoardGroup({'title': 'x'}, Hlc(90000, 2, 'phone'))}), clock: c);
    expect(c.tick() > Hlc(90000, 2, 'phone'), isTrue);
  });

  test('merge_is_commutative_and_idempotent', () {
    final r = Random(3);
    final clocks = [for (final w in ['a', 'b', 'c']) clockAt(w, 1000 + r.nextInt(50))];
    final updates = <BoardRecord>[];
    final source = Board();
    for (var i = 0; i < 50; i++) {
      final c = clocks[r.nextInt(3)];
      final group = ['content', 'column', 'run', 'life'][r.nextInt(4)];
      updates.add(source.put(RecordKinds.task, 't${r.nextInt(5)}', {group: {'n': i}}, c));
      // Only the changed group, as a device would send it.
    }
    final replicas = [Board(), Board(), Board()];
    for (final rep in replicas) {
      final order = [...updates]..shuffle(r);
      for (final u in order) {
        rep.merge(u);
      }
      for (final u in order.take(10)) {
        expect(rep.merge(u), isFalse);
      }
    }
    final a = jsonEncode(replicas[0].toJson());
    expect(jsonEncode(replicas[1].toJson()), a);
    expect(jsonEncode(replicas[2].toJson()), a);
  });

  test('summary_and_newerThan_send_only_what_is_missing', () {
    final a = Board(), b = Board();
    final ca = clockAt('a', 1000), cb = clockAt('b', 1000);
    final shared = a.put(RecordKinds.task, 'same', {'content': {'title': 's'}}, ca);
    b.merge(shared);
    a.put(RecordKinds.task, 'onlyA', {'content': {'title': 'a'}}, ca);
    b.put(RecordKinds.task, 'onlyB', {'content': {'title': 'b'}}, cb);
    a.put(RecordKinds.task, 'same', {'column': {'column': 'ready'}}, ca);
    final summary = b.summary();
    expect(summary['task/same']!.keys, ['content']);
    final send = a.newerThan(summary);
    expect({for (final r in send) r.key}, {'task/onlyA', 'task/same'});
    expect(b.newerThan(a.summary()).map((r) => r.key), ['task/onlyB']);
    for (final r in send) {
      b.merge(r);
    }
    expect(a.newerThan(b.summary()), isEmpty);
  });

  test('an_edit_to_a_deleted_task_keeps_it_deleted', () {
    final b = Board();
    b.put(RecordKinds.task, 't', {'content': {'title': 'v1'}}, clockAt('a', 1000));
    b.merge(BoardRecord(RecordKinds.task, 't', {'life': BoardGroup({'deleted': true, 'deletedAtMs': 5000}, Hlc(5000, 0, 'a'))}));
    b.merge(BoardRecord(RecordKinds.task, 't', {'content': BoardGroup({'title': 'v6'}, Hlc(6000, 0, 'offline'))}));
    final r = b.get(RecordKinds.task, 't')!;
    expect(r.deleted, isTrue);
    expect(r.groups['content']!.value['title'], 'v6');
  });

  test('prune_drops_tombstones_after_180_days_only', () {
    final now = 400 * day;
    final b = Board();
    BoardRecord dead(String id, int deletedAt) => BoardRecord(
        RecordKinds.task, id, {'life': BoardGroup({'deleted': true, 'deletedAtMs': deletedAt}, Hlc(deletedAt, 0, 'a'))});
    b.merge(dead('old', now - 181 * day));
    b.merge(dead('recent', now - 179 * day));
    b.merge(BoardRecord(RecordKinds.task, 'alive', {'content': BoardGroup({'title': 'x'}, Hlc(1, 0, 'a'))}));
    b.merge(BoardRecord(
        RecordKinds.task, 'restored', {'life': BoardGroup({'deleted': false, 'deletedAtMs': 1}, Hlc(1, 0, 'a'))}));
    expect(b.prune(now), 1);
    expect(b.get(RecordKinds.task, 'old'), isNull);
    expect(b.get(RecordKinds.task, 'recent'), isNotNull);
    expect(b.get(RecordKinds.task, 'alive'), isNotNull);
    expect(b.get(RecordKinds.task, 'restored'), isNotNull);
  });

  test('json_roundtrip', () {
    final b = Board();
    final c = clockAt('a', 1000);
    b.put(RecordKinds.task, 't', {
      'content': {'title': 'x', 'acceptance': ['one', 'two']},
      'column': {'column': 'ready'}
    }, c);
    b.put(RecordKinds.project, 'p', {'content': {'name': 'Perch'}}, c);
    b.put(RecordKinds.modelTable, 'main', {'content': {'rows': []}}, c);
    final text = jsonEncode(b.toJson());
    final back = Board.fromJson(jsonDecode(text));
    expect(jsonEncode(back.toJson()), text);
    expect(back.get(RecordKinds.task, 't')!.key, 'task/t');
    expect(back.records.length, 3);
  });

  test('unknown_kinds_and_bad_groups_are_skipped_not_thrown', () {
    expect(BoardRecord.tryFromJson({'kind': 'weird', 'id': 'x', 'groups': {}}), isNull);
    expect(BoardRecord.tryFromJson('nope'), isNull);
    expect(BoardRecord.tryFromJson({'kind': 'task', 'id': '', 'groups': {}}), isNull);
    final r = BoardRecord.tryFromJson({
      'kind': 'task',
      'id': 't',
      'groups': {
        'content': {'v': Hlc(1, 0, 'a').encode(), 'value': {'title': 'ok'}},
        'column': {'v': 'garbage', 'value': {}},
        'run': {'v': Hlc(1, 0, 'a').encode(), 'value': 'not a map'},
        'life': 3,
      }
    })!;
    expect(r.groups.keys, ['content']);
    final b = Board.fromJson({
      'records': [
        {'kind': 'weird', 'id': 'x', 'groups': {}},
        r.toJson(),
        42,
      ]
    });
    expect(b.records.length, 1);
    expect(Board.fromJson(null).records, isEmpty);
  });
}

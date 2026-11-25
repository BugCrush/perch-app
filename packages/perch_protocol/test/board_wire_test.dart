import 'dart:convert';

import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

BoardRecord rec(String id, String title) =>
    BoardRecord(RecordKinds.task, id, {'content': BoardGroup({'title': title}, Hlc(5, 1, 'phone'))});

void main() {
  final summary = {
    'task/t1': {'content': Hlc(5, 1, 'phone').encode(), 'run': Hlc(6, 0, 'win').encode()}
  };

  test('board_summary_roundtrips_both_ways', () {
    final a = decodeClient(encodeClient(BoardSummaryFromApp(summary: summary))) as BoardSummaryFromApp;
    expect(a.summary, summary);
    final h = decodeHost(encodeHost(BoardSummaryFromHost(summary: summary))) as BoardSummaryFromHost;
    expect(h.summary, summary);
    expect(BoardSummaryFromApp(summary: summary).type, 'boardSummary');
    expect(BoardSummaryFromHost(summary: summary).type, 'boardSummary');
  });

  test('board_records_roundtrip_both_ways', () {
    final rs = [rec('t1', 'One'), rec('t2', 'Two')];
    final a = decodeClient(encodeClient(BoardRecordsFromApp(records: rs))) as BoardRecordsFromApp;
    expect([for (final r in a.records) jsonEncode(r.toJson())], [for (final r in rs) jsonEncode(r.toJson())]);
    final h = decodeHost(encodeHost(BoardRecordsFromHost(records: rs))) as BoardRecordsFromHost;
    expect(h.records.map((r) => r.id), ['t1', 't2']);
  });

  test('board_key_roundtrips_both_ways', () {
    final v = Hlc(9, 0, 'phone').encode();
    final a = decodeClient(encodeClient(BoardKeyFromApp(boardId: 'b' * 22, key: 'k' * 43, keyVersion: v))) as BoardKeyFromApp;
    expect((a.boardId, a.key, a.keyVersion), ('b' * 22, 'k' * 43, v));
    final h = decodeHost(encodeHost(BoardKeyFromHost(boardId: 'c' * 22, key: 'q' * 43, keyVersion: v))) as BoardKeyFromHost;
    expect((h.boardId, h.key, h.keyVersion), ('c' * 22, 'q' * 43, v));
    expect(decodeClient(jsonEncode({'type': 'boardKey', 'boardId': 'x', 'key': '', 'keyVersion': v})), isNull);
    expect(decodeHost(jsonEncode({'type': 'boardKey', 'boardId': 'x', 'key': 'k', 'keyVersion': 'bad'})), isNull);
  });

  test('welcome_without_boardSync_reads_false', () {
    final w = decodeHost(jsonEncode({'type': 'welcome', 'machineName': 'PC', 'os': 'windows', 'hostVersion': '0.3.0'}))
        as Welcome;
    expect(w.boardSync, isFalse);
    final w2 = decodeHost(encodeHost(const Welcome(machineName: 'PC', os: 'windows', hostVersion: '0.4.0', boardSync: true)))
        as Welcome;
    expect(w2.boardSync, isTrue);
  });

  test('a_record_list_with_a_broken_record_keeps_the_good_ones', () {
    final frame = jsonEncode({
      'type': 'boardRecords',
      'records': [
        rec('t1', 'One').toJson(),
        {'kind': 'nonsense'},
        'x',
        rec('t2', 'Two').toJson(),
      ]
    });
    expect((decodeHost(frame) as BoardRecordsFromHost).records.map((r) => r.id), ['t1', 't2']);
    expect((decodeClient(frame) as BoardRecordsFromApp).records.map((r) => r.id), ['t1', 't2']);
  });
}

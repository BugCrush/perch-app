import 'package:perch_host/src/approval_dialog.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  const r = PendingDevice(id: '3f9a77', name: 'Pixel "9" ✓', route: 'relay', requestedAtMs: 1);

  test('the question names the device, its code and route', () {
    final t = approvalText('Studio', r);
    expect(t, contains('"Pixel "9" ✓" (3f9a, over the relay)'));
    expect(t, contains('Studio'));
    expect(routeText('192.168.1.5'), 'from 192.168.1.5');
  });

  test('the macOS dialog has the three buttons, Deny by default, and gives up', () {
    final s = macDialogScript(approvalText('Studio', r), 5);
    expect(s, contains('buttons {"Deny", "Watch only", "Allow"} default button "Deny"'));
    expect(s, contains(r'\"9\"'), reason: 'quotes escaped');
    expect(s, endsWith('giving up after 5'));
  });

  test('macOS answers are read from stdout', () {
    expect(parseMacDialog('button returned:Allow, gave up:false\n'), DeviceDecisions.full);
    expect(parseMacDialog('button returned:Watch only, gave up:false'), DeviceDecisions.watch);
    expect(parseMacDialog('button returned:Deny, gave up:false'), DeviceDecisions.deny);
    expect(parseMacDialog('button returned:, gave up:true'), isNull);
    expect(parseMacDialog(''), isNull);
  });

  test('the Windows script is plain ASCII and prints its decision', () {
    final s = windowsDialogScript(approvalText('Studio', r), 300);
    expect(s.codeUnits.every((c) => c < 128), isTrue);
    expect(s, contains("'Watch only', 'watch'"));
    expect(s, contains('300000'));
    expect(s, contains("Pixel \"9\" ?"));
    expect(parseWindowsDialog('decision:full\r\n'), DeviceDecisions.full);
    expect(parseWindowsDialog('decision:\r\n'), isNull);
    expect(parseWindowsDialog('decision:root'), isNull);
  });

  test('the dialog is on unless PERCH_APPROVAL_DIALOG=0', () {
    expect(approvalDialogEnabled(const {}), isTrue);
    expect(approvalDialogEnabled(const {'PERCH_APPROVAL_DIALOG': '0'}), isFalse);
    expect(approvalDialogSeconds(const {}), 300);
    expect(approvalDialogSeconds(const {'PERCH_APPROVAL_DIALOG_SECONDS': '5'}), 5);
  });
}

import 'dart:io';

import 'package:perch_host/src/state_dir.dart';
import 'package:test/test.dart';

void main() {
  test('perch_state_dir_overrides_the_default', () {
    expect(stateDirectory(environment: {'PERCH_STATE_DIR': '/s/test-host', 'HOME': '/h', 'APPDATA': r'C:\a'}), '/s/test-host');
    if (Platform.isWindows) {
      expect(stateDirectory(environment: {'APPDATA': r'C:\a'}), r'C:\a\perch');
    } else {
      expect(stateDirectory(environment: {'HOME': '/h', 'PERCH_STATE_DIR': ''}), '/h/.perch');
    }
  });
}

// Writes the macOS key helper's Swift source into a folder and prints the file name the
// host looks for (perch-mac-helper-<hash of the source>). The release workflow compiles it
// on a Mac runner (swiftc -O) and ships it next to the compiled host.
//   dart run tool/mac_helper_source.dart <folder>
import 'dart:io';

import 'package:perch_host/src/mac_helper.dart';

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? '.' : args.first)..createSync(recursive: true);
  File('${dir.path}/perch_mac_helper.swift').writeAsStringSync(helperSource);
  stdout.writeln(MacHelper.fileName);
}

// "Update available" on the first screen: a newer Perch release than this app, with
// Download (the APK in the phone's browser; Android then offers to install it over this
// one, signed with the same key) and Later (not again for that version).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;

import '../state/providers.dart';
import '../update_check.dart';
import 'glass/click.dart';
import 'glass/mosaic.dart';
import 'glass/widgets.dart';

/// The line the menu's About shows for the app's version.
String versionLine(String current, ReleaseInfo? available) =>
    available == null ? 'Version $current' : 'Version $current · ${available.version} available';

class UpdateNotice extends ConsumerWidget {
  const UpdateNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checker = ref.watch(updateCheckerProvider);
    final open = ref.watch(updateOpenerProvider);
    return ListenableBuilder(
      listenable: checker,
      builder: (context, _) {
        final a = checker.available;
        if (a == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Frost(
            key: const ValueKey('update-notice'),
            tone: G.deep,
            tint: 0.6,
            rim: true,
            radius: 22,
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(children: [
              const Icon(Icons.system_update_rounded, size: 18, color: G.glow),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Perch ${a.version} is available', style: gSans(13.5, FontWeight.w700, color: G.glow)),
              ),
              ClickDetector(
                key: const ValueKey('update-later'),
                behavior: HitTestBehavior.opaque,
                onTap: checker.dismiss,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text('Later', style: gSans(13, FontWeight.w600, color: G.muted)),
                ),
              ),
              ClickDetector(
                key: const ValueKey('update-download'),
                behavior: HitTestBehavior.opaque,
                onTap: () => open(Uri.parse(a.downloadUrl)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text('Download', style: gSans(13, FontWeight.w800)),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

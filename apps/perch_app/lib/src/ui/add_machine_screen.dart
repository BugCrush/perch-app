// Adding (or pairing again) a machine: scan the QR code the host shows, or paste its link.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:perch_protocol/perch_protocol.dart';

import '../state/providers.dart';
import 'app_theme.dart';
import 'glass/mosaic.dart';
import 'glass/widgets.dart';

/// Builds a camera view that calls back with each QR code's text.
typedef QrScannerBuilder = Widget Function(BuildContext context, void Function(String text) onCode);

Widget _mobileScanner(BuildContext context, void Function(String text) onCode) => MobileScanner(
      onDetect: (capture) {
        for (final b in capture.barcodes) {
          final v = b.rawValue;
          if (v != null) onCode(v);
        }
      },
    );

/// The camera scanner, on Android only (elsewhere the link is pasted).
final qrScannerProvider = Provider<QrScannerBuilder?>((ref) => !kIsWeb && Platform.isAndroid ? _mobileScanner : null);

const notALinkText = 'This is not a Perch pairing link. On the computer run: perch_host pair';

/// Opens the pairing screen; [replacing] is the machine being paired again.
Future<void> openAddMachine(BuildContext context, {String? replacing}) =>
    openGlass<void>(context, AddMachineScreen(replacing: replacing));

class AddMachineScreen extends ConsumerStatefulWidget {
  /// The id of the machine whose "Pair again" opened this screen.
  final String? replacing;

  /// A pairing link to use at once (the phone's camera opened Perch with it).
  final String? initialLink;
  const AddMachineScreen({super.key, this.replacing, this.initialLink});

  @override
  ConsumerState<AddMachineScreen> createState() => _AddMachineScreenState();
}

class _AddMachineScreenState extends ConsumerState<AddMachineScreen> {
  final _link = TextEditingController();
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final link = widget.initialLink;
    if (link != null) {
      _link.text = link;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_use(link));
      });
    }
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _use(String text, {bool fromCamera = false}) async {
    if (_done) return;
    final link = PairingLink.parse(text);
    if (link == null) {
      // The camera sees other codes too: only a pasted link earns an error.
      if (!fromCamera) setState(() => _error = notALinkText);
      return;
    }
    _done = true;
    final m = await ref.read(machinesProvider.notifier).pair(link, replacing: widget.replacing);
    if (!mounted) return;
    await ref.read(pushServiceProvider).afterPairing(context, m);
    if (!mounted) return;
    say(context, 'Paired with ${m.displayName}');
    Navigator.of(context).pop(m.id);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text;
    if (t == null) return;
    _link.text = t.trim();
    await _use(_link.text);
  }

  @override
  Widget build(BuildContext context) {
    final scanner = ref.watch(qrScannerProvider);
    final again = widget.replacing != null;
    return GlassScaffold(
      background: MosaicBackdrop(seed: 11, fade: G.deep, fadeFrom: 0.3, pixel: 0.65, flap: true),
      child: ListView(
        padding: screenPadding(context),
        children: [
          Row(children: [
            GlassOrb(
                key: const ValueKey('back'),
                icon: Icons.arrow_back_rounded,
                label: 'Back',
                onTap: () => Navigator.of(context).maybePop()),
          ]),
          const SizedBox(height: 36),
          Text(again ? 'Pair again' : 'Add machine', style: gSerif(38, w: FontWeight.w500, height: 1.05).copyWith(shadows: lift)),
          const SizedBox(height: 8),
          Text('On the computer, start the Perch host (or run perch_host pair) to show its pairing QR code.',
              style: gSans(14.5, FontWeight.w600).copyWith(shadows: lift)),
          const SizedBox(height: 20),
          if (scanner != null) ...[
            Frost(
              rim: true,
              radius: 30,
              padding: const EdgeInsets.all(8),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: scanner(context, (t) => _use(t, fromCamera: true)),
                ),
              ),
            ),
            const SizedBox(height: 22),
          ],
          Frost(
            tone: G.deep,
            tint: 0.5,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(scanner != null ? 'Or paste the pairing link' : 'Paste the pairing link the host printed',
                  style: gSans(15, FontWeight.w700)),
              const SizedBox(height: 12),
              GlassField(
                controller: _link,
                label: 'Pairing link',
                hint: 'perch://pair?...',
                maxLines: 3,
                keyboardType: TextInputType.url,
                error: _error,
                onSubmitted: _use,
              ),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                GlassButton(label: 'Paste', icon: Icons.content_paste_rounded, onTap: _paste),
                const SizedBox(width: 10),
                GlassButton(label: 'Pair', warm: true, onTap: () => _use(_link.text)),
              ]),
            ]),
          ),
        ],
      ),
    );
  }
}

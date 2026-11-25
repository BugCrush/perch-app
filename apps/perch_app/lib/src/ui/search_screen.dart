// Full-text search across every conversation on every connected machine: the owner types,
// each machine searches its own transcripts (SearchSessions), and the matches show grouped
// by machine, newest conversations first. A tap opens the conversation, also an old one the
// machine did not list (it is then listed as not running).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:perch_protocol/perch_protocol.dart';

import '../connection/host_connection.dart';
import '../time_format.dart';
import 'glass/click.dart';
import 'glass/mosaic.dart';
import 'glass/widgets.dart';
import 'session_row.dart' show openSessionScreen;

typedef OpenSearchHit = void Function(BuildContext context, HostConnection connection, String sessionId);

/// The shortest search sent to the machines.
const minSearchChars = 2;

class SearchScreen extends StatefulWidget {
  final List<HostConnection> connections;
  final OpenSearchHit onOpen;
  const SearchScreen({super.key, required this.connections, this.onOpen = openSessionScreen});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// What one machine answered for the current search.
class _MachineResult {
  final SearchResults? results;

  /// The machine cannot search (an older host).
  final bool older;
  const _MachineResult({this.results, this.older = false});
}

class _SearchScreenState extends State<SearchScreen> {
  final _text = TextEditingController();
  Timer? _pause;
  String _query = '';
  final Map<String, _MachineResult> _results = {};
  int _waiting = 0;

  @override
  void dispose() {
    _pause?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _pause?.cancel();
    final q = v.trim();
    if (q.length < minSearchChars) {
      setState(() {
        _query = '';
        _results.clear();
        _waiting = 0;
      });
      return;
    }
    // Wait for a pause in typing before asking the machines.
    _pause = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    final online = [for (final c in widget.connections) if (c.link.value == LinkState.online) c];
    setState(() {
      _query = q;
      _results.clear();
      _waiting = online.length;
    });
    await Future.wait([
      for (final c in online)
        c.searchSessions(q).then((r) {
          // A late answer to an earlier search is dropped.
          if (!mounted || _query != q) return;
          setState(() {
            _results[c.machine.id] = r == null ? const _MachineResult(older: true) : _MachineResult(results: r);
            _waiting--;
          });
        }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final offline = [for (final c in widget.connections) if (c.link.value != LinkState.online) c];
    final total = _results.values.fold<int>(0, (n, r) => n + (r.results?.hits.length ?? 0));
    return GlassScaffold(
      background: MosaicBackdrop(seed: 31, fade: G.deep, fadeFrom: 0.2, pixel: 0.6),
      child: ListView(key: const ValueKey('search-list'), padding: screenPadding(context), children: [
        Row(children: [
          GlassOrb(icon: Icons.arrow_back_rounded, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
          const SizedBox(width: 14),
          Expanded(child: Text('Search', style: gSerif(30))),
        ]),
        const SizedBox(height: 16),
        GlassField(
          key: const ValueKey('search-field'),
          controller: _text,
          hint: 'Words from a message or a reply',
          autofocus: true,
          onChanged: _changed,
          onSubmitted: (v) {
            _pause?.cancel();
            if (v.trim().length >= minSearchChars) _search(v.trim());
          },
        ),
        const SizedBox(height: 14),
        if (_query.isEmpty)
          _note('Search every conversation on your machines.')
        else ...[
          if (_waiting > 0) _note('Searching…'),
          if (_waiting == 0 && total == 0 && !_results.values.any((r) => r.older)) _note('No matches.'),
          for (final c in widget.connections)
            if (_results[c.machine.id] case final r?) ..._machine(context, c, r),
        ],
        for (final c in offline) _note('${c.displayName.value} is offline: not searched.'),
      ]),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(text, style: gSans(14, FontWeight.w600, color: G.muted)),
      );

  List<Widget> _machine(BuildContext context, HostConnection c, _MachineResult r) {
    final name = c.displayName.value;
    if (r.older) return [_note(olderHostSearchMessage(name))];
    final hits = r.results!.hits;
    if (hits.isEmpty) return const [];
    return [
      const SizedBox(height: 10),
      Text(name.toUpperCase(), style: gCaps(11)),
      const SizedBox(height: 8),
      for (var i = 0; i < hits.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _HitRow(
            key: ValueKey('search-hit-${c.machine.id}-${hits[i].sessionId}-${_indexInSession(hits, i)}'),
            hit: hits[i],
            query: _query,
            onTap: () => widget.onOpen(context, c, hits[i].sessionId),
          ),
        ),
      if (r.results!.truncated) _note('More matched than shown: add words to narrow it.'),
    ];
  }

  /// Which of its session's hits [i] is (several hits can come from one conversation).
  static int _indexInSession(List<SearchHit> hits, int i) =>
      hits.take(i).where((h) => h.sessionId == hits[i].sessionId).length;
}

class _HitRow extends StatelessWidget {
  final SearchHit hit;
  final String query;
  final VoidCallback onTap;
  const _HitRow({super.key, required this.hit, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final folder = hit.cwd.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? hit.cwd;
    final when = hit.atMs > 0 ? formatIst(hit.atMs) : '';
    final meta = [if (folder.isNotEmpty) folder, if (when.isNotEmpty) when, if (!hit.running) 'Not running'].join(' · ');
    return ClickDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Frost(
        tone: G.deep,
        tint: 0.5,
        rim: true,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(hit.name.isEmpty ? 'Untitled session' : hit.name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: gSans(15, FontWeight.w800)),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: gSans(12, FontWeight.w600, color: G.muted)),
          ],
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: hit.fromUser ? 'You: ' : 'Claude: ', style: gSans(13.5, FontWeight.w800, color: G.muted)),
              ..._marked(hit.snippet, query),
            ]),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: gSans(13.5, FontWeight.w500),
          ),
        ]),
      ),
    );
  }

  /// [text] with every match of [query] in bold and the accent colour.
  static List<TextSpan> _marked(String text, String query) {
    final q = query.toLowerCase();
    if (q.isEmpty) return [TextSpan(text: text)];
    final lower = text.toLowerCase();
    final out = <TextSpan>[];
    var at = 0;
    while (true) {
      final i = lower.indexOf(q, at);
      if (i < 0) break;
      if (i > at) out.add(TextSpan(text: text.substring(at, i)));
      out.add(TextSpan(text: text.substring(i, i + q.length), style: TextStyle(fontWeight: FontWeight.w800, color: G.glow)));
      at = i + q.length;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return out;
  }
}

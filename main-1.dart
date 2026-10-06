// Combiné IA – vraies cotes (The Odds API) + probabilités + analyse Gemini
// Flutter / Android
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Constantes
// ---------------------------------------------------------------------------

const kDefaultModel = 'gemini-flash-latest';

class League {
  final String key;
  final String label;
  final String sport; // Foot | Basket
  const League(this.key, this.label, this.sport);
}

const kLeagues = [
  League('soccer_epl', 'Premier League', 'Foot'),
  League('soccer_france_ligue_one', 'Ligue 1', 'Foot'),
  League('soccer_spain_la_liga', 'Liga', 'Foot'),
  League('soccer_italy_serie_a', 'Serie A', 'Foot'),
  League('soccer_germany_bundesliga', 'Bundesliga', 'Foot'),
  League('soccer_uefa_champs_league', 'Ligue des champions', 'Foot'),
  League('soccer_uefa_europa_league', 'Ligue Europa', 'Foot'),
  League('basketball_nba', 'NBA', 'Basket'),
  League('basketball_euroleague', 'Euroligue', 'Basket'),
];
const kDefaultLeagues = [
  'soccer_epl',
  'soccer_france_ligue_one',
  'soccer_uefa_champs_league',
  'basketball_nba',
];

League leagueOf(String key, [String? title]) => kLeagues.firstWhere(
      (l) => l.key == key,
      orElse: () => League(key, title ?? key,
          key.startsWith('basketball') ? 'Basket' : 'Foot'),
    );

// ---------------------------------------------------------------------------
// Formatage
// ---------------------------------------------------------------------------

String fCote(double v) => v.toStringAsFixed(2);
String fPct(double p) => '${(p * 100).toStringAsFixed(0)} %';
String fPt(double p) =>
    p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toString();
String fMoney(num v) =>
    v.round().toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ' ') +
    ' F';
String two(int n) => n.toString().padLeft(2, '0');
String fWhen(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final hm = '${two(d.hour)}:${two(d.minute)}';
  final diff = day.difference(today).inDays;
  if (diff == 0) return "Aujourd'hui $hm";
  if (diff == 1) return 'Demain $hm';
  return '${two(d.day)}/${two(d.month)} $hm';
}

// ---------------------------------------------------------------------------
// Paramètres
// ---------------------------------------------------------------------------

class AppSettings {
  String oddsKey;
  String geminiKey;
  String model;
  List<String> leagues;
  String region;

  AppSettings({
    required this.oddsKey,
    required this.geminiKey,
    required this.model,
    required this.leagues,
    required this.region,
  });

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      oddsKey: p.getString('odds_key') ?? '',
      geminiKey: p.getString('gemini_key') ?? '',
      model: p.getString('gemini_model') ?? kDefaultModel,
      leagues: p.getStringList('leagues') ?? List.of(kDefaultLeagues),
      region: p.getString('region') ?? 'eu',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('odds_key', oddsKey.trim());
    await p.setString('gemini_key', geminiKey.trim());
    await p.setString(
        'gemini_model', model.trim().isEmpty ? kDefaultModel : model.trim());
    await p.setStringList('leagues', leagues);
    await p.setString('region', region);
  }
}

// ---------------------------------------------------------------------------
// Modèle : cotes et probabilités
// ---------------------------------------------------------------------------

class _Acc {
  final probs = <double>[];
  double priceSum = 0;
  double best = 0;
  String bestBook = '';
  void add(double prob, double price, String book) {
    probs.add(prob);
    priceSum += price;
    if (price > best) {
      best = price;
      bestBook = book;
    }
  }

  double get prob => probs.reduce((a, b) => a + b) / probs.length;
  double get avgPrice => priceSum / probs.length;
}

class Outcome {
  final String market; // h2h | totals
  final String name; // nom renvoyé par l'API
  final String label; // 1, N, 2, Plus de 2.5…
  final double? point;
  final double price; // cote moyenne des bookmakers
  final double best; // meilleure cote trouvée
  final String bestBook;
  final double prob; // probabilité sans marge (consensus)
  final int books;

  const Outcome({
    required this.market,
    required this.name,
    required this.label,
    required this.point,
    required this.price,
    required this.best,
    required this.bestBook,
    required this.prob,
    required this.books,
  });

  String get id => '$market|$name|${point ?? ''}';
}

class MatchOdds {
  final String id, leagueKey, leagueLabel, sport, home, away;
  final DateTime start;
  final List<Outcome> h2h, totals;
  final double? margin;

  MatchOdds({
    required this.id,
    required this.leagueKey,
    required this.leagueLabel,
    required this.sport,
    required this.home,
    required this.away,
    required this.start,
    required this.h2h,
    required this.totals,
    required this.margin,
  });

  String get title => '$home – $away';
  bool get threeWay => h2h.length == 3;
  double p(String label) =>
      h2h.where((o) => o.label == label).fold(0.0, (a, o) => a + o.prob);
}

class Pick {
  final MatchOdds match;
  final Outcome outcome;
  Pick(this.match, this.outcome);

  String get description {
    final o = outcome;
    final m = match;
    if (o.market == 'h2h') {
      if (o.label == '1') return '1 (${m.home} gagne)';
      if (o.label == '2') return '2 (${m.away} gagne)';
      return 'N (match nul)';
    }
    final unit = m.sport == 'Basket' ? 'points' : 'buts';
    return '${o.label} $unit';
  }
}

MatchOdds? parseEvent(Map<String, dynamic> e) {
  final key = (e['sport_key'] ?? '').toString();
  final lg = leagueOf(key, e['sport_title']?.toString());
  final home = (e['home_team'] ?? '').toString();
  final away = (e['away_team'] ?? '').toString();
  final books = (e['bookmakers'] as List?) ?? const [];
  if (books.isEmpty) return null;

  final h2h = <String, _Acc>{};
  final margins = <double>[];
  final totals = <double, Map<String, _Acc>>{};

  for (final b in books) {
    final title = (b['title'] ?? b['key'] ?? '').toString();
    for (final m in (b['markets'] as List?) ?? const []) {
      final outs = ((m['outcomes'] as List?) ?? const [])
          .where((o) => o['price'] is num && (o['price'] as num) > 1)
          .toList();
      if (m['key'] == 'h2h' && outs.length >= 2) {
        final inv = outs.map((o) => 1 / (o['price'] as num).toDouble()).toList();
        final s = inv.reduce((a, b) => a + b);
        margins.add(s - 1);
        for (var i = 0; i < outs.length; i++) {
          h2h
              .putIfAbsent(outs[i]['name'].toString(), () => _Acc())
              .add(inv[i] / s, (outs[i]['price'] as num).toDouble(), title);
        }
      } else if (m['key'] == 'totals') {
        final byPt = <double, List>{};
        for (final o in outs) {
          final pt = (o['point'] as num?)?.toDouble();
          if (pt != null) byPt.putIfAbsent(pt, () => []).add(o);
        }
        byPt.forEach((pt, list) {
          if (list.length != 2) return;
          final inv =
              list.map((o) => 1 / (o['price'] as num).toDouble()).toList();
          final s = inv[0] + inv[1];
          for (var i = 0; i < 2; i++) {
            totals
                .putIfAbsent(pt, () => {})
                .putIfAbsent(list[i]['name'].toString(), () => _Acc())
                .add(inv[i] / s, (list[i]['price'] as num).toDouble(), title);
          }
        });
      }
    }
  }
  if (h2h.isEmpty) return null;

  String lbl(String n) {
    if (n == home) return '1';
    if (n == away) return '2';
    return 'N';
  }

  const order = ['1', 'N', '2'];
  final h2hList = h2h.entries
      .map((en) => Outcome(
            market: 'h2h',
            name: en.key,
            label: lbl(en.key),
            point: null,
            price: en.value.avgPrice,
            best: en.value.best,
            bestBook: en.value.bestBook,
            prob: en.value.prob,
            books: en.value.probs.length,
          ))
      .toList()
    ..sort((a, b) => order.indexOf(a.label).compareTo(order.indexOf(b.label)));

  var totList = <Outcome>[];
  if (totals.isNotEmpty) {
    // La ligne la plus proposée par les bookmakers (souvent 2.5 en foot)
    final main = totals.entries.reduce((a, b) =>
        a.value.values.first.probs.length >= b.value.values.first.probs.length
            ? a
            : b);
    totList = main.value.entries
        .map((en) => Outcome(
              market: 'totals',
              name: en.key,
              label:
                  '${en.key == 'Over' ? 'Plus de' : 'Moins de'} ${fPt(main.key)}',
              point: main.key,
              price: en.value.avgPrice,
              best: en.value.best,
              bestBook: en.value.bestBook,
              prob: en.value.prob,
              books: en.value.probs.length,
            ))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name)); // Over puis Under
  }

  return MatchOdds(
    id: (e['id'] ?? '$home$away').toString(),
    leagueKey: key,
    leagueLabel: lg.label,
    sport: lg.sport,
    home: home,
    away: away,
    start: DateTime.tryParse((e['commence_time'] ?? '').toString())?.toLocal() ??
        DateTime.now(),
    h2h: h2hList,
    totals: totList,
    margin: margins.isEmpty
        ? null
        : margins.reduce((a, b) => a + b) / margins.length,
  );
}

// ---------------------------------------------------------------------------
// Service cotes : The Odds API (v4)
// ---------------------------------------------------------------------------

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class FetchResult {
  final List<Map<String, dynamic>> events;
  final DateTime at;
  final String? remaining;
  final List<String> warnings;
  FetchResult(this.events, this.at, this.remaining, this.warnings);
}

class OddsService {
  static String _iso(DateTime d) =>
      '${d.toUtc().toIso8601String().split('.').first}Z';

  static Future<FetchResult> fetch(AppSettings s) async {
    final now = DateTime.now();
    final events = <Map<String, dynamic>>[];
    final warnings = <String>[];
    String? remaining;

    for (final key in s.leagues) {
      final uri = Uri.https('api.the-odds-api.com', '/v4/sports/$key/odds', {
        'apiKey': s.oddsKey,
        'regions': s.region,
        'markets': 'h2h,totals',
        'oddsFormat': 'decimal',
        'commenceTimeFrom': _iso(now),
        'commenceTimeTo': _iso(now.add(const Duration(hours: 36))),
      });
      http.Response res;
      try {
        res = await http.get(uri).timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw ApiException('Le serveur des cotes ne répond pas. Réessaie.');
      } on SocketException {
        throw ApiException('Pas de connexion Internet.');
      }
      remaining = res.headers['x-requests-remaining'] ?? remaining;

      if (res.statusCode == 200) {
        final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
        events.addAll(list.cast<Map<String, dynamic>>());
        continue;
      }
      String msg = '';
      try {
        msg = (jsonDecode(res.body)['message'] ?? '').toString();
      } catch (_) {}
      if (res.statusCode == 401) {
        throw ApiException(msg.toLowerCase().contains('quota') ||
                msg.toLowerCase().contains('usage')
            ? 'Crédits gratuits du mois épuisés. Ils reviennent le mois prochain.\n\n$msg'
            : 'Clé The Odds API invalide. Vérifie-la dans les paramètres.\n\n$msg');
      }
      if (res.statusCode == 429) {
        throw ApiException('Trop de requêtes. Patiente une minute.\n\n$msg');
      }
      warnings.add('${leagueOf(key).label} : indisponible (${res.statusCode})');
    }
    return FetchResult(events, now, remaining, warnings);
  }

  static Future<void> saveCache(FetchResult r) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'cache',
        jsonEncode({
          'at': r.at.toIso8601String(),
          'remaining': r.remaining,
          'events': r.events,
        }));
  }

  static Future<FetchResult?> loadCache() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('cache');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return FetchResult(
        (j['events'] as List).cast<Map<String, dynamic>>(),
        DateTime.parse(j['at'] as String),
        j['remaining'] as String?,
        const [],
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Service IA : Gemini (REST) avec recherche Google
// ---------------------------------------------------------------------------

class GeminiService {
  static const _system =
      '''Tu es un analyste sportif prudent et honnête. On te donne un combiné de paris avec les cotes réelles des bookmakers et la probabilité implicite de chaque sélection (calculée à partir des cotes, marge retirée).

Pour chaque sélection :
- Forme récente des deux équipes (5 derniers matchs si tu les trouves), absences importantes connues, enjeu et contexte (calendrier chargé, domicile/extérieur).
- Ce qui pourrait faire perdre ce pari.
- Un avis court : la probabilité implicite te semble-t-elle cohérente avec ces informations ?

Puis un avis global sur le risque du combiné.

Règles impératives :
- N'invente aucune statistique. Si tu ne trouves pas une information, écris « information non trouvée ».
- Ne promets jamais de gain et n'emploie pas les mots « sûr », « safe » ou « garanti ».
- Rappelle que plus on ajoute de sélections, plus la probabilité que tout passe diminue.
- Réponds en français, en Markdown, de façon concise (titres ### par match, listes courtes).''';

  static Future<String> analyze(AppSettings s, List<Pick> picks) async {
    final total = picks.fold(1.0, (a, p) => a * p.outcome.price);
    final prob = picks.fold(1.0, (a, p) => a * p.outcome.prob);
    final lines = picks.map((p) {
      final m = p.match;
      return '- ${m.leagueLabel} (${m.sport}), ${fWhen(m.start)} : ${m.title}. '
          'Pari : ${p.description}. Cote moyenne ${fCote(p.outcome.price)}, '
          'probabilité implicite ${fPct(p.outcome.prob)}.';
    }).join('\n');
    final prompt = 'Combiné à analyser :\n$lines\n\n'
        'Cote totale : ${fCote(total)}. Probabilité implicite que tout passe : ${fPct(prob)}.';

    try {
      return await _call(s, prompt, withSearch: true);
    } on ApiException catch (e) {
      if (e.message.startsWith('NO_SEARCH')) {
        final txt = await _call(s, prompt, withSearch: false);
        return '> ⚠️ Recherche web indisponible : analyse faite sans données récentes, à prendre avec encore plus de prudence.\n\n$txt';
      }
      rethrow;
    }
  }

  static Future<String> _call(AppSettings s, String prompt,
      {required bool withSearch}) async {
    final body = <String, dynamic>{
      'systemInstruction': {
        'parts': [
          {'text': _system}
        ]
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {'temperature': 0.3},
    };
    if (withSearch) {
      body['tools'] = [
        {'google_search': {}}
      ];
    }
    http.Response res;
    try {
      res = await http
          .post(
            Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models/${s.model}:generateContent'),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': s.geminiKey,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 2));
    } on TimeoutException {
      throw ApiException("L'analyse a pris trop de temps. Réessaie.");
    } on SocketException {
      throw ApiException('Pas de connexion Internet.');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('Réponse illisible (code ${res.statusCode}).');
    }
    if (res.statusCode != 200) {
      final msg = (data['error']?['message'] ?? '').toString();
      if (withSearch && (res.statusCode == 400 || res.statusCode == 429)) {
        throw ApiException('NO_SEARCH');
      }
      throw ApiException(switch (res.statusCode) {
        400 || 403 => 'Clé Gemini invalide. Vérifie-la dans les paramètres.\n\n$msg',
        404 => 'Modèle « ${s.model} » introuvable. Change-le dans les paramètres.\n\n$msg',
        429 => 'Quota gratuit Gemini atteint. Réessaie dans quelques minutes.\n\n$msg',
        _ => 'Erreur ${res.statusCode}.\n\n$msg',
      });
    }
    final cands = data['candidates'] as List?;
    final parts = (cands != null && cands.isNotEmpty)
        ? (cands.first['content']?['parts'] as List?) ?? []
        : [];
    final text = parts
        .where((p) => p['thought'] != true)
        .map((p) => (p['text'] ?? '').toString())
        .join()
        .trim();
    if (text.isEmpty) throw ApiException("L'IA n'a rien renvoyé. Réessaie.");
    return text;
  }
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

void main() => runApp(const CombineApp());

class CombineApp extends StatelessWidget {
  const CombineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Combiné IA',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A86B),
          brightness: Brightness.dark,
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00A86B)),
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Écran : matchs du jour
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppSettings? _s;
  List<MatchOdds> _matches = [];
  DateTime? _updated;
  String? _remaining;
  List<String> _warnings = [];
  bool _loading = false;
  String _filter = 'Tous';
  final Map<String, Pick> _picks = {}; // une sélection par match

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final s = await AppSettings.load();
    final cache = await OddsService.loadCache();
    if (!mounted) return;
    setState(() {
      _s = s;
      if (cache != null) _apply(cache);
    });
  }

  void _apply(FetchResult r) {
    final now = DateTime.now();
    _matches = r.events
        .map(parseEvent)
        .whereType<MatchOdds>()
        .where((m) => m.start.isAfter(now))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    _updated = r.at;
    _remaining = r.remaining;
    _warnings = r.warnings;
    final ids = _matches.map((m) => m.id).toSet();
    _picks.removeWhere((id, _) => !ids.contains(id));
  }

  Future<void> _openSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    final s = await AppSettings.load();
    if (mounted) setState(() => _s = s);
  }

  Future<void> _refresh() async {
    final s = _s;
    if (s == null) return;
    if (s.oddsKey.isEmpty) {
      _snack('Ajoute ta clé The Odds API dans les paramètres.');
      return _openSettings();
    }
    if (s.leagues.isEmpty) {
      _snack('Choisis au moins un championnat dans les paramètres.');
      return _openSettings();
    }
    setState(() => _loading = true);
    try {
      final r = await OddsService.fetch(s);
      await OddsService.saveCache(r);
      if (!mounted) return;
      setState(() => _apply(r));
      if (_matches.isEmpty) _snack('Aucun match coté dans les 36 prochaines heures.');
    } on ApiException catch (e) {
      _error(e.message);
    } catch (e) {
      _error('Erreur inattendue : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  void _error(String m) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Impossible de charger'),
        content: SingleChildScrollView(child: Text(m)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))
        ],
      ),
    );
  }

  void _toggle(MatchOdds m, Outcome o) {
    setState(() {
      final cur = _picks[m.id];
      if (cur != null && cur.outcome.id == o.id) {
        _picks.remove(m.id);
      } else {
        _picks[m.id] = Pick(m, o);
      }
    });
  }

  double get _total => _picks.values.fold(1.0, (a, p) => a * p.outcome.price);

  Future<void> _openCombine() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CombineScreen(
          picks: _picks.values.toList(),
          settings: _s!,
          onRemove: (id) => setState(() => _picks.remove(id)),
          openSettings: _openSettings,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _matches
        .where((m) => _filter == 'Tous' || m.sport == _filter)
        .toList();

    Widget body;
    if (_s == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_matches.isEmpty) {
      body = ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 40),
          Icon(Icons.sports_soccer, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            _s!.oddsKey.isEmpty
                ? 'Ajoute ta clé gratuite The Odds API pour voir les vraies cotes du jour.'
                : 'Appuie sur « Charger les cotes » pour récupérer les matchs des 36 prochaines heures.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _loading
                ? null
                : (_s!.oddsKey.isEmpty ? _openSettings : _refresh),
            icon: Icon(_s!.oddsKey.isEmpty ? Icons.key : Icons.download),
            label: Text(
                _s!.oddsKey.isEmpty ? 'Ouvrir les paramètres' : 'Charger les cotes'),
          ),
          for (final w in _warnings)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(w,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
            ),
        ],
      );
    } else {
      final items = <Widget>[];
      String? lastLeague;
      for (final m in shown) {
        final head = '${m.leagueLabel} • ${m.sport}';
        if (head != lastLeague) {
          items.add(Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
            child: Text(m.leagueLabel,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
          ));
          lastLeague = head;
        }
        items.add(MatchCard(
          match: m,
          selected: _picks[m.id]?.outcome.id,
          onPick: (o) => _toggle(m, o),
        ));
      }
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 110),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'Mis à jour : ${fWhen(_updated!)}'
                '${_remaining != null ? '  •  Crédits restants : $_remaining' : ''}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            for (final w in _warnings)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(w,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Tous', label: Text('Tous')),
                ButtonSegment(value: 'Foot', label: Text('Foot')),
                ButtonSegment(value: 'Basket', label: Text('Basket')),
              ],
              selected: {_filter},
              onSelectionChanged: (v) => setState(() => _filter = v.first),
            ),
            ...items,
            if (shown.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('Aucun match pour ce sport.',
                    textAlign: TextAlign.center),
              ),
            const SizedBox(height: 16),
            const InfoCard(),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Combiné IA'),
        actions: [
          IconButton(
            tooltip: 'Actualiser les cotes',
            onPressed: _loading ? null : _refresh,
            icon: _loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Paramètres',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: body,
      floatingActionButton: _picks.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _openCombine,
              icon: const Icon(Icons.receipt_long),
              label: Text(
                  'Mon combiné (${_picks.length})  •  ${fCote(_total)}'),
            ),
    );
  }
}

class InfoCard extends StatelessWidget {
  const InfoCard({super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      color: t.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          'Comment lire : la cote affichée est la moyenne des bookmakers ; le pourcentage est la probabilité que le marché donne à ce résultat, marge retirée. '
          'La marge fait que, sur la durée, parier fait perdre de l\'argent. Ne mise que ce que tu peux perdre.',
          style: t.textTheme.bodySmall,
        ),
      ),
    );
  }
}

class MatchCard extends StatelessWidget {
  final MatchOdds match;
  final String? selected;
  final ValueChanged<Outcome> onPick;

  const MatchCard({
    super.key,
    required this.match,
    required this.selected,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = match;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(fWhen(m.start), style: t.textTheme.bodySmall),
                const Spacer(),
                if (m.margin != null)
                  Text('Marge bookmaker ${(m.margin! * 100).toStringAsFixed(1)} %',
                      style: t.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(m.title,
                style: t.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final o in m.h2h)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: OddButton(
                        top: o.label,
                        outcome: o,
                        selected: selected == o.id,
                        onTap: () => onPick(o),
                      ),
                    ),
                  ),
              ],
            ),
            if (m.totals.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final o in m.totals)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: OddButton(
                          top: o.label,
                          outcome: o,
                          selected: selected == o.id,
                          onTap: () => onPick(o),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (m.threeWay) ...[
              const SizedBox(height: 8),
              Text(
                'Double chance (probabilité) : 1N ${fPct(m.p('1') + m.p('N'))}   '
                'N2 ${fPct(m.p('N') + m.p('2'))}   12 ${fPct(m.p('1') + m.p('2'))}',
                style: t.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class OddButton extends StatelessWidget {
  final String top;
  final Outcome outcome;
  final bool selected;
  final VoidCallback onTap;

  const OddButton({
    super.key,
    required this.top,
    required this.outcome,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onPrimary : cs.onSurface;
    return Material(
      color: selected ? cs.primary : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            children: [
              Text(top,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: fg.withValues(alpha: .8))),
              Text(fCote(outcome.price),
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: fg)),
              Text(fPct(outcome.prob),
                  style: TextStyle(fontSize: 11, color: fg.withValues(alpha: .75))),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Écran : mon combiné
// ---------------------------------------------------------------------------

class CombineScreen extends StatefulWidget {
  final List<Pick> picks;
  final AppSettings settings;
  final ValueChanged<String> onRemove;
  final Future<void> Function() openSettings;

  const CombineScreen({
    super.key,
    required this.picks,
    required this.settings,
    required this.onRemove,
    required this.openSettings,
  });

  @override
  State<CombineScreen> createState() => _CombineScreenState();
}

class _CombineScreenState extends State<CombineScreen> {
  late final List<Pick> _picks = List.of(widget.picks);
  final _stake = TextEditingController(text: '1000');

  @override
  void dispose() {
    _stake.dispose();
    super.dispose();
  }

  double get _odds => _picks.fold(1.0, (a, p) => a * p.outcome.price);
  double get _prob => _picks.fold(1.0, (a, p) => a * p.outcome.prob);

  String _asText() {
    final b = StringBuffer('Mon combiné\n');
    for (var i = 0; i < _picks.length; i++) {
      final p = _picks[i];
      b.writeln('${i + 1}. ${p.match.title} (${fWhen(p.match.start)}) : '
          '${p.description} @ ${fCote(p.outcome.price)}');
    }
    b.write('Cote totale : ${fCote(_odds)}  •  Probabilité estimée : ${fPct(_prob)}');
    return b.toString();
  }

  Future<void> _analyze() async {
    final s = await AppSettings.load();
    if (!mounted) return;
    if (s.geminiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ajoute ta clé Gemini dans les paramètres.')));
      await widget.openSettings();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AnalysisScreen(picks: List.of(_picks), settings: s)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stake = int.tryParse(_stake.text.replaceAll(RegExp(r'\D'), '')) ?? 0;
    final back100 = 100 * _odds * _prob;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon combiné'),
        actions: [
          IconButton(
            tooltip: 'Copier',
            icon: const Icon(Icons.copy_outlined),
            onPressed: _picks.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _asText()));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Combiné copié')));
                  },
          ),
        ],
      ),
      body: _picks.isEmpty
          ? const Center(child: Text('Ton combiné est vide.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final p in _picks)
                  Card(
                    child: ListTile(
                      title: Text(p.match.title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${p.match.leagueLabel}, ${fWhen(p.match.start)}\n'
                          '${p.description}\n'
                          'Meilleure cote : ${fCote(p.outcome.best)} (${p.outcome.bestBook})'),
                      isThreeLine: true,
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(fCote(p.outcome.price),
                              style: t.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(fPct(p.outcome.prob),
                              style: t.textTheme.bodySmall),
                        ],
                      ),
                      onLongPress: () {
                        setState(() => _picks.remove(p));
                        widget.onRemove(p.match.id);
                      },
                    ),
                  ),
                Text('Appui long sur une sélection pour la retirer.',
                    style: t.textTheme.bodySmall),
                const SizedBox(height: 16),
                Card(
                  color: t.colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Cote totale', style: t.textTheme.bodyMedium),
                        Text(fCote(_odds),
                            style: t.textTheme.displaySmall
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Text(
                            'Probabilité estimée que tout passe : ${fPct(_prob)}',
                            style: t.textTheme.titleSmall),
                        Text(
                            'Soit environ 1 fois sur ${(1 / _prob).toStringAsFixed(1)}.',
                            style: t.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _stake,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Mise (FCFA)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                Text('Si tout passe : ${fMoney(stake * _odds)}',
                    style: t.textTheme.titleMedium),
                Text(
                  'En moyenne, pour 100 F misés sur ce combiné, tu récupères '
                  '${back100.toStringAsFixed(0)} F.',
                  style: t.textTheme.bodyMedium?.copyWith(
                      color: back100 < 100
                          ? t.colorScheme.error
                          : t.colorScheme.primary),
                ),
                const SizedBox(height: 4),
                Text(
                  'Calcul : cote totale × probabilité estimée. En dessous de 100 F, c\'est la marge du bookmaker qui joue contre toi. '
                  'Les cotes sont des moyennes : vérifie la cote réelle chez ton bookmaker.',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _analyze,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Analyse IA des sélections'),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Écran : analyse IA
// ---------------------------------------------------------------------------

class AnalysisScreen extends StatefulWidget {
  final List<Pick> picks;
  final AppSettings settings;
  const AnalysisScreen({super.key, required this.picks, required this.settings});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  late Future<String> _future = _run();

  Future<String> _run() => GeminiService.analyze(widget.settings, widget.picks);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analyse IA')),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Recherche de la forme des équipes…'),
                ],
              ),
            );
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(snap.error.toString(), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() => _future = _run()),
                      child: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            );
          }
          final text = snap.data!;
          return Column(
            children: [
              Expanded(
                child: Markdown(
                  data: text,
                  selectable: true,
                  padding: const EdgeInsets.all(16),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Analyse copiée')));
                    },
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text("Copier l'analyse"),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Écran : paramètres
// ---------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _odds = TextEditingController();
  final _gem = TextEditingController();
  final _model = TextEditingController();
  Set<String> _leagues = {};
  String _region = 'eu';
  bool _ready = false, _hide1 = true, _hide2 = true;

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _odds.text = s.oddsKey;
        _gem.text = s.geminiKey;
        _model.text = s.model;
        _leagues = s.leagues.toSet();
        _region = s.region;
        _ready = true;
      });
    });
  }

  @override
  void dispose() {
    _odds.dispose();
    _gem.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await AppSettings(
      oddsKey: _odds.text,
      geminiKey: _gem.text,
      model: _model.text,
      leagues: kLeagues.map((l) => l.key).where(_leagues.contains).toList(),
      region: _region,
    ).save();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Paramètres enregistrés')));
    Navigator.pop(context);
  }

  Widget _keyField(TextEditingController c, String hint, String help,
      bool hide, VoidCallback toggle) {
    return TextField(
      controller: c,
      obscureText: hide,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        hintText: hint,
        helperText: help,
        helperMaxLines: 2,
        suffixIcon: IconButton(
          icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: toggle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cost = _leagues.length * 2;
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Clé The Odds API (cotes)', style: t.textTheme.titleMedium),
                const SizedBox(height: 8),
                _keyField(_odds, 'Colle ta clé ici',
                    'Gratuite sur the-odds-api.com (500 crédits par mois)',
                    _hide1, () => setState(() => _hide1 = !_hide1)),
                const SizedBox(height: 20),
                Text('Clé Gemini (analyse IA)', style: t.textTheme.titleMedium),
                const SizedBox(height: 8),
                _keyField(_gem, 'Colle ta clé ici',
                    'Gratuite sur aistudio.google.com → Get API key',
                    _hide2, () => setState(() => _hide2 = !_hide2)),
                const SizedBox(height: 12),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Modèle Gemini',
                    helperText: 'Par défaut : $kDefaultModel',
                  ),
                ),
                const SizedBox(height: 24),
                Text('Championnats', style: t.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Chaque actualisation coûte 2 crédits par championnat coché '
                  '(ici $cost crédits). Hors saison, un championnat ne renvoie aucun match.',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final l in kLeagues)
                      FilterChip(
                        label: Text(l.label),
                        selected: _leagues.contains(l.key),
                        onSelected: (v) => setState(
                            () => v ? _leagues.add(l.key) : _leagues.remove(l.key)),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text('Bookmakers', style: t.textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'eu', label: Text('Europe')),
                    ButtonSegment(value: 'uk', label: Text('Royaume-Uni')),
                  ],
                  selected: {_region},
                  onSelectionChanged: (v) => setState(() => _region = v.first),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Enregistrer'),
                ),
              ],
            ),
    );
  }
}

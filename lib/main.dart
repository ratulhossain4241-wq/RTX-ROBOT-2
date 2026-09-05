import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RtxApp());
}

@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: OverlayHome(),
  ));
}

class RtxApp extends StatelessWidget {
  const RtxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LaunchPage(),
    );
  }
}

// ───────────────── THEME ─────────────────
class T {
  static const bg = Color(0xFF0A0A0A);
  static const card = Color(0xFF0D1117);
  static const green = Color(0xFF00FF41);
  static const red = Color(0xFFFF0040);
  static const gold = Color(0xFFFFCC00);
  static const cyan = Color(0xFF00FFFF);
  static const dim = Color(0xFF0A6E0A);
  static const muted = Color(0xFF333333);
}

// ───────────────── MARKETS ─────────────────
class Market {
  final String name, td, cat;
  const Market(this.name, this.td, this.cat);
}

const markets = <Market>[
  Market('EUR/USD', 'EUR/USD', 'Major'),
  Market('GBP/USD', 'GBP/USD', 'Major'),
  Market('USD/JPY', 'USD/JPY', 'Major'),
  Market('USD/CHF', 'USD/CHF', 'Major'),
  Market('USD/CAD', 'USD/CAD', 'Major'),
  Market('AUD/USD', 'AUD/USD', 'Major'),
  Market('NZD/USD', 'NZD/USD', 'Major'),
  Market('EUR/JPY', 'EUR/JPY', 'Cross'),
  Market('GBP/JPY', 'GBP/JPY', 'Cross'),
  Market('EUR/GBP', 'EUR/GBP', 'Cross'),
  Market('AUD/JPY', 'AUD/JPY', 'Cross'),
  Market('USD/INR', 'USD/INR', 'Exotic'),
  Market('USD/SGD', 'USD/SGD', 'Exotic'),
];

// ───────────────── CANDLE + ENGINE ─────────────────
class Candle {
  final double o, h, l, c;
  final String time; // raw "datetime" string from TwelveData, e.g. "2026-09-05 01:16:00"
  Candle(this.o, this.h, this.l, this.c, this.time);
  factory Candle.fromJson(Map<String, dynamic> j) => Candle(
        double.parse(j['open'].toString()),
        double.parse(j['high'].toString()),
        double.parse(j['low'].toString()),
        double.parse(j['close'].toString()),
        (j['datetime'] ?? '').toString(),
      );
}

/// Pure technical-engine output. No grade/direction/color here anymore —
/// those are decided later by [buildFinalSignal] using engine + AI together,
/// which is what fixes the "PUT never gets A+" bug.
class Signal {
  final int strength; // 0-100, 50 = neutral, >50 leans bullish, <50 bearish
  final int techConfidence; // 0-100, how much the indicators agree with each other
  final Map<String, String> breakdown; // kept for AI prompt / debugging, not shown in overlay UI anymore
  final Map<String, double> indicators; // raw numeric values, used for the Gemini prompt
  Signal({
    required this.strength,
    required this.techConfidence,
    required this.breakdown,
    required this.indicators,
  });
}

/// Final, user-facing decision after combining the technical engine with Gemini.
class FinalSignal {
  final String grade; // A+, A, B+, B, C — same scale for CALL and PUT
  final String direction; // 'CALL' or 'PUT'
  final int accuracy; // 0-99, combined confidence score
  final Color color;
  final String reason;
  FinalSignal({
    required this.grade,
    required this.direction,
    required this.accuracy,
    required this.color,
    required this.reason,
  });
}

double? ema(List<double> a, int p) {
  if (a.length < p) return null;
  final k = 2 / (p + 1);
  var v = a.sublist(0, p).reduce((x, y) => x + y) / p;
  for (var i = p; i < a.length; i++) {
    v = a[i] * k + v * (1 - k);
  }
  return v;
}

double? rsi(List<double> a, [int p = 14]) {
  if (a.length < p + 1) return null;
  final s = a.sublist(a.length - p - 1);
  final ch = <double>[];
  for (var i = 1; i < s.length; i++) {
    ch.add(s[i] - s[i - 1]);
  }
  final ag = ch.where((e) => e > 0).fold(0.0, (x, y) => x + y) / p;
  final al = ch.where((e) => e < 0).fold(0.0, (x, y) => x - y) / p;
  if (al == 0) return 100;
  return 100 - 100 / (1 + ag / al);
}

Map<String, double>? bb(List<double> a, [int p = 20]) {
  if (a.length < p) return null;
  final s = a.sublist(a.length - p);
  final mid = s.reduce((x, y) => x + y) / p;
  final std = sqrt(s.map((v) => pow(v - mid, 2)).reduce((x, y) => x + y) / p);
  return {'upper': mid + 2 * std, 'mid': mid, 'lower': mid - 2 * std};
}

Map<String, double>? macd(List<double> a) {
  if (a.length < 35) return null;
  final series = <double>[];
  for (var i = a.length - 9; i < a.length; i++) {
    final sl = a.sublist(0, i + 1);
    final e12 = ema(sl, 12);
    final e26 = ema(sl, 26);
    if (e12 != null && e26 != null) series.add(e12 - e26);
  }
  if (series.length < 9) return null;
  final sig = series.reduce((x, y) => x + y) / 9;
  final line = series.last;
  return {'line': line, 'signal': sig, 'hist': line - sig};
}

double? stoch(List<Candle> cs, [int p = 14]) {
  if (cs.length < p) return null;
  final s = cs.sublist(cs.length - p);
  final hh = s.map((e) => e.h).reduce(max);
  final ll = s.map((e) => e.l).reduce(min);
  if (hh == ll) return 50;
  return ((cs.last.c - ll) / (hh - ll)) * 100;
}

Signal runEngine(List<Candle> candles) {
  final bd = <String, String>{};
  final ind = <String, double>{};
  if (candles.length < 60) {
    return Signal(strength: 50, techConfidence: 50, breakdown: {'Status': 'LOW DATA'}, indicators: {});
  }

  final closes = candles.map((e) => e.c).toList();
  final last = closes.last;
  ind['lastClose'] = last;
  var score = 0;
  var maxScore = 0;

  final e8 = ema(closes, 8);
  final e21 = ema(closes, 21);
  if (e8 != null && e21 != null) {
    final v = e8 > e21 ? 16 : -16;
    score += v;
    maxScore += 16;
    bd['EMA 8/21'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['ema8'] = e8;
    ind['ema21'] = e21;
  }

  final e50 = ema(closes, 50);
  if (e21 != null && e50 != null) {
    final v = e21 > e50 ? 12 : -12;
    score += v;
    maxScore += 12;
    bd['EMA 21/50'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['ema50'] = e50;
  }

  final r = rsi(closes);
  if (r != null) {
    final v = r < 35 ? 14 : (r > 65 ? -14 : (r >= 50 ? 3 : -3));
    score += v;
    maxScore += 14;
    bd['RSI ${r.toStringAsFixed(0)}'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['rsi'] = r;
  }

  final b = bb(closes);
  if (b != null) {
    final pct = (last - b['lower']!) / (b['upper']! - b['lower']!);
    final v = pct < 0.2 ? 12 : (pct > 0.8 ? -12 : (pct >= 0.5 ? 2 : -2));
    score += v;
    maxScore += 12;
    bd['Bollinger'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['bbUpper'] = b['upper']!;
    ind['bbMid'] = b['mid']!;
    ind['bbLower'] = b['lower']!;
  }

  final m = macd(closes);
  if (m != null) {
    final v = m['line']! > m['signal']! ? 12 : -12;
    score += v;
    maxScore += 12;
    bd['MACD'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['macdLine'] = m['line']!;
    ind['macdSignal'] = m['signal']!;
  }

  final st = stoch(candles);
  if (st != null) {
    final v = st < 30 ? 10 : (st > 70 ? -10 : (st >= 50 ? 2 : -2));
    score += v;
    maxScore += 10;
    bd['Stoch'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['stoch'] = st;
  }

  final bullPat = candles.last.c >= candles.last.o;
  score += bullPat ? 8 : -8;
  maxScore += 8;
  bd['Pattern'] = bullPat ? '↑ BULL' : '↓ BEAR';

  if (maxScore == 0) maxScore = 1;
  final strength = (((score / maxScore) + 1) / 2 * 100).round().clamp(0, 100);
  final bulls = bd.values.where((e) => e.contains('BULL')).length;
  final bears = bd.values.where((e) => e.contains('BEAR')).length;
  final total = max(1, bulls + bears);
  final techConfidence = ((max(bulls, bears) / total) * 100).round();

  return Signal(strength: strength, techConfidence: techConfidence, breakdown: bd, indicators: ind);
}

/// Grade is now purely about how CONFIDENT the final call is (0-99 accuracy),
/// completely independent of whether the direction is CALL or PUT.
/// A strong PUT and a strong CALL both reach A+; a weak/unclear read of
/// either direction lands on C. This fixes the "PUT can only be C/D" bug.
Map<String, dynamic> gradeFromAccuracy(int accuracy, String direction) {
  String grade;
  if (accuracy >= 88) {
    grade = 'A+';
  } else if (accuracy >= 76) {
    grade = 'A';
  } else if (accuracy >= 63) {
    grade = 'B+';
  } else if (accuracy >= 50) {
    grade = 'B';
  } else {
    grade = 'C';
  }
  final color = direction == 'CALL' ? T.green : T.red;
  final arrow = direction == 'CALL' ? '▲' : '▼';
  final prefix = grade == 'A+'
      ? 'STRONG '
      : grade == 'C'
          ? 'WEAK '
          : '';
  return {
    'grade': grade,
    'label': '$prefix$direction $arrow',
    'color': grade == 'C' ? T.muted : color,
  };
}

/// Combines the technical engine (strength/confidence) with Gemini's
/// read of the same data into one final CALL/PUT decision + accuracy score.
FinalSignal buildFinalSignal({
  required Signal eng,
  required bool aiOk,
  required String aiDirection,
  required int aiConfidence,
  required String reason,
}) {
  // How far the technical engine is from neutral (50), scaled to 0-100.
  final techScore = ((eng.strength - 50).abs() * 2).clamp(0, 100);
  final techDirection = eng.strength >= 50 ? 'CALL' : 'PUT';

  String finalDirection;
  int accuracy;

  if (!aiOk) {
    // Gemini unavailable/failed → fall back to the technical engine alone.
    finalDirection = techDirection;
    accuracy = ((techScore * 0.7) + (eng.techConfidence * 0.3)).round().clamp(0, 95);
  } else {
    finalDirection = aiDirection;
    final agree = aiDirection == techDirection;
    final base = (techScore * 0.5) + (aiConfidence * 0.5);
    // Reward when the engine and Gemini agree, penalize when they conflict —
    // this is what "accuracy" actually reflects: agreement + raw confidence,
    // not a guarantee of a winning trade.
    accuracy = agree ? min(99, (base + 8).round()) : max(20, (base - 18).round());
  }

  final g = gradeFromAccuracy(accuracy, finalDirection);
  return FinalSignal(
    grade: g['grade'],
    direction: finalDirection,
    accuracy: accuracy,
    color: g['color'],
    reason: reason,
  );
}

// ───────────────── STORAGE ─────────────────
// IMPORTANT: the main app and the floating overlay run in two SEPARATE
// Flutter engines. shared_preferences caches all values in memory per
// engine on first getInstance() call and normally never re-reads disk
// after that. That stale cache was the real cause of the overlay being
// stuck on one market and not seeing new API keys — calling reload()
// before every read forces a fresh disk read on both sides, every time.
class Store {
  static Future<SharedPreferences> _fresh() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p;
  }

  static Future<void> saveKeys(String td, String gem) async {
    final p = await _fresh();
    await p.setString('td', td);
    await p.setString('gem', gem);
  }

  static Future<String> td() async => (await _fresh()).getString('td') ?? '';
  static Future<String> gem() async => (await _fresh()).getString('gem') ?? '';
  static Future<void> saveMarket(String m) async => (await _fresh()).setString('mkt', m);
  static Future<String> market() async => (await _fresh()).getString('mkt') ?? 'EUR/USD';
}

// ───────────────── API ─────────────────
Future<List<Candle>> fetchCandles(String key, String symbol) async {
  final uri = Uri.parse(
    'https://api.twelvedata.com/time_series?symbol=${Uri.encodeComponent(symbol)}&interval=1min&outputsize=80&apikey=$key',
  );
  final res = await http.get(uri);
  final data = jsonDecode(res.body);
  if (data['status'] == 'error' || data['values'] == null) {
    throw Exception(data['message'] ?? 'API error');
  }
  final list =
      (data['values'] as List).reversed.map((e) => Candle.fromJson(e)).toList();
  if (list.length > 1) return list.sublist(0, list.length - 1);
  return list;
}

/// Builds a compact, token-cheap dump of the last candles for the AI prompt.
/// Format per candle: o,h,l,c — separated by ';'.
String _candleDump(List<Candle> candles, {int last = 30}) {
  final slice = candles.length > last ? candles.sublist(candles.length - last) : candles;
  return slice
      .map((c) =>
          '${c.o.toStringAsFixed(5)},${c.h.toStringAsFixed(5)},${c.l.toStringAsFixed(5)},${c.c.toStringAsFixed(5)}')
      .join(';');
}

String _indicatorDump(Map<String, double> ind) {
  return ind.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(5)}').join(', ');
}

Future<Map<String, dynamic>> askGemini({
  required String key,
  required String market,
  required List<Candle> candles,
  required Signal eng,
}) async {
  try {
    final model = GenerativeModel(
      // gemini-2.0-flash-lite was fully shut down by Google on 2026-06-01
      // (that's why it kept 404'ing). gemini-3.1-flash-lite is the current
      // stable, cheapest-tier model with no shutdown date announced —
      // the right long-term pick for a live signal loop.
      model: 'gemini-3.1-flash-lite',
      apiKey: key,
      generationConfig: GenerationConfig(
        temperature: 0.15,
        maxOutputTokens: 40,
        candidateCount: 1,
      ),
      systemInstruction: Content.system(
        'You are a strict 1-minute forex signal filter. '
        'You ONLY ever output exactly one line in this exact format, nothing else: '
        'DIRECTION|CONFIDENCE|REASON\n'
        'DIRECTION must be exactly the word CALL or PUT (nothing else). '
        'CONFIDENCE is an integer 0-100. '
        'REASON is at most 6 words, no punctuation beyond a comma. '
        'Never add greetings, disclaimers, markdown, explanations, or extra lines. '
        'Never refuse to answer — always pick CALL or PUT based on the data given.',
      ),
    );

    final prompt = '''
Pair: $market
Recent 1m candles (oldest→newest, o,h,l,c per candle, ; separated):
${_candleDump(candles)}

Computed indicators: ${_indicatorDump(eng.indicators)}
Technical engine reading: strength=${eng.strength}/100, agreement=${eng.techConfidence}%

Respond with exactly one line: DIRECTION|CONFIDENCE|REASON
''';

    final out = await model.generateContent([Content.text(prompt)]);
    final text = (out.text ?? '').trim();
    final p = text.split('|');
    if (p.length >= 3) {
      final d = p[0].trim().toUpperCase();
      final c = int.tryParse(p[1].trim().replaceAll(RegExp(r'[^0-9]'), '')) ?? 50;
      if (d == 'CALL' || d == 'PUT') {
        return <String, dynamic>{
          'direction': d,
          'ai': c.clamp(0, 100),
          'reason': p.sublist(2).join('|').trim(),
          'ok': true,
        };
      }
    }
    return <String, dynamic>{
      'direction': eng.strength >= 50 ? 'CALL' : 'PUT',
      'ai': 0,
      'reason': 'Unrecognized AI response, using engine',
      'ok': false,
    };
  } catch (e) {
    return <String, dynamic>{
      'direction': eng.strength >= 50 ? 'CALL' : 'PUT',
      'ai': 0,
      'reason': 'AI error: $e',
      'ok': false,
    };
  }
}

// ───────────────── LAUNCH PAGE (Settings + Market + Start) ─────────────────
class LaunchPage extends StatefulWidget {
  const LaunchPage({super.key});
  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

class _LaunchPageState extends State<LaunchPage> {
  bool perm = false;
  bool loading = true;
  String msg = '';
  final tdCtrl = TextEditingController();
  final gemCtrl = TextEditingController();
  Market selected = markets.first;

  @override
  void initState() {
    super.initState();
    init();
  }

  @override
  void dispose() {
    tdCtrl.dispose();
    gemCtrl.dispose();
    super.dispose();
  }

  Future<void> init() async {
    final g = await FlutterOverlayWindow.isPermissionGranted();
    final td = await Store.td();
    final gem = await Store.gem();
    final m = await Store.market();
    setState(() {
      perm = g;
      tdCtrl.text = td;
      gemCtrl.text = gem;
      selected = markets.firstWhere((e) => e.td == m, orElse: () => markets.first);
      loading = false;
    });
  }

  Future<void> saveKeys() async {
    await Store.saveKeys(tdCtrl.text.trim(), gemCtrl.text.trim());
    if (!mounted) return;
    setState(() => msg = 'API Key সেভ হয়েছে ✅');
  }

  Future<void> pickMarket() async {
    final picked = await showModalBottomSheet<Market>(
      context: context,
      backgroundColor: T.card,
      isScrollControlled: true,
      builder: (ctx) {
        return SizedBox(
          height: 420,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('MARKET বাছাই করুন',
                    style: TextStyle(
                        color: T.green, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: markets.length,
                  itemBuilder: (_, i) {
                    final m = markets[i];
                    return ListTile(
                      title: Text(m.name, style: const TextStyle(color: T.green)),
                      subtitle: Text(m.cat, style: const TextStyle(color: T.dim, fontSize: 11)),
                      onTap: () => Navigator.pop(ctx, m),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      // saveMarket already forces a fresh reload+write; setState after await
      // so the LaunchPage UI and the persisted value never disagree.
      await Store.saveMarket(picked.td);
      setState(() {
        selected = picked;
        msg = 'Market সেট হয়েছে: ${picked.name} — ফ্লোটিং বাবল বন্ধ থাকলে আবার START দিন, খোলা থাকলে পরের SIGNAL চাপেই নতুন মার্কেট ব্যবহার হবে';
      });
    }
  }

  Future<void> start() async {
    try {
      if (tdCtrl.text.trim().isEmpty) {
        setState(() => msg = 'আগে Twelve Data API Key দিয়ে সেভ করুন');
        return;
      }
      await saveKeys();
      if (!perm) {
        await FlutterOverlayWindow.requestPermission();
        final g = await FlutterOverlayWindow.isPermissionGranted();
        setState(() => perm = g);
        if (!perm) {
          setState(() => msg = 'Overlay permission দিতে হবে');
          return;
        }
      }
      final active = await FlutterOverlayWindow.isActive();
      if (!active) {
        await FlutterOverlayWindow.showOverlay(
          enableDrag: true,
          height: 600,
          width: 360,
          alignment: OverlayAlignment.center,
          flag: OverlayFlag.defaultFlag,
          overlayTitle: 'RTX ROBOT',
          overlayContent: 'Signal running',
        );
      }
      setState(() => msg = 'Overlay চালু হয়েছে ✅');
    } catch (e) {
      setState(() => msg = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: T.bg,
        body: Center(child: CircularProgressIndicator(color: T.green)),
      );
    }
    return Scaffold(
      backgroundColor: T.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              const Center(
                child: Text('🤖 RTX ROBOT',
                    style: TextStyle(
                        color: T.green,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2)),
              ),
              const SizedBox(height: 4),
              const Center(
                child: Text('HACKER FLOATING SIGNAL',
                    style: TextStyle(color: T.dim, fontSize: 11, letterSpacing: 2)),
              ),
              const SizedBox(height: 24),
              Text(perm ? 'OVERLAY PERMISSION: ON' : 'OVERLAY PERMISSION: OFF',
                  style: TextStyle(
                      color: perm ? T.green : T.red, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),

              // ── API KEYS ──
              const Text('API KEYS',
                  style: TextStyle(color: T.gold, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              _field(tdCtrl, 'Twelve Data API Key (আবশ্যক)'),
              const SizedBox(height: 10),
              _field(gemCtrl, 'Gemini API Key (ঐচ্ছিক)'),
              const SizedBox(height: 10),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: T.green),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: saveKeys,
                child: const Text('SAVE KEYS', style: TextStyle(color: T.green, fontWeight: FontWeight.bold)),
              ),

              const SizedBox(height: 24),

              // ── MARKET ──
              const Text('MARKET',
                  style: TextStyle(color: T.gold, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              InkWell(
                onTap: pickMarket,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: T.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: T.muted),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(selected.name,
                          style: const TextStyle(color: T.green, fontWeight: FontWeight.bold)),
                      const Text('▼ পরিবর্তন করুন', style: TextStyle(color: T.dim, fontSize: 11)),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: T.green,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: start,
                  child: Text(
                    perm ? 'START FLOATING ROBOT' : 'GRANT + START',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (msg.isNotEmpty)
                Center(
                  child: Text(msg,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: T.gold, fontSize: 12)),
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint) {
    return TextField(
      controller: c,
      style: const TextStyle(color: T.green, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: T.dim, fontSize: 12),
        filled: true,
        fillColor: T.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: T.muted),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
    );
  }
}

// ───────────────── OVERLAY UI (view-only: no TextField / no ListView) ─────────────────
class OverlayHome extends StatefulWidget {
  const OverlayHome({super.key});
  @override
  State<OverlayHome> createState() => _OverlayHomeState();
}

class _OverlayHomeState extends State<OverlayHome> {
  String time = '--:--:--';
  Timer? timer;
  bool scanning = false;
  Market selected = markets.first;
  FinalSignal? finalSignal;
  List<Candle> candles = [];
  String lastCandleTime = ''; // last closed candle's timestamp, shown so the user can confirm data is fresh

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => time = DateFormat('HH:mm:ss').format(DateTime.now()));
      }
      // Re-check the saved market every tick too (cheap, and reload() makes
      // it accurate now) so the header chip updates even before you tap
      // SIGNAL, if you changed the market in the main app moments ago.
      loadMarket();
    });
    loadMarket();
  }

  Future<void> loadMarket() async {
    final m = await Store.market();
    if (!mounted) return;
    final next = markets.firstWhere((e) => e.td == m, orElse: () => markets.first);
    if (next.td != selected.td) {
      setState(() => selected = next);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> generate() async {
    // reload market in case it was changed in the main app since overlay opened
    await loadMarket();
    final marketAtRequest = selected; // freeze which market this specific scan is for
    final key = await Store.td();
    if (key.isEmpty) {
      setState(() {
        finalSignal = FinalSignal(
          grade: '-',
          direction: '-',
          accuracy: 0,
          color: T.dim,
          reason: 'Twelve Data key নেই — মূল অ্যাপে SAVE KEYS দিন',
        );
      });
      return;
    }
    setState(() => scanning = true);
    try {
      final cs = await fetchCandles(key, marketAtRequest.td);
      // if the user switched markets again while this fetch was running, drop this stale result
      final nowMarket = await Store.market();
      if (nowMarket != marketAtRequest.td) {
        if (mounted) setState(() => scanning = false);
        return;
      }
      final eng = runEngine(cs);
      final gKey = await Store.gem();
      Map<String, dynamic> ai = <String, dynamic>{
        'direction': eng.strength >= 50 ? 'CALL' : 'PUT',
        'ai': 0,
        'reason': 'No Gemini key — engine only',
        'ok': false,
      };
      if (gKey.isNotEmpty) {
        ai = await askGemini(key: gKey, market: marketAtRequest.name, candles: cs, eng: eng);
      }
      final fs = buildFinalSignal(
        eng: eng,
        aiOk: ai['ok'] as bool,
        aiDirection: ai['direction'] as String,
        aiConfidence: (ai['ai'] as num).toInt(),
        reason: ai['reason']?.toString() ?? '',
      );
      if (!mounted) return;
      setState(() {
        candles = cs;
        finalSignal = fs;
        lastCandleTime = cs.isNotEmpty ? cs.last.time : '';
        selected = marketAtRequest;
        scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        scanning = false;
        finalSignal = FinalSignal(
          grade: '-',
          direction: '-',
          accuracy: 0,
          color: T.dim,
          reason: 'Error: $e',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final border = finalSignal?.color ?? T.green;
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xF20A0A0A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: 1.5),
        ),
        // Column gets bounded height from the fixed-size overlay window
        // (height:600 set in showOverlay), so Expanded below is valid and
        // makes the button row ALWAYS reachable no matter how much content
        // sits above it — this is what fixes the "stuck overlay" bug.
        child: Column(
          children: [
            Row(
              children: [
                const Text('RTX ROBOT',
                    style: TextStyle(color: T.green, fontSize: 12, fontWeight: FontWeight.w900)),
                const Spacer(),
                // Prominent market chip in the header — always visible, always current.
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: T.gold.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: T.gold.withOpacity(0.6)),
                    ),
                    child: Text(selected.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: T.gold, fontSize: 13, fontWeight: FontWeight.w900)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(time, style: const TextStyle(color: T.dim, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  children: [
                    miniChart(),
                    const SizedBox(height: 10),
                    signalBox(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: scanning ? null : generate,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: T.green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: T.green),
                      ),
                      child: Center(
                        child: Text(
                          scanning ? 'SCAN...' : '🚀 SIGNAL',
                          style: const TextStyle(color: T.green, fontWeight: FontWeight.w900, fontSize: 14),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => FlutterOverlayWindow.closeOverlay(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    decoration: BoxDecoration(
                      color: T.card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: T.muted),
                    ),
                    child: const Text('✕', style: TextStyle(fontSize: 16, color: T.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget miniChart() {
    final list = candles.length > 15 ? candles.sublist(candles.length - 15) : candles;
    if (list.isEmpty) {
      return Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: T.muted),
        ),
        child: const Text('NO CHART YET', style: TextStyle(color: T.dim, fontSize: 11)),
      );
    }
    final maxH = list.map((e) => e.h).reduce(max);
    final minL = list.map((e) => e.l).reduce(min);
    final range = (maxH - minL) == 0 ? 0.001 : (maxH - minL);
    return Container(
      height: 52,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: T.muted),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: list.map((c) {
          final bull = c.c >= c.o;
          final h = ((c.c - minL) / range).clamp(0.15, 1.0);
          return Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              height: 42 * h,
              color: bull ? T.green : T.red,
            ),
          );
        }).toList(),
      ),
    );
  }

  // Indicator breakdown chips are intentionally NOT rendered here anymore —
  // per your request they run in the background only. This box now shows
  // the market name again (big, at the top) + the final decision + the
  // timestamp of the last candle used, so it's always obvious which market
  // and which fresh piece of data the signal belongs to.
  Widget signalBox() {
    if (scanning) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('SCANNING ${selected.name}...',
            style: const TextStyle(color: T.green, fontWeight: FontWeight.bold, fontSize: 13)),
      );
    }
    final fs = finalSignal;
    if (fs == null) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: Text(
          '[ READY ] Tap SIGNAL',
          textAlign: TextAlign.center,
          style: TextStyle(color: T.dim, fontWeight: FontWeight.bold, fontSize: 12),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fs.color.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Text(selected.name,
              style: const TextStyle(color: T.gold, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1)),
          const SizedBox(height: 8),
          Text('GRADE ${fs.grade}',
              style: TextStyle(color: fs.color, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 5),
          Text(fs.direction,
              style: TextStyle(color: fs.color, fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('ACCURACY ${fs.accuracy}%',
              style: const TextStyle(color: T.cyan, fontSize: 13, fontWeight: FontWeight.bold)),
          if (lastCandleTime.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text('Data: $lastCandleTime',
                style: const TextStyle(color: T.dim, fontSize: 10)),
          ],
          if (fs.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(fs.reason,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: T.dim, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

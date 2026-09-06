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

// ───────────────── CANDLE ─────────────────
class Candle {
  final double o, h, l, c;
  final String time; // raw "datetime" string from TwelveData
  Candle(this.o, this.h, this.l, this.c, this.time);
  factory Candle.fromJson(Map<String, dynamic> j) => Candle(
        double.parse(j['open'].toString()),
        double.parse(j['high'].toString()),
        double.parse(j['low'].toString()),
        double.parse(j['close'].toString()),
        (j['datetime'] ?? '').toString(),
      );
}

/// Pure technical-engine output — 11 indicators, ported 1:1 from the web
/// app's signalEngine.js (ADX+DI, Supertrend, Ichimoku, Fractal2, EMA8/21,
/// EMA21/50, RSI, Bollinger, MACD, Stochastic, Pattern). No grade/direction
/// here — [buildFinalSignal] decides that from engine + Gemini together.
class Signal {
  final double strength; // 0-100, 50 = neutral, >50 leans bullish, <50 bearish
  final int techConfidence; // 0-100, how much the 11 indicators agree with each other
  final Map<String, String> breakdown; // every indicator's own BULL/BEAR/NEUTRAL vote
  final Map<String, double> indicators; // every raw numeric value, sent to Gemini in full
  Signal({
    required this.strength,
    required this.techConfidence,
    required this.breakdown,
    required this.indicators,
  });
}

/// Final, user-facing decision after combining the technical engine with Gemini.
/// direction/grade/accuracy are ALWAYS resolved to a real CALL or PUT — never null.
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

// ══════════════════════════════════════════════════════════
//   CORE MATH HELPERS
// ══════════════════════════════════════════════════════════

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

/// 3-candle pattern read (engulfing / pin bar / reversal / 3-in-a-row).
/// Returns -2..2. Ported 1:1 from the web app's patternScore().
int patternScore(List<Candle> candles) {
  if (candles.length < 3) return 0;
  final last3 = candles.sublist(candles.length - 3);
  final c2 = last3[0], c1 = last3[1], c0 = last3[2]; // oldest -> newest
  bool bull(Candle c) => c.c > c.o;
  double body(Candle c) => (c.c - c.o).abs();
  final c0body = body(c0), c1body = body(c1), c2body = body(c2);
  final lw = min(c0.o, c0.c) - c0.l;
  final uw = c0.h - max(c0.o, c0.c);

  if (bull(c0) && !bull(c1) && c0.o <= c1.c && c0.c >= c1.o && c0body > c1body) return 2;
  if (!bull(c0) && bull(c1) && c0.o >= c1.c && c0.c <= c1.o && c0body > c1body) return -2;
  if (lw > c0body * 2 && uw < c0body * 0.3) return 1;
  if (uw > c0body * 2 && lw < c0body * 0.3) return -1;
  if (!bull(c2) && c1body < c2body * 0.3 && bull(c0) && c0.c > (c2.o + c2.c) / 2) return 2;
  if (bull(c2) && c1body < c2body * 0.3 && !bull(c0) && c0.c < (c2.o + c2.c) / 2) return -2;
  if (bull(c2) && bull(c1) && bull(c0)) return 1;
  if (!bull(c2) && !bull(c1) && !bull(c0)) return -1;
  return 0;
}

// ══════════════════════════════════════════════════════════
//   TOP-TIER INDICATORS (ADX, Supertrend, Ichimoku, Fractal2)
//   Ported 1:1 from the web app's signalEngine.js
// ══════════════════════════════════════════════════════════

Map<String, double>? calcADX(List<Candle> candles, [int p = 14]) {
  if (candles.length < p * 2 + 1) return null;
  final highs = candles.map((c) => c.h).toList();
  final lows = candles.map((c) => c.l).toList();
  final closes = candles.map((c) => c.c).toList();

  final plusDM = <double>[], minusDM = <double>[], trs = <double>[];
  for (var i = 1; i < candles.length; i++) {
    final upMove = highs[i] - highs[i - 1];
    final downMove = lows[i - 1] - lows[i];
    plusDM.add(upMove > downMove && upMove > 0 ? upMove : 0);
    minusDM.add(downMove > upMove && downMove > 0 ? downMove : 0);
    trs.add([
      highs[i] - lows[i],
      (highs[i] - closes[i - 1]).abs(),
      (lows[i] - closes[i - 1]).abs(),
    ].reduce(max));
  }

  List<double> wilderSmooth(List<double> arr, int period) {
    final out = <double>[arr.sublist(0, period).reduce((a, b) => a + b)];
    for (var i = period; i < arr.length; i++) {
      out.add(out.last - out.last / period + arr[i]);
    }
    return out;
  }

  final sTR = wilderSmooth(trs, p);
  final sPlus = wilderSmooth(plusDM, p);
  final sMinus = wilderSmooth(minusDM, p);

  final plusDI = <double>[], minusDI = <double>[];
  for (var i = 0; i < sPlus.length; i++) {
    final trv = sTR[i] == 0 ? 1 : sTR[i];
    plusDI.add(100 * sPlus[i] / trv);
    minusDI.add(100 * sMinus[i] / trv);
  }
  final dx = <double>[];
  for (var i = 0; i < plusDI.length; i++) {
    final denom = (plusDI[i] + minusDI[i]) == 0 ? 1 : (plusDI[i] + minusDI[i]);
    dx.add(100 * (plusDI[i] - minusDI[i]).abs() / denom);
  }

  if (dx.length < p) return null;
  var adxVal = dx.sublist(0, p).reduce((a, b) => a + b) / p;
  for (var i = p; i < dx.length; i++) {
    adxVal = (adxVal * (p - 1) + dx[i]) / p;
  }
  return {'adx': adxVal, 'plusDI': plusDI.last, 'minusDI': minusDI.last};
}

Map<String, double>? calcSupertrend(List<Candle> candles, [int period = 10, double mult = 3]) {
  if (candles.length < period + 2) return null;
  final highs = candles.map((c) => c.h).toList();
  final lows = candles.map((c) => c.l).toList();
  final closes = candles.map((c) => c.c).toList();

  final trs = <double>[];
  for (var i = 1; i < candles.length; i++) {
    trs.add([
      highs[i] - lows[i],
      (highs[i] - closes[i - 1]).abs(),
      (lows[i] - closes[i - 1]).abs(),
    ].reduce(max));
  }
  var atrVal = trs.sublist(0, period).reduce((a, b) => a + b) / period;
  final atrSeries = <double>[atrVal];
  for (var i = period; i < trs.length; i++) {
    atrVal = (atrVal * (period - 1) + trs[i]) / period;
    atrSeries.add(atrVal);
  }

  var trend = 1;
  var finalUpper = 0.0, finalLower = 0.0;
  final offset = candles.length - atrSeries.length;
  for (var i = 0; i < atrSeries.length; i++) {
    final idx = i + offset;
    final hl2 = (highs[idx] + lows[idx]) / 2;
    final bUpper = hl2 + mult * atrSeries[i];
    final bLower = hl2 - mult * atrSeries[i];
    if (i == 0) {
      finalUpper = bUpper;
      finalLower = bLower;
      continue;
    }
    final prevClose = closes[idx - 1];
    finalUpper = (bUpper < finalUpper || prevClose > finalUpper) ? bUpper : finalUpper;
    finalLower = (bLower > finalLower || prevClose < finalLower) ? bLower : finalLower;
    if (trend == 1 && closes[idx] < finalLower) trend = -1;
    else if (trend == -1 && closes[idx] > finalUpper) trend = 1;
  }
  return {'trend': trend.toDouble(), 'value': trend == 1 ? finalLower : finalUpper};
}

Map<String, double>? calcIchimoku(List<Candle> candles) {
  if (candles.length < 52) return null;
  final highs = candles.map((c) => c.h).toList();
  final lows = candles.map((c) => c.l).toList();
  final close = candles.last.c;
  double periodHL(int p) {
    final hs = highs.sublist(highs.length - p);
    final ls = lows.sublist(lows.length - p);
    return (hs.reduce(max) + ls.reduce(min)) / 2;
  }
  final tenkan = periodHL(9);
  final kijun = periodHL(26);
  final spanA = (tenkan + kijun) / 2;
  final spanB = periodHL(52);
  final aboveCloud = close > max(spanA, spanB);
  final belowCloud = close < min(spanA, spanB);
  final tkCross = tenkan > kijun ? 1.0 : (tenkan < kijun ? -1.0 : 0.0);
  return {
    'tenkan': tenkan,
    'kijun': kijun,
    'spanA': spanA,
    'spanB': spanB,
    'aboveCloud': aboveCloud ? 1 : 0,
    'belowCloud': belowCloud ? 1 : 0,
    'tkCross': tkCross,
  };
}

/// Confirmed-only Williams 5-bar fractal (n=2 each side) — never repaints.
/// Returns {'type': 1=low(bull)/-1=high(bear), 'age': candles since confirmed}.
Map<String, double>? calcFractal2(List<Candle> candles, [int n = 2]) {
  if (candles.length < n * 2 + 1) return null;
  final highs = candles.map((c) => c.h).toList();
  final lows = candles.map((c) => c.l).toList();
  final idx = candles.length - 1 - n;
  if (idx < n) return null;
  var isHigh = true, isLow = true;
  for (var i = 1; i <= n; i++) {
    if (!(highs[idx] > highs[idx - i] && highs[idx] > highs[idx + i])) isHigh = false;
    if (!(lows[idx] < lows[idx - i] && lows[idx] < lows[idx + i])) isLow = false;
  }
  final age = candles.length - 1 - (idx + n);
  if (isHigh) return {'type': -1, 'age': age.toDouble()};
  if (isLow) return {'type': 1, 'age': age.toDouble()};
  return null;
}

// ══════════════════════════════════════════════════════════
//   MASTER SIGNAL ENGINE — all 11 indicators
// ══════════════════════════════════════════════════════════
Signal runEngine(List<Candle> candles) {
  final bd = <String, String>{};
  final ind = <String, double>{};
  if (candles.length < 60) {
    return Signal(strength: 50, techConfidence: 50, breakdown: {'Status': 'LOW DATA'}, indicators: {});
  }

  final closes = candles.map((e) => e.c).toList();
  final last = closes.last;
  ind['lastClose'] = last;
  double score = 0;
  double maxScore = 0;

  // 1. ADX + DI — weight 16
  final ax = calcADX(candles, 14);
  if (ax != null) {
    double v;
    if (ax['adx']! > 25) {
      v = ax['plusDI']! > ax['minusDI']! ? 16 : -16;
    } else if (ax['adx']! > 20) {
      v = ax['plusDI']! > ax['minusDI']! ? 8 : -8;
    } else {
      v = ax['plusDI']! > ax['minusDI']! ? 4 : -4;
    }
    score += v;
    maxScore += 16;
    bd['ADX ${ax['adx']!.toStringAsFixed(0)}'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['adx'] = ax['adx']!;
    ind['plusDI'] = ax['plusDI']!;
    ind['minusDI'] = ax['minusDI']!;
  } else {
    bd['ADX'] = '→ NEUTRAL';
  }

  // 2. Supertrend — weight 16
  final st2 = calcSupertrend(candles, 10, 3);
  if (st2 != null) {
    final v = st2['trend']! == 1 ? 16.0 : -16.0;
    score += v;
    maxScore += 16;
    bd['Supertrend'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['supertrendTrend'] = st2['trend']!;
    ind['supertrendValue'] = st2['value']!;
  } else {
    bd['Supertrend'] = '→ NEUTRAL';
  }

  // 3. Ichimoku Cloud — weight 16
  final ich = calcIchimoku(candles);
  if (ich != null) {
    double v;
    if (ich['aboveCloud'] == 1) {
      v = 16;
    } else if (ich['belowCloud'] == 1) {
      v = -16;
    } else if (ich['tkCross'] != 0) {
      v = ich['tkCross']! * 4;
    } else {
      v = last >= ich['kijun']! ? 4 : -4;
    }
    score += v;
    maxScore += 16;
    bd['Ichimoku'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['ichiTenkan'] = ich['tenkan']!;
    ind['ichiKijun'] = ich['kijun']!;
    ind['ichiSpanA'] = ich['spanA']!;
    ind['ichiSpanB'] = ich['spanB']!;
    ind['ichiAboveCloud'] = ich['aboveCloud']!;
    ind['ichiBelowCloud'] = ich['belowCloud']!;
    ind['ichiTkCross'] = ich['tkCross']!;
  } else {
    bd['Ichimoku'] = '→ NEUTRAL';
  }

  // 4. Fractal 2 — weight 16, decays with age; falls back to 3-candle momentum
  final fr = calcFractal2(candles, 2);
  if (fr != null) {
    final decay = max(0.0, 1 - fr['age']! * 0.15);
    final v = fr['type']! == 1 ? 16 * decay : -16 * decay;
    score += v;
    maxScore += 16;
    bd['Fractal 2'] = fr['type']! == 1 ? '↑ BULL (▲)' : '↓ BEAR (▼)';
    ind['fractal2Type'] = fr['type']!;
    ind['fractal2Age'] = fr['age']!;
  } else {
    final isBullMomentum = last > closes[max(0, closes.length - 4)];
    final v = isBullMomentum ? 8.0 : -8.0; // fallback still actually votes, half weight
    score += v;
    maxScore += 16;
    bd['Fractal 2'] = isBullMomentum ? '↑ BULL' : '↓ BEAR';
    ind['fractal2Type'] = 0;
  }

  // 5. EMA 8/21 — weight up to 14, scaled by gap size
  final e8 = ema(closes, 8);
  final e21 = ema(closes, 21);
  if (e8 != null && e21 != null) {
    final gap = ((e8 - e21) / e21).abs() * 100;
    final w = min(14.0, gap * 250);
    final v = e8 > e21 ? w : -w;
    score += v;
    maxScore += 14;
    bd['EMA 8/21'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['ema8'] = e8;
    ind['ema21'] = e21;
  } else {
    bd['EMA 8/21'] = '→ NEUTRAL';
  }

  // 6. EMA 21/50 — weight 12
  final e50 = ema(closes, 50);
  if (e21 != null && e50 != null) {
    final v = e21 > e50 ? 12.0 : -12.0;
    score += v;
    maxScore += 12;
    bd['EMA 21/50'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['ema50'] = e50;
  } else {
    bd['EMA 21/50'] = '→ NEUTRAL';
  }

  // 7. RSI — weight up to 14, graduated by zone
  final r = rsi(closes, 14);
  if (r != null) {
    double v;
    if (r < 25) {
      v = 14;
    } else if (r < 35) {
      v = 9;
    } else if (r < 45) {
      v = 3;
    } else if (r > 75) {
      v = -14;
    } else if (r > 65) {
      v = -9;
    } else if (r > 55) {
      v = -3;
    } else {
      v = r >= 50 ? 1 : -1;
    }
    score += v;
    maxScore += 14;
    bd['RSI ${r.toStringAsFixed(0)}'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['rsi'] = r;
  } else {
    bd['RSI'] = '→ NEUTRAL';
  }

  // 8. Bollinger Bands — weight up to 12, graduated by %B
  final b = bb(closes, 20);
  if (b != null) {
    final pct = (last - b['lower']!) / (b['upper']! - b['lower']!);
    double v;
    if (pct < 0.05) {
      v = 12;
    } else if (pct < 0.2) {
      v = 7;
    } else if (pct < 0.4) {
      v = 3;
    } else if (pct > 0.95) {
      v = -12;
    } else if (pct > 0.8) {
      v = -7;
    } else if (pct > 0.6) {
      v = -3;
    } else {
      v = pct >= 0.5 ? 1 : -1;
    }
    score += v;
    maxScore += 12;
    bd['Bollinger'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['bbUpper'] = b['upper']!;
    ind['bbMid'] = b['mid']!;
    ind['bbLower'] = b['lower']!;
    ind['bbPct'] = pct;
  } else {
    bd['Bollinger'] = '→ NEUTRAL';
  }

  // 9. MACD — weight 12 (7 from line-vs-signal, 5 from histogram sign)
  final m = macd(closes);
  if (m != null) {
    final cv = m['line']! > m['signal']! ? 7.0 : -7.0;
    final hv = m['hist']! > 0 ? 5.0 : -5.0;
    score += cv + hv;
    maxScore += 12;
    bd['MACD'] = (cv + hv) > 0 ? '↑ BULL' : '↓ BEAR';
    ind['macdLine'] = m['line']!;
    ind['macdSignal'] = m['signal']!;
    ind['macdHist'] = m['hist']!;
  } else {
    bd['MACD'] = '→ NEUTRAL';
  }

  // 10. Stochastic — weight up to 10, graduated by zone
  final st = stoch(candles, 14);
  if (st != null) {
    double v;
    if (st < 20) {
      v = 10;
    } else if (st < 35) {
      v = 5;
    } else if (st > 80) {
      v = -10;
    } else if (st > 65) {
      v = -5;
    } else {
      v = st >= 50 ? 1 : -1;
    }
    score += v;
    maxScore += 10;
    bd['Stoch ${st.toStringAsFixed(0)}'] = v > 0 ? '↑ BULL' : '↓ BEAR';
    ind['stoch'] = st;
  } else {
    bd['Stoch'] = '→ NEUTRAL';
  }

  // 11. Candle Pattern — weight 10
  final pat = patternScore(candles);
  ind['patternScore'] = pat.toDouble();
  if (pat != 0) {
    final v = pat * 5.0;
    score += v;
    maxScore += 10;
    bd['Pattern'] = v > 0 ? '↑ BULL' : '↓ BEAR';
  } else {
    final lastC = candles.last;
    final isBullCandle = lastC.c > lastC.o;
    final v = isBullCandle ? 5.0 : -5.0; // fallback still actually votes, half weight
    score += v;
    maxScore += 10;
    bd['Pattern'] = isBullCandle ? '↑ BULL' : '↓ BEAR';
  }

  if (maxScore == 0) maxScore = 1;
  final strength = (((score / maxScore) + 1) / 2 * 100).clamp(0.0, 100.0).toDouble();
  final bulls = bd.values.where((e) => e.contains('BULL')).length;
  final bears = bd.values.where((e) => e.contains('BEAR')).length;
  final total = max(1, bulls + bears);
  final techConfidence = ((max(bulls, bears) / total) * 100).round();

  return Signal(strength: strength, techConfidence: techConfidence, breakdown: bd, indicators: ind);
}

/// Grade is purely about how CONFIDENT the final call is (0-99 accuracy),
/// independent of CALL vs PUT — a strong PUT and a strong CALL both reach A+.
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
  return {
    'grade': grade,
    'color': grade == 'C' ? T.muted : color,
  };
}

/// Combines the 11-indicator engine with Gemini's read into one final
/// decision. ALWAYS resolves to CALL or PUT — never leaves it undecided.
FinalSignal buildFinalSignal({
  required Signal eng,
  required bool aiOk,
  required String aiDirection,
  required int aiConfidence,
  required String reason,
}) {
  final techScore = ((eng.strength - 50).abs() * 2).clamp(0, 100).toDouble();
  final techDirection = eng.strength >= 50 ? 'CALL' : 'PUT';

  String finalDirection;
  int accuracy;

  if (!aiOk) {
    finalDirection = techDirection;
    accuracy = ((techScore * 0.7) + (eng.techConfidence * 0.3)).round().clamp(0, 95).toInt();
  } else {
    finalDirection = aiDirection;
    final agree = aiDirection == techDirection;
    final base = (techScore * 0.5) + (aiConfidence * 0.5);
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
// Main app and overlay run in two SEPARATE Flutter engines. shared_preferences
// caches everything in memory per engine on first getInstance() and normally
// never re-reads disk after that — reload() forces a fresh disk read every
// time, on both sides, which is what keeps market/API keys in sync.
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
    'https://api.twelvedata.com/time_series?symbol=${Uri.encodeComponent(symbol)}&interval=1min&outputsize=80&timezone=UTC&apikey=$key',
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

String _candleDump(List<Candle> candles, {int last = 30}) {
  final slice = candles.length > last ? candles.sublist(candles.length - last) : candles;
  return slice
      .map((c) =>
          '${c.o.toStringAsFixed(5)},${c.h.toStringAsFixed(5)},${c.l.toStringAsFixed(5)},${c.c.toStringAsFixed(5)}')
      .join(';');
}

/// Every raw numeric result from all 11 indicators — nothing omitted.
String _indicatorDump(Map<String, double> ind) {
  return ind.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(5)}').join(', ');
}

/// Every indicator's own BULL/BEAR/NEUTRAL vote — the same breakdown the
/// engine itself uses, so Gemini sees exactly what the engine saw.
String _voteDump(Map<String, String> bd) {
  return bd.entries.map((e) => '${e.key}:${e.value}').join(', ');
}

Future<Map<String, dynamic>> askGemini({
  required String key,
  required String market,
  required List<Candle> candles,
  required Signal eng,
}) async {
  try {
    final model = GenerativeModel(
      model: 'gemini-3.1-flash-lite',
      apiKey: key,
      generationConfig: GenerationConfig(
        temperature: 0.15,
        maxOutputTokens: 100,
        candidateCount: 1,
      ),
      systemInstruction: Content.system(
        'You are a strict 1-minute forex signal filter analyzing 11 technical '
        'indicators (ADX+DI, Supertrend, Ichimoku, Fractal2, EMA8/21, EMA21/50, '
        'RSI, Bollinger, MACD, Stochastic, Pattern). '
        'You ONLY ever output exactly one line in this exact format, nothing else: '
        'DIRECTION|CONFIDENCE|REASON\n'
        'DIRECTION must be exactly the word CALL or PUT in English (nothing else) — '
        'never blank, never both, always pick one with certainty. '
        'CONFIDENCE is an integer 0-100. '
        'REASON must be written in Bengali (বাংলা), up to about 20 words: '
        'if the indicators conflict or the setup looks risky/uncertain, explain '
        'in Bengali WHY it is risky or confusing; if the indicators agree well, '
        'explain in Bengali WHY you are confident. Either way REASON ends with '
        'the same certain direction already given in the DIRECTION field. '
        'No punctuation beyond commas in REASON. '
        'Never add greetings, disclaimers, markdown, or extra lines beyond the one required. '
        'Never refuse to answer — always pick CALL or PUT based on the data given.',
      ),
    );

    final prompt = '''
Pair: $market
Recent 1m candles (oldest→newest, o,h,l,c per candle, ; separated):
${_candleDump(candles)}

All 11 indicator votes: ${_voteDump(eng.breakdown)}
All raw indicator values: ${_indicatorDump(eng.indicators)}
Technical engine reading: strength=${eng.strength.toStringAsFixed(1)}/100, agreement=${eng.techConfidence}%

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
      await Store.saveMarket(picked.td);
      setState(() {
        selected = picked;
        msg = 'Market সেট হয়েছে: ${picked.name}';
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
                child: Text('HACKER FLOATING SIGNAL — 11 INDICATORS',
                    style: TextStyle(color: T.dim, fontSize: 10, letterSpacing: 1)),
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

// ───────────────── OVERLAY UI ─────────────────
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
  String lastCandleTimeLocal = ''; // UTC candle time converted to phone-local time

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => time = DateFormat('HH:mm:ss').format(DateTime.now()));
      }
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

  String _toLocalTimeLabel(String utcDatetime) {
    if (utcDatetime.isEmpty) return '';
    try {
      // TwelveData is requested with timezone=UTC, so parse as UTC then
      // convert to the phone's local time — matches the header clock exactly.
      final iso = '${utcDatetime.replaceFirst(' ', 'T')}Z';
      final dt = DateTime.parse(iso);
      final local = dt.toLocal();
      return DateFormat('HH:mm:ss').format(local);
    } catch (_) {
      return utcDatetime;
    }
  }

  Future<void> generate() async {
    await loadMarket();
    final marketAtRequest = selected;
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
        lastCandleTimeLocal = cs.isNotEmpty ? _toLocalTimeLabel(cs.last.time) : '';
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
        child: Column(
          children: [
            Row(
              children: [
                const Text('RTX ROBOT',
                    style: TextStyle(color: T.green, fontSize: 12, fontWeight: FontWeight.w900)),
                const Spacer(),
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
          final h = ((c.c - minL) / range).clamp(0.15, 1.0).toDouble();
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

  Widget signalBox() {
    if (scanning) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('SCANNING ${selected.name} (11 indicators)...',
            textAlign: TextAlign.center,
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
          if (lastCandleTimeLocal.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text('Data: $lastCandleTimeLocal (local)',
                style: const TextStyle(color: T.dim, fontSize: 10)),
          ],
          if (fs.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(fs.reason,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: T.dim, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

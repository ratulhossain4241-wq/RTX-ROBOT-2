import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

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
  static const ghostUpFill = Color(0x73FFFFFF);
  static const ghostUpBorder = Color(0xFFFFFFFF);
  static const ghostDownFill = Color(0x73F3BA2F);
  static const ghostDownBorder = Color(0xFFF3BA2F);
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
  final String time;
  Candle(this.o, this.h, this.l, this.c, this.time);
  factory Candle.fromJson(Map<String, dynamic> j) => Candle(
        double.parse(j['open'].toString()),
        double.parse(j['high'].toString()),
        double.parse(j['low'].toString()),
        double.parse(j['close'].toString()),
        (j['datetime'] ?? '').toString(),
      );
}

class GhostCandle {
  final double open, high, low, close;
  GhostCandle({required this.open, required this.high, required this.low, required this.close});
  bool get isUp => close >= open;
}

class Signal {
  final double strength;
  final int techConfidence;
  final Map<String, String> breakdown;
  final Map<String, double> indicators;
  Signal({
    required this.strength,
    required this.techConfidence,
    required this.breakdown,
    required this.indicators,
  });
}

class FinalSignal {
  final String grade;
  final String direction;
  final int accuracy;
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

int patternScore(List<Candle> candles) {
  if (candles.length < 3) return 0;
  final last3 = candles.sublist(candles.length - 3);
  final c2 = last3[0], c1 = last3[1], c0 = last3[2];
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
//   TOP-TIER INDICATORS
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
//   NEW: ATR / SUPPORT-RESISTANCE / FVG / TREND
//   (context Gemini needs to draw grounded, non-random candles)
// ══════════════════════════════════════════════════════════

/// Wilder ATR — used both as prompt context AND to sanity-check Gemini's
/// output range after the fact (rejects absurdly large/small candles).
double? calcATR(List<Candle> candles, [int period = 14]) {
  if (candles.length < period + 1) return null;
  final trs = <double>[];
  for (var i = 1; i < candles.length; i++) {
    final c = candles[i];
    final prevClose = candles[i - 1].c;
    trs.add([c.h - c.l, (c.h - prevClose).abs(), (c.l - prevClose).abs()].reduce(max));
  }
  var val = trs.sublist(0, period).reduce((a, b) => a + b) / period;
  for (var i = period; i < trs.length; i++) {
    val = (val * (period - 1) + trs[i]) / period;
  }
  return val;
}

/// Finds the nearest support (below price) and resistance (above price)
/// from confirmed swing highs/lows over the recent lookback window,
/// clustering nearby touches into one level so noise doesn't create
/// dozens of near-duplicate levels.
Map<String, double?> findSupportResistance(List<Candle> candles, {int lookback = 150, int n = 3}) {
  final recent = candles.length > lookback ? candles.sublist(candles.length - lookback) : candles;
  if (recent.length < n * 2 + 1) return {'support': null, 'resistance': null};
  final price = recent.last.c;
  final swingHighs = <double>[];
  final swingLows = <double>[];
  for (var i = n; i < recent.length - n; i++) {
    final h = recent[i].h;
    final l = recent[i].l;
    var isHigh = true, isLow = true;
    for (var k = 1; k <= n; k++) {
      if (!(h > recent[i - k].h && h > recent[i + k].h)) isHigh = false;
      if (!(l < recent[i - k].l && l < recent[i + k].l)) isLow = false;
    }
    if (isHigh) swingHighs.add(h);
    if (isLow) swingLows.add(l);
  }

  // Cluster: merge levels within 0.05% of each other, keep the mean.
  List<double> cluster(List<double> levels) {
    if (levels.isEmpty) return [];
    final sorted = [...levels]..sort();
    final out = <double>[];
    var group = <double>[sorted.first];
    for (var i = 1; i < sorted.length; i++) {
      if ((sorted[i] - group.last).abs() / sorted[i] < 0.0005) {
        group.add(sorted[i]);
      } else {
        out.add(group.reduce((a, b) => a + b) / group.length);
        group = [sorted[i]];
      }
    }
    out.add(group.reduce((a, b) => a + b) / group.length);
    return out;
  }

  final resLevels = cluster(swingHighs).where((v) => v > price).toList()..sort((a, b) => a.compareTo(b));
  final supLevels = cluster(swingLows).where((v) => v < price).toList()..sort((a, b) => b.compareTo(a));

  return {
    'support': supLevels.isNotEmpty ? supLevels.first : null,
    'resistance': resLevels.isNotEmpty ? resLevels.first : null,
  };
}

class FVGZone {
  final double top, bottom;
  final bool bullish;
  FVGZone({required this.top, required this.bottom, required this.bullish});
}

/// 3-candle Fair Value Gap detection: candle[i-2].high < candle[i].low is a
/// bullish imbalance (candle[i-2].low > candle[i].high = bearish). Only
/// UNFILLED gaps (price hasn't traded back through them yet) are returned —
/// filled gaps have already done their job and no longer matter.
List<FVGZone> detectFVG(List<Candle> candles, {int lookback = 80, int maxZones = 3}) {
  final recent = candles.length > lookback ? candles.sublist(candles.length - lookback) : candles;
  final zones = <MapEntry<FVGZone, int>>[];
  for (var i = 2; i < recent.length; i++) {
    final left = recent[i - 2];
    final right = recent[i];
    if (left.h < right.l) {
      zones.add(MapEntry(FVGZone(top: right.l, bottom: left.h, bullish: true), i));
    } else if (left.l > right.h) {
      zones.add(MapEntry(FVGZone(top: left.l, bottom: right.h, bullish: false), i));
    }
  }
  final unfilled = <FVGZone>[];
  for (final entry in zones) {
    final zone = entry.key;
    final createdAt = entry.value;
    var filled = false;
    for (var j = createdAt + 1; j < recent.length; j++) {
      final c = recent[j];
      if (zone.bullish && c.l <= zone.bottom) { filled = true; break; }
      if (!zone.bullish && c.h >= zone.top) { filled = true; break; }
    }
    if (!filled) unfilled.add(zone);
  }
  return unfilled.length > maxZones ? unfilled.sublist(unfilled.length - maxZones) : unfilled;
}

/// Simple structural trend read from EMA50 vs EMA200 (falls back to a
/// 50-candle price comparison when there isn't 200 candles yet).
String detectTrend(List<Candle> candles) {
  final closes = candles.map((c) => c.c).toList();
  final e50 = ema(closes, 50);
  if (e50 == null) return 'UNKNOWN';
  if (closes.length >= 200) {
    final e200 = ema(closes, 200);
    if (e200 != null) {
      if (e50 > e200 * 1.0005) return 'UPTREND';
      if (e50 < e200 * 0.9995) return 'DOWNTREND';
      return 'SIDEWAYS';
    }
  }
  final refIdx = max(0, closes.length - 50);
  final diff = (closes.last - closes[refIdx]) / closes[refIdx];
  if (diff > 0.001) return 'UPTREND';
  if (diff < -0.001) return 'DOWNTREND';
  return 'SIDEWAYS';
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
    final v = isBullMomentum ? 8.0 : -8.0;
    score += v;
    maxScore += 16;
    bd['Fractal 2'] = isBullMomentum ? '↑ BULL' : '↓ BEAR';
    ind['fractal2Type'] = 0;
  }

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
    final v = isBullCandle ? 5.0 : -5.0;
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
// outputsize now 200 (was 80) — engine and Gemini context both benefit
// from the deeper history, especially Ichimoku (needs 52+) and S/R.
Future<List<Candle>> fetchCandles(String key, String symbol) async {
  final uri = Uri.parse(
    'https://api.twelvedata.com/time_series?symbol=${Uri.encodeComponent(symbol)}&interval=1min&outputsize=200&timezone=UTC&apikey=$key',
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

String _candleDump(List<Candle> candles, {int last = 40}) {
  final slice = candles.length > last ? candles.sublist(candles.length - last) : candles;
  return slice
      .map((c) =>
          '${c.o.toStringAsFixed(5)},${c.h.toStringAsFixed(5)},${c.l.toStringAsFixed(5)},${c.c.toStringAsFixed(5)}')
      .join(';');
}

String _voteDump(Map<String, String> bd) {
  return bd.entries.map((e) => '${e.key}:${e.value}').join(', ');
}

String _fvgDump(List<FVGZone> zones, int decimals) {
  if (zones.isEmpty) return 'none';
  return zones
      .map((z) =>
          '${z.bullish ? "BULLISH" : "BEARISH"}(${z.bottom.toStringAsFixed(decimals)}-${z.top.toStringAsFixed(decimals)})')
      .join(', ');
}

int _decimalsFor(String symbol) => symbol.toUpperCase().contains('JPY') ? 3 : 5;

const _ghostSystemInstruction =
    'You are a strict 1-minute forex candle predictor. You are given: 11 '
    'technical indicator votes (ADX+DI, Supertrend, Ichimoku, Fractal2, '
    'EMA8/21, EMA21/50, RSI, Bollinger, MACD, Stochastic, Pattern), the '
    'current ATR (average true range, i.e. typical candle size), the nearest '
    'support and resistance levels, any unfilled Fair Value Gap zones, and '
    'the overall trend (UPTREND/DOWNTREND/SIDEWAYS).\n'
    'You predict the NEXT TWO consecutive 1-minute candles (candle 1 = next '
    'minute, candle 2 = the minute after that). The two candles are '
    'INDEPENDENT — candle 2 does not have to move the same direction as '
    'candle 1; judge each one purely on its own merits.\n'
    'Ground your prediction in ALL the given context: respect support/'
    'resistance as areas price may reverse or stall at, treat unfilled FVG '
    'zones as magnets price may move toward, do not fight the stated overall '
    'trend without a strong reason from the indicators, and keep each '
    'candle\'s total range (high-low) realistic relative to the given ATR — '
    'normally between 0.3x and 2.5x ATR, never wildly outside it.\n'
    'You ONLY ever output exactly one line in this exact format, nothing else:\n'
    'O1|H1|L1|C1|H2|L2|C2|CONFIDENCE|REASON\n'
    'O1, H1, L1, C1 are candle 1 open/high/low/close. O1 must equal the last '
    'known close given to you. H1 must be >= max(O1,C1). L1 must be <= min(O1,C1).\n'
    'H2, L2, C2 are candle 2 high/low/close (candle 2 open is fixed to equal '
    'C1, so do not output it). H2 must be >= max(C1,C2). L2 must be <= min(C1,C2).\n'
    'All six prices use the same number of decimal places as the input prices.\n'
    'CONFIDENCE is an integer 0-100, your confidence in candle 1.\n'
    'REASON must be written in Bengali (বাংলা), up to about 20 words, '
    'referencing WHICH context (trend, S/R, FVG, or indicators) drove your '
    'call. No punctuation beyond commas in REASON.\n'
    'Never add greetings, disclaimers, markdown, or extra lines beyond the one required.\n'
    'Never refuse to answer — always output definite predicted candles.';

/// Predicts the next TWO ghost candles via Gemini's REST API directly.
/// Now includes ATR, support/resistance, FVG zones, and trend as context,
/// and validates the response's range against ATR afterward — an
/// out-of-bounds candle is rejected and the fallback is used instead,
/// which is what stops "random-looking" AI candles from reaching the UI.
Future<Map<String, dynamic>> predictGhostCandles({
  required String key,
  required String market,
  required List<Candle> candles,
  required Signal eng,
}) async {
  final lastClose = candles.last.c;
  final decimals = _decimalsFor(market);
  final atrVal = calcATR(candles, 14) ?? (candles.last.h - candles.last.l);
  final sr = findSupportResistance(candles);
  final fvg = detectFVG(candles);
  final trend = detectTrend(candles);

  Map<String, dynamic> fallback(String reasonText, String errorType) {
    final recent = candles.length > 10 ? candles.sublist(candles.length - 10) : candles;
    final avgRange = recent.map((c) => c.h - c.l).reduce((a, b) => a + b) / recent.length;
    final bullish = eng.strength >= 50;
    final move = avgRange * 0.4;

    final c1o = lastClose;
    final c1c = bullish ? c1o + move : c1o - move;
    final c1h = max(c1o, c1c) + avgRange * 0.15;
    final c1l = min(c1o, c1c) - avgRange * 0.15;

    final c2o = c1c;
    final c2c = bullish ? c2o + move * 0.7 : c2o - move * 0.7;
    final c2h = max(c2o, c2c) + avgRange * 0.15;
    final c2l = min(c2o, c2c) - avgRange * 0.15;

    double round(double n) => double.parse(n.toStringAsFixed(decimals));
    return {
      'candle1': GhostCandle(open: round(c1o), high: round(c1h), low: round(c1l), close: round(c1c)),
      'candle2': GhostCandle(open: round(c2o), high: round(c2h), low: round(c2l), close: round(c2c)),
      'confidence': 0,
      'reason': reasonText,
      'ok': false,
      'errorType': errorType,
    };
  }

  if (key.isEmpty) {
    return fallback('Gemini key নেই — শুধু ইন্ডিকেটর দিয়ে অনুমান করা হলো', 'no_key');
  }

  final srLine =
      'Support: ${sr['support'] != null ? sr['support']!.toStringAsFixed(decimals) : "none nearby"}, '
      'Resistance: ${sr['resistance'] != null ? sr['resistance']!.toStringAsFixed(decimals) : "none nearby"}';

  final prompt = '''
Pair: $market
Recent 1m candles (oldest→newest, o,h,l,c per candle, ; separated), from a 200-candle history:
${_candleDump(candles)}

Last known close (this is O1, the open of candle 1): ${lastClose.toStringAsFixed(decimals)}
Overall trend (from 200-candle history): $trend
$srLine
Unfilled Fair Value Gap zones: ${_fvgDump(fvg, decimals)}
Current ATR (typical 1m candle range): ${atrVal.toStringAsFixed(decimals)}
All 11 indicator votes: ${_voteDump(eng.breakdown)}
Technical engine reading: strength=${eng.strength.toStringAsFixed(1)}/100, agreement=${eng.techConfidence}%

Respond with exactly one line: O1|H1|L1|C1|H2|L2|C2|CONFIDENCE|REASON
''';

  http.Response res;
  try {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=${Uri.encodeComponent(key)}',
    );
    res = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'systemInstruction': {
              'parts': [
                {'text': _ghostSystemInstruction}
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
            'generationConfig': {'temperature': 0.15, 'maxOutputTokens': 160, 'candidateCount': 1},
          }),
        )
        .timeout(const Duration(seconds: 15));
  } on TimeoutException {
    return fallback('Gemini রেসপন্সে সময় বেশি লাগছে (timeout), ইন্ডিকেটর দিয়ে অনুমান', 'timeout');
  } catch (e) {
    return fallback('নেটওয়ার্ক/সার্ভার সমস্যা: $e', 'network');
  }

  Map<String, dynamic> body;
  try {
    body = jsonDecode(res.body) as Map<String, dynamic>;
  } catch (_) {
    return fallback('Gemini রেসপন্স পার্স করা যায়নি (status ${res.statusCode})', 'parse');
  }

  if (res.statusCode != 200 || body['error'] != null) {
    final err = body['error'] as Map<String, dynamic>?;
    final msg = err?['message']?.toString() ?? 'Unknown error';
    final details = (err?['details'] as List?) ?? [];
    final reasonCode = details
        .whereType<Map>()
        .map((d) => d['reason']?.toString() ?? '')
        .firstWhere((r) => r.isNotEmpty, orElse: () => '');

    if (reasonCode == 'ACCESS_TOKEN_TYPE_UNSUPPORTED') {
      return fallback(
        'Gemini key (AQ. ফরম্যাট) দিয়ে সরাসরি REST কল Google-এর বাগের কারণে কাজ করছে না — AI Studio থেকে নতুন key ট্রাই করুন',
        'aq_key_bug',
      );
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      return fallback('Gemini API key ভুল বা অবৈধ ($msg)', 'auth');
    }
    if (res.statusCode == 404) {
      return fallback('Gemini মডেল পাওয়া যায়নি ($msg)', 'not_found');
    }
    if (res.statusCode == 429) {
      return fallback('Gemini দৈনিক/মিনিট লিমিট শেষ, একটু পর আবার চেষ্টা করুন', 'rate_limit');
    }
    if (res.statusCode >= 500) {
      return fallback('Gemini সার্ভারে সাময়িক সমস্যা, একটু পর আবার চেষ্টা করুন', 'server');
    }
    return fallback('Gemini error (${res.statusCode}): $msg', 'bad_request');
  }

  final candidates = body['candidates'] as List?;
  final text = (candidates != null && candidates.isNotEmpty)
      ? (candidates[0]['content']?['parts']?[0]?['text']?.toString() ?? '')
      : '';
  if (text.trim().isEmpty) {
    return fallback('Gemini থেকে কোনো উত্তর আসেনি (খালি রেসপন্স)', 'empty');
  }

  final parts = text.trim().split('|');
  if (parts.length < 9) {
    return fallback('AI রেসপন্স ফরম্যাট ভুল ছিলো, ইঞ্জিন দিয়ে অনুমান করা হলো', 'format');
  }

  try {
    final o1 = double.parse(parts[0].trim());
    final h1 = double.parse(parts[1].trim());
    final l1 = double.parse(parts[2].trim());
    final c1 = double.parse(parts[3].trim());
    final h2 = double.parse(parts[4].trim());
    final l2 = double.parse(parts[5].trim());
    final c2 = double.parse(parts[6].trim());
    final confidence =
        int.tryParse(parts[7].trim().replaceAll(RegExp(r'[^0-9]'), '')) ?? 50;
    final reason = parts.sublist(8).join('|').trim();
    final o2 = c1;

    final range1Valid = h1 >= max(o1, c1) && l1 <= min(o1, c1);
    final range2Valid = h2 >= max(o2, c2) && l2 <= min(o2, c2);
    if (!range1Valid || !range2Valid) {
      return fallback('AI ভুল রেঞ্জের ক্যান্ডেল দিয়েছে, ইঞ্জিন দিয়ে অনুমান করা হলো', 'range_invalid');
    }

    // ATR sanity check — this is what actually stops "random" candles:
    // if Gemini ignores the given ATR and outputs a candle way outside
    // realistic size (too huge OR suspiciously flat), reject it.
    final range1 = h1 - l1;
    final range2 = h2 - l2;
    final minOk = atrVal * 0.15;
    final maxOk = atrVal * 4.0;
    if (range1 < minOk || range1 > maxOk || range2 < minOk || range2 > maxOk) {
      return fallback(
        'AI-এর ক্যান্ডেল সাইজ বর্তমান ATR-এর তুলনায় অস্বাভাবিক ছিলো, ইঞ্জিন দিয়ে অনুমান করা হলো',
        'atr_out_of_range',
      );
    }

    double round(double n) => double.parse(n.toStringAsFixed(decimals));
    return {
      'candle1': GhostCandle(open: round(o1), high: round(h1), low: round(l1), close: round(c1)),
      'candle2': GhostCandle(open: round(o2), high: round(h2), low: round(l2), close: round(c2)),
      'confidence': confidence.clamp(0, 100),
      'reason': reason.isNotEmpty ? reason : 'কোনো কারণ দেওয়া হয়নি',
      'ok': true,
      'errorType': null,
    };
  } catch (e) {
    return fallback('AI সংখ্যা পার্স করা যায়নি: $e', 'number_parse');
  }
}

// ───────────────── LAUNCH PAGE ─────────────────
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
                child: Text('HACKER FLOATING SIGNAL — 11 INDICATORS + GHOST CANDLE',
                    style: TextStyle(color: T.dim, fontSize: 10, letterSpacing: 1)),
              ),
              const SizedBox(height: 24),
              Text(perm ? 'OVERLAY PERMISSION: ON' : 'OVERLAY PERMISSION: OFF',
                  style: TextStyle(
                      color: perm ? T.green : T.red, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              const Text('API KEYS',
                  style: TextStyle(color: T.gold, fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              _field(tdCtrl, 'Twelve Data API Key (আবশ্যক)'),
              const SizedBox(height: 10),
              _field(gemCtrl, 'Gemini API Key (ঐচ্ছিক, ঘোস্ট ক্যান্ডেলের জন্য)'),
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

// ───────────────── GHOST CANDLE CHART PAINTER ─────────────────
class _OhlcBox {
  final double o, h, l, c;
  final bool isGhost;
  _OhlcBox({required this.o, required this.h, required this.l, required this.c, this.isGhost = false});
  bool get isUp => c >= o;
}

class GhostCandlePainter extends CustomPainter {
  final List<Candle> realCandles;
  final GhostCandle? ghost1;
  final GhostCandle? ghost2;
  GhostCandlePainter({required this.realCandles, this.ghost1, this.ghost2});

  @override
  void paint(Canvas canvas, Size size) {
    final all = <_OhlcBox>[
      for (final c in realCandles) _OhlcBox(o: c.o, h: c.h, l: c.l, c: c.c),
    ];
    if (ghost1 != null) {
      all.add(_OhlcBox(o: ghost1!.open, h: ghost1!.high, l: ghost1!.low, c: ghost1!.close, isGhost: true));
    }
    if (ghost2 != null) {
      all.add(_OhlcBox(o: ghost2!.open, h: ghost2!.high, l: ghost2!.low, c: ghost2!.close, isGhost: true));
    }
    if (all.isEmpty) return;

    final maxH = all.map((e) => e.h).reduce(max);
    final minL = all.map((e) => e.l).reduce(min);
    final range = (maxH - minL) == 0 ? 0.0001 : (maxH - minL);
    final slotW = size.width / all.length;
    final bodyW = slotW * 0.55;

    double yFor(double v) => size.height - ((v - minL) / range) * size.height;

    for (var i = 0; i < all.length; i++) {
      final box = all[i];
      final cx = slotW * i + slotW / 2;
      final up = box.isUp;

      final lineColor = box.isGhost
          ? (up ? T.ghostUpBorder : T.ghostDownBorder)
          : (up ? T.green : T.red);
      final fillColor = box.isGhost
          ? (up ? T.ghostUpFill : T.ghostDownFill)
          : (up ? T.green : T.red);

      canvas.drawLine(
        Offset(cx, yFor(box.h)),
        Offset(cx, yFor(box.l)),
        Paint()
          ..color = lineColor
          ..strokeWidth = 1.2,
      );

      final bodyTop = yFor(max(box.o, box.c));
      final bodyBottom = max(yFor(min(box.o, box.c)), bodyTop + 1.5);
      final rect = Rect.fromLTRB(cx - bodyW / 2, bodyTop, cx + bodyW / 2, bodyBottom);
      canvas.drawRect(rect, Paint()..color = fillColor);
      if (box.isGhost) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = lineColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3,
        );
      }
    }

    if (ghost1 != null && realCandles.isNotEmpty) {
      final dx = slotW * realCandles.length;
      canvas.drawLine(
        Offset(dx, 0),
        Offset(dx, size.height),
        Paint()
          ..color = T.muted
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant GhostCandlePainter oldDelegate) {
    return oldDelegate.realCandles != realCandles ||
        oldDelegate.ghost1 != ghost1 ||
        oldDelegate.ghost2 != ghost2;
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
  bool predicting = false;
  Market selected = markets.first;
  FinalSignal? finalSignal;
  List<Candle> candles = [];
  List<GhostCandle>? predictedCandles;
  String predictedReason = '';
  String lastCandleTimeLocal = '';

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
    setState(() {
      scanning = true;
      predictedCandles = null;
      predictedReason = '';
    });
    try {
      final cs = await fetchCandles(key, marketAtRequest.td);
      final nowMarket = await Store.market();
      if (nowMarket != marketAtRequest.td) {
        if (mounted) setState(() => scanning = false);
        return;
      }
      final eng = runEngine(cs);
      final gKey = await Store.gem();

      setState(() => predicting = true);
      final gh = await predictGhostCandles(
        key: gKey,
        market: marketAtRequest.name,
        candles: cs,
        eng: eng,
      );
      if (!mounted) return;
      setState(() => predicting = false);

      final c1 = gh['candle1'] as GhostCandle;
      final c2 = gh['candle2'] as GhostCandle;
      final aiDirection = c1.isUp ? 'CALL' : 'PUT';
      final aiConfidence = gh['confidence'] as int;
      final aiOk = gh['ok'] as bool;
      final reason = gh['reason'] as String;

      final fs = buildFinalSignal(
        eng: eng,
        aiOk: aiOk,
        aiDirection: aiDirection,
        aiConfidence: aiConfidence,
        reason: reason,
      );

      if (!mounted) return;
      setState(() {
        candles = cs;
        finalSignal = fs;
        predictedCandles = [c1, c2];
        predictedReason = reason;
        lastCandleTimeLocal = cs.isNotEmpty ? _toLocalTimeLabel(cs.last.time) : '';
        selected = marketAtRequest;
        scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        scanning = false;
        predicting = false;
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
                    candleChart(),
                    if (predictedCandles != null) ...[
                      const SizedBox(height: 6),
                      ghostLegend(),
                    ],
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

  Widget candleChart() {
    final list = candles.length > 15 ? candles.sublist(candles.length - 15) : candles;
    if (list.isEmpty) {
      return Container(
        height: 90,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: T.muted),
        ),
        child: const Text('NO CHART YET', style: TextStyle(color: T.dim, fontSize: 11)),
      );
    }
    return Container(
      height: 90,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: T.muted),
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: GhostCandlePainter(
          realCandles: list,
          ghost1: predictedCandles != null && predictedCandles!.isNotEmpty ? predictedCandles![0] : null,
          ghost2: predictedCandles != null && predictedCandles!.length > 1 ? predictedCandles![1] : null,
        ),
      ),
    );
  }

  Widget ghostLegend() {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: T.ghostUpFill, border: Border.all(color: T.ghostUpBorder), borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          const Text('সাদা = AI প্রেডিক্টেড UP', style: TextStyle(color: T.dim, fontSize: 9)),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: T.ghostDownFill, border: Border.all(color: T.ghostDownBorder), borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          const Text('গোল্ড = AI প্রেডিক্টেড DOWN', style: TextStyle(color: T.dim, fontSize: 9)),
        ]),
      ],
    );
  }

  Widget signalBox() {
    if (scanning) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          predicting ? 'Gemini ভাবছে (২০০ ক্যান্ডেল, S/R, FVG সহ)...' : 'SCANNING ${selected.name} (200 candles)...',
          textAlign: TextAlign.center,
          style: const TextStyle(color: T.green, fontWeight: FontWeight.bold, fontSize: 13),
        ),
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

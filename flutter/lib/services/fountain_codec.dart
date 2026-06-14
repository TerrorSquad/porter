import 'dart:math';

/// Mix constant for seeding the PRNG from a sequence number. Must match
/// nodejs/src/lib/fountain.ts's SEED_XOR exactly.
const int _seedXor = 0x9e3779b9;

/// xorshift32 (Marsaglia, shifts 13/17/5). Must stay bit-for-bit identical to
/// nodejs/src/lib/fountain.ts's xorshift32 — encoder and decoder derive
/// (degree, indices) independently from the same `seq`.
///
/// [x] must be a 32-bit value (0..0xFFFFFFFF) on entry; the result is too.
int _xorshift32(int x) {
  x = (x ^ (x << 13)) & 0xFFFFFFFF;
  x = x ^ (x >> 17);
  x = (x ^ (x << 5)) & 0xFFFFFFFF;
  return x;
}

/// Returns a closure that yields successive uint32 values, seeded from [seq].
int Function() makeRng(int seq) {
  int state = (seq ^ _seedXor) & 0xFFFFFFFF;
  if (state == 0) state = _seedXor;
  return () {
    state = _xorshift32(state);
    return state;
  };
}

/// Integer-weight degree distribution: `cumWeights[0] = 0`, `cumWeights[d]` =
/// sum of weights for degrees `1..d`.
class DegreeTable {
  final List<int> cumWeights;
  final int total;

  const DegreeTable(this.cumWeights, this.total);
}

/// Robust-soliton-inspired degree distribution, expressed entirely with
/// integer weights so the same table (and the same draw-by-modulo) produces
/// identical degrees in TS and Dart. Must stay in sync with
/// nodejs/src/lib/fountain.ts's buildDegreeTable.
///
/// - weight(1) = 1, weight(i) = floor(K / (i*(i-1))) for i = 2..K
///   (approximates the ideal soliton distribution rho(i); rho(2) dominates)
/// - a "tau" correction spreads extra weight across the low degrees
///   1..S-1 (S = floor(sqrt(K))) and adds a spike of weight S at degree S,
///   mirroring robust soliton's tau(i) term and mitigating the last-block
///   problem
/// - K <= 2: degree is always 1 (avoids degenerate tables for trivial transfers)
DegreeTable buildDegreeTable(int k) {
  if (k <= 2) {
    return const DegreeTable([0, 1], 1);
  }

  final weights = List<int>.filled(k + 1, 0);
  weights[1] = 1;
  for (int i = 2; i <= k; i++) {
    weights[i] = max(1, k ~/ (i * (i - 1)));
  }

  final s = max(2, sqrt(k).floor());
  for (int i = 1; i < s; i++) {
    weights[i] += max(1, s ~/ i);
  }
  weights[s] += s;

  final cumWeights = List<int>.filled(k + 1, 0);
  int running = 0;
  for (int i = 1; i <= k; i++) {
    running += weights[i];
    cumWeights[i] = running;
  }

  return DegreeTable(cumWeights, running);
}

int _pickDegree(int r, List<int> cumWeights) {
  for (int d = 1; d < cumWeights.length; d++) {
    if (r < cumWeights[d]) return d;
  }
  return cumWeights.length - 1;
}

/// The (degree, source-block indices) tuple derived for one fountain symbol.
/// [indices] are 1-based and sorted ascending.
class SampledIndices {
  final int degree;
  final List<int> indices;

  const SampledIndices(this.degree, this.indices);
}

/// Derives the (degree, source-block indices) tuple for symbol [seq] over [k]
/// source blocks. Pass a precomputed [table] (from [buildDegreeTable]) to
/// avoid rebuilding it per call. Must stay in sync with
/// nodejs/src/lib/fountain.ts's sampleIndices.
SampledIndices sampleIndices(int seq, int k, [DegreeTable? table]) {
  final t = table ?? buildDegreeTable(k);
  final rng = makeRng(seq);

  final r = rng() % t.total;
  final degree = _pickDegree(r, t.cumWeights);

  final indices = <int>{};
  while (indices.length < degree && indices.length < k) {
    indices.add((rng() % k) + 1);
  }

  final sorted = indices.toList()..sort();
  return SampledIndices(sorted.length, sorted);
}

//! Fountain (LT-code) PRNG and degree table. Must stay bit-for-bit identical
//! to `nodejs/src/lib/fountain.ts` and `flutter/lib/services/fountain_codec.dart`
//! -- sender and receiver derive `(degree, indices)` independently from the
//! same `seq`, so any drift here breaks fountain-mode decoding silently.

/// Mix constant for seeding the PRNG from a sequence number. Must match
/// nodejs/src/lib/fountain.ts's SEED_XOR exactly.
const SEED_XOR: u32 = 0x9e3779b9;

/// xorshift32 (Marsaglia, shifts 13/17/5). `u32` wraps natively in Rust, so
/// unlike the TS/Dart ports no explicit masking is needed -- the shift
/// amounts and XOR order must still match exactly.
fn xorshift32(x: u32) -> u32 {
    let mut x = x;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    x
}

/// Returns a closure that yields successive u32 values, seeded from `seq`.
pub fn make_rng(seq: u32) -> impl FnMut() -> u32 {
    let mut state = seq ^ SEED_XOR;
    if state == 0 {
        state = SEED_XOR;
    }
    move || {
        state = xorshift32(state);
        state
    }
}

/// Integer-weight degree distribution: `cum_weights[0] = 0`, `cum_weights[d]`
/// = sum of weights for degrees `1..d`.
pub struct DegreeTable {
    pub cum_weights: Vec<u32>,
    pub total: u32,
}

/// Robust-soliton-inspired degree distribution, expressed entirely with
/// integer weights so the same table (and the same draw-by-modulo) produces
/// identical degrees across TS/Dart/Rust. Must stay in sync with
/// nodejs/src/lib/fountain.ts's buildDegreeTable.
///
/// - weight(1) = 1, weight(i) = floor(K / (i*(i-1))) for i = 2..K
///   (approximates the ideal soliton distribution rho(i); rho(2) dominates)
/// - a "tau" correction spreads extra weight across the low degrees
///   1..S-1 (S = floor(sqrt(K))) and adds a spike of weight S at degree S,
///   mirroring robust soliton's tau(i) term and mitigating the last-block
///   problem
/// - K <= 2: degree is always 1 (avoids degenerate tables for trivial transfers)
// Index-based loops (not iterators) are deliberate: this is a byte-for-byte
// port of nodejs/src/lib/fountain.ts's buildDegreeTable, and keeping the same
// loop shape makes it easy to diff against the TS/Dart source when verifying
// parity after a future change to any of the three.
#[allow(clippy::needless_range_loop)]
pub fn build_degree_table(k: u32) -> DegreeTable {
    if k <= 2 {
        return DegreeTable {
            cum_weights: vec![0, 1],
            total: 1,
        };
    }

    let k_usize = k as usize;
    let mut weights = vec![0u32; k_usize + 1];
    weights[1] = 1;
    for i in 2..=k_usize {
        // No max(1, ...) here: the ideal-soliton weight floors to 0 once
        // i*(i-1) > k (around i > sqrt(k)). Flooring those to 1 instead would
        // give every high degree weight 1 -- a huge uniform tail of enormous
        // degrees that, for a large file (K in the hundreds of thousands),
        // makes most symbols XOR tens of thousands of blocks (catastrophically
        // slow and undecodable). Letting them stay 0 caps the max degree near
        // sqrt(K).
        weights[i] = k / (i as u32 * (i as u32 - 1));
    }

    let s = (2usize).max((k as f64).sqrt().floor() as usize);
    for i in 1..s {
        weights[i] += (1u32).max(s as u32 / i as u32);
    }
    weights[s] += s as u32;

    let mut cum_weights = vec![0u32; k_usize + 1];
    let mut running: u32 = 0;
    for i in 1..=k_usize {
        running += weights[i];
        cum_weights[i] = running;
    }

    DegreeTable {
        cum_weights,
        total: running,
    }
}

/// Smallest degree d (>= 1) with cum_weights[d] > r. cum_weights is strictly
/// increasing, so binary search -- a linear scan here is O(K) per symbol,
/// which dominates encode/decode time for large files (K in the hundreds of
/// thousands).
fn pick_degree(r: u32, cum_weights: &[u32]) -> u32 {
    let mut lo = 1usize;
    let mut hi = cum_weights.len() - 1;
    while lo < hi {
        let mid = (lo + hi) / 2;
        if cum_weights[mid] > r {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    lo as u32
}

/// Derives the (degree, source-block indices) tuple for symbol `seq` over `k`
/// source blocks. Indices are 1-based and sorted ascending. Pass a
/// precomputed `table` (from `build_degree_table`) to avoid rebuilding it per
/// call.
pub fn sample_indices(seq: u32, k: u32, table: &DegreeTable) -> (u32, Vec<u32>) {
    let mut rng = make_rng(seq);

    let r = rng() % table.total;
    let degree = pick_degree(r, &table.cum_weights);

    let mut indices = std::collections::BTreeSet::new();
    while (indices.len() as u32) < degree && (indices.len() as u32) < k {
        let idx = (rng() % k) + 1;
        indices.insert(idx);
    }

    let sorted: Vec<u32> = indices.into_iter().collect();
    (sorted.len() as u32, sorted)
}

// ---------------------------------------------------------------------------
// Encoder: lazy fountain symbol generation.
// Direct port of nodejs/src/lib/fountain.ts's FountainChunker. TS uses a
// Proxy to synthesize each symbol on access rather than precomputing the
// whole N=3K pool up front (K can be hundreds of thousands of blocks). Rust
// gets the same laziness for free via `build_symbol`, called on demand from
// the renderer's draw loop -- no Proxy equivalent needed.
// ---------------------------------------------------------------------------

use crate::qrtypes::EccLevel;
use base64::Engine;

pub struct FountainLayoutOptions {
    pub buffer: i32,
    pub ecc_level: EccLevel,
}

pub struct FountainChunker {
    pub version: i32,
    pub block_size: usize,
    pub k: u32,
    pub chunk_id: String,
    pub checksum: String,
    /// Total frames = symbol_count symbols + 1 trailing checksum chunk.
    pub total_frames: u32,
    content: Vec<u8>,
    blocks: Vec<Vec<u8>>,
    table: DegreeTable,
    symbol_count: u32,
    file_size: usize,
}

impl FountainChunker {
    pub fn new(content: Vec<u8>) -> Self {
        use sha2::{Digest, Sha256};
        let digest = Sha256::digest(&content);
        let checksum = digest
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let chunk_id = crate::chunker::make_chunk_id(digest[0], digest[1]);
        FountainChunker {
            version: 1,
            block_size: 0,
            k: 0,
            chunk_id,
            checksum,
            total_frames: 0,
            content,
            blocks: Vec::new(),
            table: DegreeTable {
                cum_weights: vec![0, 1],
                total: 1,
            },
            symbol_count: 0,
            file_size: 0,
        }
    }

    /// Same version-selection heuristic as Chunker::calculate_layout, and
    /// the same N/K=3 redundancy factor chosen empirically in fountain.ts
    /// (comment there: smallest round redundancy factor that guarantees full
    /// peeling recovery from the complete pool, K=1..2000+, with margin for
    /// symbol loss during scanning).
    pub fn calculate_layout(&mut self, rows: i32, options: &FountainLayoutOptions) {
        // Header reserve for `F|seq|K|fileSize|id|` -- see fountain.ts's
        // FOUNTAIN_HEADER_RESERVE.
        const FOUNTAIN_HEADER_RESERVE: u32 = 32;

        let available_rows = rows - options.buffer;
        let max_ver = (available_rows * 2 - 17 - 4) / 4;
        self.version = max_ver.clamp(1, 40);

        let char_capacity = crate::constants::get_max_capacity(self.version, options.ecc_level);
        let working_capacity = char_capacity.saturating_sub(FOUNTAIN_HEADER_RESERVE);
        self.block_size = (working_capacity as f64 * 0.75).floor() as usize;
        if self.block_size == 0 {
            self.block_size = 16;
        }

        self.file_size = self.content.len();
        self.k = self.file_size.div_ceil(self.block_size).max(1) as u32;

        self.table = build_degree_table(self.k);

        self.blocks.clear();
        for i in 0..self.k as usize {
            let start = i * self.block_size;
            let end = (start + self.block_size).min(self.content.len());
            let mut block = vec![0u8; self.block_size];
            if start < self.content.len() {
                let slice = &self.content[start..end];
                block[..slice.len()].copy_from_slice(slice);
            }
            self.blocks.push(block);
        }

        self.symbol_count = (self.k + 20).max((self.k as f64 * 3.0).ceil() as u32);
        self.total_frames = self.symbol_count + 1;
    }

    /// Builds the `F|seq|K|fileSize|id|payload` string for one symbol.
    /// `total_frames - 1` (the last index) is the trailing checksum frame,
    /// handled by the caller.
    pub fn build_symbol(&self, seq: u32) -> String {
        let (_, indices) = sample_indices(seq, self.k, &self.table);
        let mut symbol = vec![0u8; self.block_size];
        for idx in indices {
            let block = &self.blocks[(idx - 1) as usize];
            for b in 0..self.block_size {
                symbol[b] ^= block[b];
            }
        }
        let payload = base64::engine::general_purpose::STANDARD.encode(&symbol);
        format!(
            "F|{seq}|{}|{}|{}|{payload}",
            self.k, self.file_size, self.chunk_id
        )
    }

    pub fn checksum_frame(&self) -> String {
        format!("CHECKSUM|T|{}|{}", self.chunk_id, self.checksum)
    }

    /// Frame at 0-based `index` across the full total_frames range -- the
    /// last index is the checksum frame, everything else is a symbol.
    pub fn frame(&self, index: u32) -> String {
        if index == self.symbol_count {
            self.checksum_frame()
        } else {
            self.build_symbol(index)
        }
    }
}

// ---------------------------------------------------------------------------
// Decoder: peeling with a capped GF(2) Gaussian-elimination fallback.
// Direct port of flutter/lib/services/fountain_decoder.dart (NOT
// nodejs/src/lib/fountain-decoder.ts -- the TS version has no cap on the
// elimination fallback, an O(K^2)/O(K^3) stall risk documented as a bug in
// docs/adr/0004-sender-language-rust.md's Open Questions; the Dart receiver's
// capped behavior is the correct reference here).
// ---------------------------------------------------------------------------

/// Above this many unresolved blocks, Gaussian elimination's O(N^2)/O(N^3)
/// cost is no longer worth attempting; rely on peeling alone. Matches Dart's
/// kDefaultMaxEliminationMissingCount.
pub const DEFAULT_MAX_ELIMINATION_MISSING_COUNT: u32 = 500;

/// A source block recovered by `add_symbol`, direct or cascaded. Current
/// callers (serve.rs) only care about `add_symbol`'s side effect on the
/// decoder's own recovered-block map, not this per-call list -- kept public
/// so a future caller wanting incremental recovery notifications (e.g. a
/// progress UI) doesn't need decoder internals exposed for it.
#[allow(dead_code)]
pub struct RecoveredBlock {
    pub index: u32,
    pub bytes: Vec<u8>,
}

struct PendingSymbol {
    xor: Vec<u8>,
    unresolved: std::collections::BTreeSet<u32>,
}

pub struct FountainDecoder {
    pub k: u32,
    pub block_size: usize,
    max_elimination_missing_count: u32,
    table: DegreeTable,
    recovered: std::collections::BTreeMap<u32, Vec<u8>>,
    seen_seqs: std::collections::HashSet<u32>,
    pending: Vec<PendingSymbol>,
}

impl FountainDecoder {
    pub fn new(k: u32, block_size: usize) -> Self {
        Self::with_max_elimination(k, block_size, DEFAULT_MAX_ELIMINATION_MISSING_COUNT)
    }

    pub fn with_max_elimination(
        k: u32,
        block_size: usize,
        max_elimination_missing_count: u32,
    ) -> Self {
        FountainDecoder {
            k,
            block_size,
            max_elimination_missing_count,
            table: build_degree_table(k),
            recovered: std::collections::BTreeMap::new(),
            seen_seqs: std::collections::HashSet::new(),
            pending: Vec::new(),
        }
    }

    pub fn recovered_count(&self) -> u32 {
        self.recovered.len() as u32
    }

    pub fn symbol_count(&self) -> u32 {
        self.seen_seqs.len() as u32
    }

    pub fn is_complete(&self) -> bool {
        self.recovered.len() as u32 == self.k
    }

    pub fn has_seq(&self, seq: u32) -> bool {
        self.seen_seqs.contains(&seq)
    }

    fn missing_count(&self) -> u32 {
        self.k - self.recovered.len() as u32
    }

    fn xor_into(dst: &mut [u8], src: &[u8]) {
        for (d, s) in dst.iter_mut().zip(src.iter()) {
            *d ^= s;
        }
    }

    /// Feeds one symbol into the decoder. Returns source blocks newly
    /// recovered as a direct or cascaded result (empty if duplicate, fully
    /// redundant, or merely queued for later).
    pub fn add_symbol(&mut self, seq: u32, bytes: &[u8]) -> Vec<RecoveredBlock> {
        let mut newly_recovered = Vec::new();
        if self.is_complete() || self.seen_seqs.contains(&seq) {
            return newly_recovered;
        }
        self.seen_seqs.insert(seq);

        let (_, indices) = sample_indices(seq, self.k, &self.table);

        let mut xor = vec![0u8; self.block_size];
        let n = self.block_size.min(bytes.len());
        xor[..n].copy_from_slice(&bytes[..n]);

        let mut unresolved = std::collections::BTreeSet::new();
        for idx in indices {
            if let Some(known) = self.recovered.get(&idx) {
                Self::xor_into(&mut xor, known);
            } else {
                unresolved.insert(idx);
            }
        }

        if unresolved.is_empty() {
            return newly_recovered; // fully redundant
        }

        if unresolved.len() == 1 {
            let only = *unresolved.iter().next().unwrap();
            self.recover_and_cascade(only, xor, &mut newly_recovered);
        } else {
            self.pending.push(PendingSymbol { xor, unresolved });
        }

        // Peeling can stall on a "stuck core" even when the data is fully
        // determined. Gate GE on pending >= missing so it stays off the fast
        // path, and cap it so large-K transfers can't hit an O(K^2)/O(K^3)
        // stall (see module doc).
        if !self.is_complete()
            && self.missing_count() < self.max_elimination_missing_count
            && self.pending.len() as u32 >= self.missing_count()
        {
            self.solve_residual_by_elimination(&mut newly_recovered);
        }

        newly_recovered
    }

    fn recover_and_cascade(&mut self, index: u32, bytes: Vec<u8>, out: &mut Vec<RecoveredBlock>) {
        let mut queue: Vec<(u32, Vec<u8>)> = vec![(index, bytes)];

        while let Some((idx, block_bytes)) = queue.pop() {
            if self.recovered.contains_key(&idx) {
                continue;
            }
            self.recovered.insert(idx, block_bytes.clone());
            out.push(RecoveredBlock {
                index: idx,
                bytes: block_bytes.clone(),
            });

            let mut i = self.pending.len();
            while i > 0 {
                i -= 1;
                let removed = self.pending[i].unresolved.remove(&idx);
                if !removed {
                    continue;
                }
                Self::xor_into(&mut self.pending[i].xor, &block_bytes);

                if self.pending[i].unresolved.is_empty() {
                    self.pending.remove(i);
                } else if self.pending[i].unresolved.len() == 1 {
                    let p = self.pending.remove(i);
                    let next_idx = *p.unresolved.iter().next().unwrap();
                    queue.push((next_idx, p.xor));
                }
            }
        }
    }

    fn xor_sets(
        a: &std::collections::BTreeSet<u32>,
        b: &std::collections::BTreeSet<u32>,
    ) -> std::collections::BTreeSet<u32> {
        let mut r = a.clone();
        for x in b {
            if !r.remove(x) {
                r.insert(*x);
            }
        }
        r
    }

    /// Solves the residual system of `pending` equations via Gaussian
    /// elimination over GF(2). On full rank, recovers every remaining block
    /// and clears `pending`; otherwise leaves state untouched.
    fn solve_residual_by_elimination(&mut self, out: &mut Vec<RecoveredBlock>) {
        let unknowns = self.missing_count();

        let mut pivots: std::collections::BTreeMap<
            u32,
            (Vec<u8>, std::collections::BTreeSet<u32>),
        > = std::collections::BTreeMap::new();

        for p in &self.pending {
            let mut coeffs = p.unresolved.clone();
            let mut bytes = p.xor.clone();

            loop {
                if coeffs.is_empty() {
                    break;
                }
                let pivot = *coeffs.iter().next().unwrap();
                match pivots.get(&pivot) {
                    None => {
                        pivots.insert(pivot, (bytes, coeffs));
                        break;
                    }
                    Some((existing_bytes, existing_unresolved)) => {
                        coeffs = Self::xor_sets(&coeffs, existing_unresolved);
                        Self::xor_into(&mut bytes, existing_bytes);
                    }
                }
            }
        }

        if (pivots.len() as u32) < unknowns {
            return; // not yet uniquely solvable
        }

        // Back-substitution: largest pivot index down, so higher-index
        // coefficients are already solved when reached.
        let mut solution: std::collections::BTreeMap<u32, Vec<u8>> =
            std::collections::BTreeMap::new();
        let pivot_indices_desc: Vec<u32> = pivots.keys().rev().copied().collect();
        for pivot in pivot_indices_desc {
            let (row_xor, row_unresolved) = &pivots[&pivot];
            let mut bytes = row_xor.clone();
            for c in row_unresolved {
                if *c == pivot {
                    continue;
                }
                if let Some(solved) = solution.get(c) {
                    Self::xor_into(&mut bytes, solved);
                }
            }
            solution.insert(pivot, bytes);
        }

        self.pending.clear();
        for (index, bytes) in solution {
            if self.recovered.contains_key(&index) {
                continue;
            }
            self.recovered.insert(index, bytes.clone());
            out.push(RecoveredBlock { index, bytes });
        }
    }

    /// Concatenates recovered blocks 1..k in order. Panics if incomplete;
    /// callers trim the result to the original file size themselves.
    pub fn assemble(&self) -> Vec<u8> {
        assert!(
            self.is_complete(),
            "cannot assemble: {} of {} blocks recovered",
            self.recovered_count(),
            self.k
        );
        let mut out = Vec::with_capacity(self.block_size * self.k as usize);
        for i in 1..=self.k {
            out.extend_from_slice(&self.recovered[&i]);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use serde::Deserialize;
    use sha2::{Digest, Sha256};
    use std::fs;
    use std::path::Path;

    #[derive(Deserialize)]
    struct Fixture {
        #[serde(rename = "inputBase64")]
        input_base64: String,
        k: u32,
        #[serde(rename = "blockSize")]
        block_size: usize,
        #[serde(rename = "fileSize")]
        file_size: usize,
        #[serde(rename = "chunkId")]
        chunk_id: String,
        chunks: Vec<String>,
    }

    /// Cross-language parity: regenerate every symbol in the existing
    /// `flutter/test/fixtures/fountain_sample.json` fixture (the same golden
    /// file the Dart decoder test already checks against) using this Rust
    /// port, and assert byte-for-byte equality against the fixture's
    /// TS-encoder-generated `chunks`. Proves zero PRNG/degree-table drift
    /// against the reference the receiver already trusts, not just internal
    /// self-consistency.
    #[test]
    fn matches_existing_cross_language_fixture() {
        let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../flutter/test/fixtures/fountain_sample.json");
        let raw = fs::read_to_string(&fixture_path)
            .unwrap_or_else(|e| panic!("failed to read {fixture_path:?}: {e}"));
        let fixture: Fixture = serde_json::from_str(&raw).expect("fixture is valid JSON");

        let content = base64::engine::general_purpose::STANDARD
            .decode(&fixture.input_base64)
            .expect("inputBase64 is valid base64");

        let k = fixture.k as usize;
        let block_size = fixture.block_size;
        let mut blocks: Vec<Vec<u8>> = Vec::with_capacity(k);
        for i in 0..k {
            let start = i * block_size;
            let end = (start + block_size).min(content.len());
            let mut block = vec![0u8; block_size];
            if start < content.len() {
                let slice = &content[start..end];
                block[..slice.len()].copy_from_slice(slice);
            }
            blocks.push(block);
        }

        let table = build_degree_table(fixture.k);
        let file_size = content.len();

        // The fixture's chunks are N symbols followed by one trailing
        // CHECKSUM line -- regenerate the symbols, then compare the checksum
        // line separately.
        let symbol_count = fixture.chunks.len() - 1;
        for seq in 0..symbol_count {
            let (_, indices) = sample_indices(seq as u32, fixture.k, &table);
            let mut symbol = vec![0u8; block_size];
            for idx in indices {
                let block = &blocks[(idx - 1) as usize];
                for b in 0..block_size {
                    symbol[b] ^= block[b];
                }
            }
            let payload = base64::engine::general_purpose::STANDARD.encode(&symbol);
            let expected = format!(
                "F|{}|{}|{}|{}|{}",
                seq, fixture.k, file_size, fixture.chunk_id, payload
            );
            assert_eq!(
                expected, fixture.chunks[seq],
                "symbol seq={seq} diverged from fixture"
            );
        }

        let digest = Sha256::digest(&content);
        let sha256_hex = digest
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let expected_checksum = format!("CHECKSUM|T|{}|{}", fixture.chunk_id, sha256_hex);
        assert_eq!(expected_checksum, fixture.chunks[symbol_count]);
    }

    /// Decoder-direction cross-language parity: feed the same fixture's
    /// `chunks` (TS-encoder-generated) into the ported FountainDecoder and
    /// confirm the recovered bytes match `inputBase64`. Mirrors
    /// flutter/test/services/fountain_decoder_test.dart's fixture-driven
    /// test -- proves the Rust decoder recovers what the Dart decoder
    /// already does, from the exact same wire bytes.
    #[test]
    fn decoder_recovers_fixture_input_from_fixture_chunks() {
        let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../flutter/test/fixtures/fountain_sample.json");
        let raw = fs::read_to_string(&fixture_path)
            .unwrap_or_else(|e| panic!("failed to read {fixture_path:?}: {e}"));
        let fixture: Fixture = serde_json::from_str(&raw).expect("fixture is valid JSON");

        let expected = base64::engine::general_purpose::STANDARD
            .decode(&fixture.input_base64)
            .expect("inputBase64 is valid base64");

        let mut decoder = FountainDecoder::new(fixture.k, fixture.block_size);

        for line in &fixture.chunks {
            if line.starts_with("CHECKSUM|") {
                continue;
            }
            // F|seq|K|fileSize|id|payload
            let parts: Vec<&str> = line.splitn(6, '|').collect();
            assert_eq!(parts.len(), 6, "malformed fixture line: {line}");
            let seq: u32 = parts[1].parse().expect("seq is a number");
            let payload = base64::engine::general_purpose::STANDARD
                .decode(parts[5])
                .expect("payload is valid base64");
            decoder.add_symbol(seq, &payload);
        }

        assert!(decoder.is_complete(), "decoder did not recover all blocks");
        let assembled = decoder.assemble();
        let trimmed = &assembled[..fixture.file_size.min(assembled.len())];
        assert_eq!(trimmed, expected.as_slice());
    }
}

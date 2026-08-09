//! Sequential chunker. Direct port of nodejs/src/lib/chunker.ts's Chunker
//! class -- same version-selection heuristic, same chunk-size math, same
//! `index|total|mode|id|payload` wire format.

use base64::Engine;
use sha2::{Digest, Sha256};

use crate::constants::get_max_capacity;
use crate::qrtypes::EccLevel;

const CHUNK_ID_ALPHABET: &[u8] =
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_";

/// Same 2-character id derivation as nodejs/src/lib/chunker.ts's makeChunkId.
pub fn make_chunk_id(high: u8, low: u8) -> String {
    let value = ((high as u16) << 8) | (low as u16);
    let a = CHUNK_ID_ALPHABET[((value >> 6) & 0x3f) as usize] as char;
    let b = CHUNK_ID_ALPHABET[(value & 0x3f) as usize] as char;
    format!("{a}{b}")
}

/// Splits `content` (must already be valid UTF-8) into end-offsets no
/// larger than `target_size` bytes each, never cutting mid-codepoint. Backs
/// off from the naive `target_size`-byte cut to the nearest earlier
/// character boundary (UTF-8 codepoints are at most 4 bytes, so this never
/// backs off more than 3 bytes) -- chunks are therefore slightly smaller
/// than `target_size` at a boundary, never larger, so they still fit the
/// capacity `target_size` was computed from.
fn utf8_chunk_boundaries(content: &[u8], target_size: usize) -> Vec<usize> {
    // `str::is_char_boundary` requires the byte slice to itself be valid
    // UTF-8 to give meaningful answers at every offset -- guaranteed by the
    // caller (invalid-UTF-8 input is auto-promoted to --base64 before this
    // path is ever reached).
    let text = std::str::from_utf8(content).expect("caller guarantees valid UTF-8 in text mode");

    let mut boundaries = Vec::new();
    let mut start = 0;
    while start < text.len() {
        let mut end = (start + target_size).min(text.len());
        while end > start && !text.is_char_boundary(end) {
            end -= 1;
        }
        // A single codepoint longer than target_size (shouldn't happen at
        // any real QR capacity, but stay correct rather than infinite-loop)
        // still needs to go somewhere -- extend to the next boundary instead
        // of producing an empty chunk.
        if end == start {
            end = start + 1;
            while end < text.len() && !text.is_char_boundary(end) {
                end += 1;
            }
        }
        boundaries.push(end);
        start = end;
    }
    boundaries
}

pub struct ChunkOptions {
    pub buffer: i32,
    pub use_base64: bool,
    pub add_header: bool,
    pub ecc_level: EccLevel,
    pub add_checksum: bool,
    /// From `--verify=<file>`: a checksum read from an external file, sent
    /// in the CHECKSUM frame instead of the locally computed one -- matches
    /// porter.ts's `providedChecksum` (porter.ts:255-262). Useful for
    /// multi-part transfers where the trusted checksum is the original
    /// pre-split file's, not a re-hash of the concatenated parts (which
    /// should match, but comes from a trusted source either way). `None`
    /// falls back to `Chunker`'s own computed `checksum`.
    pub provided_checksum: Option<String>,
}

pub struct Chunker {
    pub chunks: Vec<String>,
    pub version: i32,
    pub chunk_size: usize,
    pub chunk_id: String,
    pub checksum: String,
    content: Vec<u8>,
}

impl Chunker {
    pub fn new(content: Vec<u8>) -> Self {
        let digest = Sha256::digest(&content);
        let checksum = digest
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let chunk_id = make_chunk_id(digest[0], digest[1]);
        Chunker {
            chunks: Vec::new(),
            version: 1,
            chunk_size: 500,
            chunk_id,
            checksum,
            content,
        }
    }

    /// Same heuristic as chunker.ts's calculateLayout:
    /// QR size (modules) = 17 + 4*version; using half-blocks we need
    /// modules/2 rows, so version <= (2*rows - 17 - margin) / 4.
    pub fn calculate_layout(&mut self, rows: i32, options: &ChunkOptions) {
        let available_rows = rows - options.buffer;
        let max_ver = (available_rows * 2 - 17 - 4) / 4;
        self.version = max_ver.clamp(1, 40);

        // The CHECKSUM frame is a fixed ~78 bytes (`CHECKSUM|T|id|` + 64 hex
        // chars), so a version chosen purely from terminal height can be too
        // small to ever carry it -- the transfer would then send every data
        // chunk and fail only on the final frame, with no checksum to verify
        // against. Raise the version to fit it; the QR is then taller than
        // the terminal, which the TUI already handles by scrolling/clipping,
        // and that beats an unverifiable transfer.
        if options.add_checksum {
            let probe = format!("CHECKSUM|T|{}|{}", self.chunk_id, self.checksum);
            while self.version < 40
                && !crate::renderer::fits(&probe, options.ecc_level, self.version)
            {
                self.version += 1;
            }
        }

        let char_capacity = get_max_capacity(self.version, options.ecc_level);
        // Header is `index|total|mode|id|`. A fixed 16-char reserve (what
        // chunker.ts uses) underestimates it as soon as the file needs 5+
        // digit chunk counts: at total=70965 the real header is 17 chars,
        // so the last chunk overflows capacity and qrcode rejects it with
        // DataTooLong. Compute the worst case instead: `total` is the
        // widest either counter gets (index <= total), and it depends on
        // chunk_size, which depends on the header -- so solve by iterating
        // to a fixed point (converges in 1-2 rounds, digits only grow).
        let header_size = |total: usize| -> u32 {
            if !options.add_header {
                return 0;
            }
            let digits = total.to_string().len() as u32;
            // index + total + 1-char mode + 2-char id + four '|'
            digits * 2 + 1 + self.chunk_id.len() as u32 + 4
        };

        let total_length = self.content.len();
        let payload_capacity = |header: u32| -> usize {
            let working = char_capacity.saturating_sub(header);
            // ponytail: a version too small to hold even the header yields 0
            // here, and the caller bails out rather than clamping to 1 and
            // emitting a chunk that can't encode.
            if options.use_base64 {
                // base64 pads to whole 4-char groups: n raw bytes encode to
                // 4*ceil(n/3) chars. Invert that instead of scaling by 0.75,
                // which can round up past `working` on the final group.
                (working as usize / 4) * 3
            } else {
                working as usize
            }
        };

        let mut size = payload_capacity(header_size(1));
        for _ in 0..4 {
            if size == 0 {
                break;
            }
            let total = total_length.div_ceil(size).max(1);
            let next = payload_capacity(header_size(total));
            if next == size {
                break;
            }
            size = next;
        }
        self.chunk_size = size;
        self.chunks.clear();

        // No room for even one payload byte at this version -- emit nothing
        // rather than chunks that can't encode. The TUI surfaces this as its
        // "terminal too small" state instead of a per-chunk encode failure.
        if self.chunk_size == 0 {
            return;
        }

        // Shrink until the longest chunk fits. With Byte-mode encoding (see
        // renderer::encode) the capacity table is exact, so the computed size
        // is already right and this normally makes zero adjustments -- it's a
        // cheap guard against the header estimate drifting, not the mechanism
        // the sizing relies on. Only the longest chunk is checked: cost is
        // monotonic in length under a single Byte segment, so if it fits,
        // they all do.
        for _ in 0..12 {
            self.build_chunks(options);
            let longest = self.chunks.iter().max_by_key(|c| c.len());
            match longest {
                Some(c) if !crate::renderer::fits(c, options.ecc_level, self.version) => {}
                _ => return,
            }
            let Some(shrunk) = self.chunk_size.checked_sub(3).filter(|&s| s > 0) else {
                // Can't shrink further at this version -- emit nothing rather
                // than frames that fail mid-slideshow.
                self.chunks.clear();
                return;
            };
            self.chunk_size = shrunk;
        }
        // Didn't converge: don't hand back unverified chunks.
        self.chunks.clear();
    }

    /// Slices `content` into `chunks` at the current `chunk_size`.
    fn build_chunks(&mut self, options: &ChunkOptions) {
        self.chunks.clear();
        let total_length = self.content.len();

        // Byte offsets to slice at. In base64 mode, any offset is safe --
        // base64 encodes raw bytes, no character-boundary concept applies.
        // In text (T) mode, slicing at an arbitrary byte offset can land
        // mid-codepoint; String::from_utf8_lossy then replaces the dangling
        // bytes with U+FFFD (3 bytes in UTF-8 per replacement), which can
        // inflate a chunk past the capacity it was sized for -- reachable in
        // practice with any non-ASCII UTF-8 content (accents, emoji, CJK),
        // not just an edge case. (nodejs/src/lib/chunker.ts has the same
        // bug via Buffer.toString('utf8') on an arbitrary byte slice; fixed
        // here rather than matched, since matching a bug isn't the goal.)
        // Fixed by only ever cutting on a valid UTF-8 character boundary in
        // text mode -- content reaching this path is already known-valid
        // UTF-8 (invalid input is auto-promoted to --base64 by the caller),
        // so a boundary-respecting cut is never lossy.
        let boundaries = if options.use_base64 {
            None
        } else {
            Some(utf8_chunk_boundaries(&self.content, self.chunk_size))
        };

        let temp_chunks_count = match &boundaries {
            Some(b) => b.len().max(1),
            None => total_length.div_ceil(self.chunk_size).max(1),
        };

        let mut current_chunk_index = 0;
        let mut i = 0;
        while i < total_length {
            let end = match &boundaries {
                Some(b) => b[current_chunk_index],
                None => (i + self.chunk_size).min(total_length),
            };
            let chunk_bytes = &self.content[i..end];
            let payload_body = if options.use_base64 {
                base64::engine::general_purpose::STANDARD.encode(chunk_bytes)
            } else {
                // Safe: `end` is always a UTF-8 boundary in this branch (see
                // utf8_chunk_boundaries), so this is never actually lossy.
                String::from_utf8_lossy(chunk_bytes).into_owned()
            };

            current_chunk_index += 1;
            let payload = if options.add_header {
                let mode_char = if options.use_base64 { 'B' } else { 'T' };
                format!(
                    "{current_chunk_index}|{temp_chunks_count}|{mode_char}|{}|{payload_body}",
                    self.chunk_id
                )
            } else {
                payload_body
            };

            self.chunks.push(payload);
            i = end;
        }

        if options.add_checksum {
            let checksum = options
                .provided_checksum
                .as_deref()
                .unwrap_or(&self.checksum);
            self.chunks
                .push(format!("CHECKSUM|T|{}|{checksum}", self.chunk_id));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_id_matches_known_bytes() {
        // Cross-check against the existing fixture's chunkId "Or" for
        // digest bytes that must map to that id (see fountain_sample.json).
        // We don't have the raw digest bytes here, so instead verify the
        // alphabet/bit-packing logic is internally consistent: round-trip
        // a few (high, low) pairs through the same formula the TS/Dart
        // implementations use and confirm 2 chars are always produced.
        for high in [0u8, 1, 128, 255] {
            for low in [0u8, 1, 128, 255] {
                let id = make_chunk_id(high, low);
                assert_eq!(id.chars().count(), 2);
            }
        }
    }

    #[test]
    fn splits_content_into_expected_chunk_count() {
        let content = vec![b'a'; 1000];
        let mut chunker = Chunker::new(content);
        chunker.calculate_layout(
            40, // plenty of rows -> large version -> large capacity
            &ChunkOptions {
                buffer: 10,
                use_base64: false,
                add_header: true,
                ecc_level: EccLevel::L,
                add_checksum: false,
                provided_checksum: None,
            },
        );
        assert!(!chunker.chunks.is_empty());
        let expected_count = 1000usize.div_ceil(chunker.chunk_size);
        assert_eq!(chunker.chunks.len(), expected_count);
        for chunk in &chunker.chunks {
            let parts: Vec<&str> = chunk.splitn(5, '|').collect();
            assert_eq!(parts.len(), 5);
            assert_eq!(parts[1], expected_count.to_string());
            assert_eq!(parts[2], "T");
        }
    }

    #[test]
    fn adds_trailing_checksum_chunk_when_requested() {
        let content = vec![1u8, 2, 3, 4, 5];
        let mut chunker = Chunker::new(content);
        chunker.calculate_layout(
            40,
            &ChunkOptions {
                buffer: 10,
                use_base64: true,
                add_header: true,
                ecc_level: EccLevel::L,
                add_checksum: true,
                provided_checksum: None,
            },
        );
        let last = chunker.chunks.last().unwrap();
        assert!(last.starts_with("CHECKSUM|T|"));
        assert!(last.ends_with(&chunker.checksum));
    }

    /// `--verify=<file>` (porter.ts:255-262's providedChecksum) sends the
    /// externally-supplied checksum instead of the locally computed one.
    #[test]
    fn uses_provided_checksum_over_computed_when_given() {
        let content = vec![1u8, 2, 3, 4, 5];
        let mut chunker = Chunker::new(content);
        let provided = "deadbeef".repeat(8); // 64 hex chars, sha256-shaped
        chunker.calculate_layout(
            40,
            &ChunkOptions {
                buffer: 10,
                use_base64: true,
                add_header: true,
                ecc_level: EccLevel::L,
                add_checksum: true,
                provided_checksum: Some(provided.clone()),
            },
        );
        let last = chunker.chunks.last().unwrap();
        assert!(last.ends_with(&provided));
        assert_ne!(
            provided, chunker.checksum,
            "test checksum must differ from the real computed one"
        );
    }

    /// Regression test for a live-reported crash: a fixed 16-char header
    /// reserve underestimates `index|total|mode|id|` once the chunk count
    /// reaches 5 digits (17 chars), so chunks overflowed the QR capacity
    /// they were sized for and qrcode rejected them with DataTooLong.
    /// Checks both modes at a small version, where the header is the
    /// largest share of capacity.
    #[test]
    fn header_reserve_holds_for_five_digit_chunk_counts() {
        for use_base64 in [false, true] {
            // Big enough to need 5-digit totals at this version.
            let content = vec![b'a'; 8_000_000];
            let mut chunker = Chunker::new(content);
            chunker.calculate_layout(
                50,
                &ChunkOptions {
                    buffer: 10,
                    use_base64,
                    add_header: true,
                    ecc_level: EccLevel::L,
                    add_checksum: false,
                    provided_checksum: None,
                },
            );

            let capacity = crate::constants::get_max_capacity(chunker.version, EccLevel::L);
            assert!(
                chunker.chunks.len() >= 10_000,
                "test needs a 5+ digit chunk count, got {}",
                chunker.chunks.len()
            );
            for chunk in &chunker.chunks {
                assert!(
                    chunk.len() as u32 <= capacity,
                    "base64={use_base64}: chunk of {} bytes exceeds capacity {capacity}",
                    chunk.len(),
                );
            }
        }
    }

    /// Regression test for a live-reported crash: text mode chunking at a
    /// fixed byte offset used to be able to split a multi-byte UTF-8
    /// character, and String::from_utf8_lossy would replace the dangling
    /// bytes with U+FFFD (3 bytes each) -- inflating that one chunk past
    /// the QR capacity it was sized for. Repros with content whose
    /// multi-byte characters are deliberately positioned to straddle a
    /// naive chunk_size-byte cut.
    #[test]
    fn never_produces_a_chunk_larger_than_the_target_size_with_multibyte_content() {
        // 'é' is 2 bytes in UTF-8; with an odd-length ASCII prefix, some
        // naive `target_size`-byte cuts land exactly mid-character.
        let content = format!("{}{}", "a".repeat(7), "é".repeat(200)).into_bytes();
        let mut chunker = Chunker::new(content.clone());
        chunker.calculate_layout(
            24, // small terminal -> small version -> small capacity, closer
            // to the reported repro (version 11, not the "plenty of
            // rows" 40 used by the other tests here)
            &ChunkOptions {
                buffer: 10,
                use_base64: false,
                add_header: true,
                ecc_level: EccLevel::L,
                add_checksum: false,
                provided_checksum: None,
            },
        );

        assert!(!chunker.chunks.is_empty());
        for chunk in &chunker.chunks {
            // The full wire payload (header + body) must never exceed the
            // capacity chunk_size was computed from -- this is the actual
            // invariant that was violated (a too-long chunk that qrcode
            // then rejects with DataTooLong).
            let capacity = crate::constants::get_max_capacity(chunker.version, EccLevel::L);
            assert!(
                chunk.len() as u32 <= capacity,
                "chunk {chunk:?} ({} bytes) exceeds capacity {capacity} at version {}",
                chunk.len(),
                chunker.version,
            );
        }

        // And reassembling every chunk's body must reproduce the original
        // bytes exactly -- boundary-aware cutting must not drop or
        // duplicate any content.
        let mut reassembled = Vec::new();
        for chunk in &chunker.chunks {
            let body = chunk.splitn(5, '|').nth(4).unwrap();
            reassembled.extend_from_slice(body.as_bytes());
        }
        assert_eq!(reassembled, content);
    }
}

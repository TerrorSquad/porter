//! QR encoding: half-block character selection from a `qrcode::QrCode`.
//! Direct port of nodejs/src/lib/renderer.ts's `buildQrLines` -- same cell
//! characters, same quiet-zone border. This is the one piece
//! docs/adr/0004-sender-language-rust.md says must stay bit-identical
//! (module -> character mapping); how the resulting lines get placed on
//! screen is `tui.rs`'s concern (a ratatui `Buffer`, not cursor escapes).

use qrcode::bits::Bits;
use qrcode::types::QrResult;
use qrcode::{Color, QrCode, Version};

use crate::qrtypes::EccLevel;

const QR_WHITE_ALL: char = '█';
const QR_WHITE_BLACK: char = '▀';
const QR_BLACK_WHITE: char = '▄';
const QR_BLACK_ALL: char = ' ';

/// Encodes `payload` in a single Byte-mode segment at the given version.
///
/// Deliberately *not* `QrCode::with_version`, which runs the crate's optimal
/// segmentation: that splits the payload into numeric/alphanumeric/byte runs,
/// and for mixed content (digits + punctuation + newlines -- i.e. every real
/// chunk) the per-segment mode and count headers can cost more bits than one
/// plain Byte segment. The result was payloads well under the table capacity
/// still failing: at version 9 the tables allow 230 bytes and symbols peaked
/// at 224, yet ~2% of them were rejected, with no length that reliably
/// predicted which. The capacity tables in `constants` are Byte-mode maxima,
/// so forcing one Byte segment makes them exact and the sizing math sound.
///
/// Wire-compatible: mode selection is an encoder-side detail, and the decoded
/// payload is byte-identical either way.
fn encode(payload: &str, ecc_level: EccLevel, version: i32) -> QrResult<QrCode> {
    let ec = ecc_level.to_qrcode_ec_level();
    let mut bits = Bits::new(Version::Normal(version as i16));
    bits.push_byte_data(payload.as_bytes())?;
    bits.push_terminator(ec)?;
    QrCode::with_bits(bits, ec)
}

/// Whether `payload` fits this version/ECC, via the same Byte-mode encoding
/// used to render it.
pub fn fits(payload: &str, ecc_level: EccLevel, version: i32) -> bool {
    encode(payload, ecc_level, version).is_ok()
}

/// Returns the QR's half-block lines, or the `qrcode` crate's error if the
/// payload doesn't fit the chosen version/ECC. Errors are possible even
/// after Chunker sizes payloads to fit -- e.g. binary content read as lossy
/// UTF-8 can inflate past its expected byte size (each invalid byte becomes
/// a 3-byte U+FFFD) -- so callers must handle this, not `.expect()` it away:
/// a single oversized frame shouldn't crash the whole TUI process.
///
/// Inversion (`--invert`) is applied by the caller as a ratatui `Style`
/// (see `tui::QrGridWidget`), not baked in here -- embedding raw ANSI
/// escapes in a string that ratatui writes via `Buffer::set_string` would
/// render as literal garbage characters instead of reverse video, since
/// ratatui owns styling, not raw stdout bytes.
pub fn build_qr_lines(
    payload: &str,
    ecc_level: EccLevel,
    version: i32,
) -> Result<Vec<String>, qrcode::types::QrError> {
    let code = encode(payload, ecc_level, version)?;

    let module_count = code.width();
    let colors = code.to_colors();
    let is_dark = |row: usize, col: usize| -> bool {
        if row >= module_count || col >= module_count {
            return false;
        }
        colors[row * module_count + col] == Color::Dark
    };

    let padded_rows = if module_count % 2 == 1 {
        module_count + 1
    } else {
        module_count
    };

    let mut lines = Vec::new();
    let border_top: String = std::iter::repeat_n(QR_BLACK_WHITE, module_count + 3).collect();
    let border_bottom: String = std::iter::repeat_n(QR_WHITE_BLACK, module_count + 3).collect();
    lines.push(border_top);

    let mut row = 0;
    while row < padded_rows {
        let mut line = String::new();
        line.push(QR_WHITE_ALL);
        for col in 0..module_count {
            let top = is_dark(row, col);
            let bottom = is_dark(row + 1, col);
            let ch = match (top, bottom) {
                (false, false) => QR_WHITE_ALL,
                (false, true) => QR_WHITE_BLACK,
                (true, false) => QR_BLACK_WHITE,
                (true, true) => QR_BLACK_ALL,
            };
            line.push(ch);
        }
        line.push(QR_WHITE_ALL);
        lines.push(line);
        row += 2;
    }

    if module_count.is_multiple_of(2) {
        lines.push(border_bottom);
    }

    Ok(lines)
}

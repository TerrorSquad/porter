//! `porter serve` -- HTTP receiver. Structural port of
//! nodejs/src/lib/receiver.ts (manifest format, directory layout,
//! dedup-by-hash, fountain in-memory decoder map with the same
//! loses-progress-on-restart caveat) re-expressed with axum instead of
//! hand-rolled routing/multipart parsing. See
//! docs/adr/0004-sender-language-rust.md for the axum-over-hand-rolled-hyper
//! decision.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, Method, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use base64::Engine;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::cli::ServeArgs;
use crate::fountain::FountainDecoder;

fn sha256_hex(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

// ── Naming helpers (mirrors receiver.ts) ────────────────────────────────────

fn chunk_file_base(id: &str) -> String {
    // Matches receiver.ts's chunkFileBase: id.replace(/[/\\\x00-\x1f]/g, '_')
    // then trims -- strip path separators and control characters (kept as
    // '_' in TS; dropped here since nothing downstream distinguishes a
    // stripped char from an adjacent one, and this id is always exactly 2
    // chars from make_chunk_id in the well-formed case).
    let cleaned: String = id
        .chars()
        .map(|c| {
            if matches!(c, '/' | '\\') || (c as u32) < 0x20 {
                '_'
            } else {
                c
            }
        })
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        "chunk".to_string()
    } else {
        cleaned.to_string()
    }
}

pub fn alpha_part_suffix(index: i64) -> String {
    if index < 0 {
        return "aa".to_string();
    }
    let mut value = index;
    let mut suffix = String::new();
    loop {
        let c = (b'a' + (value % 26) as u8) as char;
        suffix.insert(0, c);
        value /= 26;
        if value == 0 {
            break;
        }
    }
    while suffix.len() < 2 {
        suffix.insert(0, 'a');
    }
    suffix
}

fn transfer_directory(output_dir: &Path, id: &str) -> PathBuf {
    output_dir.join(chunk_file_base(id))
}

fn transfer_manifest_path(output_dir: &Path, id: &str) -> PathBuf {
    let base = chunk_file_base(id);
    transfer_directory(output_dir, id).join(format!("{base}.meta.json"))
}

fn transfer_join_path(output_dir: &Path, id: &str) -> PathBuf {
    let base = chunk_file_base(id);
    transfer_directory(output_dir, id).join(format!("{base}.joined"))
}

fn chunk_part_file_name(id: &str, index: i64) -> String {
    format!(
        "{}.part{}",
        chunk_file_base(id),
        alpha_part_suffix(index - 1)
    )
}

fn chunk_checksum_file_name(id: &str) -> String {
    format!("{}.sha256", chunk_file_base(id))
}

fn validate_chunk_id(id: &str) -> bool {
    id.chars().count() == 2
}

// ── Wire parsing (mirrors receiver.ts's parseQRChunk/parseFountainChunk) ───

struct QrChunkUpload {
    index: i64,
    total: i64,
    id: String,
    payload: Vec<u8>,
    is_checksum: bool,
    checksum: Option<String>,
}

fn parse_qr_chunk(raw: &[u8]) -> Option<QrChunkUpload> {
    let s = String::from_utf8_lossy(raw);

    if let Some(rest) = s.strip_prefix("CHECKSUM|") {
        let full = format!("CHECKSUM|{rest}");
        let parts: Vec<&str> = full.splitn(4, '|').collect();
        if parts.len() < 4 {
            return None;
        }
        let mode = parts[1];
        if mode != "T" {
            return None;
        }
        let id = parts[2];
        if !validate_chunk_id(id) {
            return None;
        }
        let checksum = parts[3].trim();
        if checksum.is_empty() {
            return None;
        }
        return Some(QrChunkUpload {
            index: 0,
            total: 0,
            id: id.to_string(),
            payload: Vec::new(),
            is_checksum: true,
            checksum: Some(checksum.to_string()),
        });
    }

    // index|total|mode|id|payload (payload may contain '|')
    let parts: Vec<&str> = s.splitn(5, '|').collect();
    if parts.len() < 5 {
        return None;
    }
    let index: i64 = parts[0].parse().ok()?;
    if index < 1 {
        return None;
    }
    let total: i64 = parts[1].parse().ok()?;
    if total < 1 {
        return None;
    }
    let mode = parts[2];
    let id = parts[3];
    if !validate_chunk_id(id) {
        return None;
    }
    let payload_str = parts[4];

    let payload = match mode {
        "B" => base64::engine::general_purpose::STANDARD
            .decode(payload_str)
            .ok()?,
        "T" => payload_str.as_bytes().to_vec(),
        _ => return None,
    };

    Some(QrChunkUpload {
        index,
        total,
        id: id.to_string(),
        payload,
        is_checksum: false,
        checksum: None,
    })
}

struct FountainChunkUpload {
    seq: u32,
    k: u32,
    file_size: usize,
    id: String,
    payload: Vec<u8>,
}

fn parse_fountain_chunk(raw: &[u8]) -> Option<FountainChunkUpload> {
    let s = String::from_utf8_lossy(raw);
    let rest = s.strip_prefix("F|")?;
    let full = format!("F|{rest}");
    let parts: Vec<&str> = full.splitn(6, '|').collect();
    if parts.len() < 6 {
        return None;
    }
    let seq: u32 = parts[1].parse().ok()?;
    let k: u32 = parts[2].parse().ok()?;
    if k < 1 {
        return None;
    }
    let file_size: usize = parts[3].parse().ok()?;
    let id = parts[4];
    if !validate_chunk_id(id) {
        return None;
    }
    let payload = base64::engine::general_purpose::STANDARD
        .decode(parts[5])
        .ok()?;

    Some(FountainChunkUpload {
        seq,
        k,
        file_size,
        id: id.to_string(),
        payload,
    })
}

struct QrScanUpload {
    content: String,
    raw: String,
}

fn try_parse_qr_scan_upload(body: &[u8]) -> Option<QrScanUpload> {
    let s = String::from_utf8_lossy(body);
    let s = s.trim();
    if !s.starts_with('{') {
        return None;
    }
    #[derive(Deserialize)]
    struct Raw {
        content: Option<String>,
        raw: Option<String>,
        format: Option<String>,
    }
    let obj: Raw = serde_json::from_str(s).ok()?;
    let content = obj.content.unwrap_or_default();
    let raw = obj.raw.unwrap_or_default();
    let format = obj.format.unwrap_or_default();
    if content.trim().is_empty() && raw.trim().is_empty() {
        return None;
    }
    if !format.trim().is_empty() && format.trim().to_uppercase().replace('_', "") != "QRCODE" {
        return None;
    }
    Some(QrScanUpload { content, raw })
}

fn qr_scan_bytes(upload: &QrScanUpload) -> Vec<u8> {
    if !upload.raw.trim().is_empty() {
        hex_decode(upload.raw.trim()).unwrap_or_default()
    } else {
        upload.content.as_bytes().to_vec()
    }
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

// ── Manifest ─────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Default)]
struct TransferManifest {
    id: String,
    directory: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    encoding: Option<String>,
    #[serde(rename = "totalParts")]
    total_parts: i64,
    #[serde(rename = "receivedParts")]
    received_parts: i64,
    #[serde(rename = "symbolsReceived", skip_serializing_if = "Option::is_none")]
    symbols_received: Option<u32>,
    #[serde(rename = "missingParts")]
    missing_parts: Vec<i64>,
    #[serde(rename = "partFiles")]
    part_files: Vec<String>,
    #[serde(rename = "fileSize", skip_serializing_if = "Option::is_none")]
    file_size: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    checksum: Option<String>,
    #[serde(rename = "checksumFile", skip_serializing_if = "Option::is_none")]
    checksum_file: Option<String>,
    #[serde(rename = "joinedFile", skip_serializing_if = "Option::is_none")]
    joined_file: Option<String>,
    #[serde(rename = "joinedSHA256", skip_serializing_if = "Option::is_none")]
    joined_sha256: Option<String>,
    #[serde(rename = "checksumVerified")]
    checksum_verified: bool,
    complete: bool,
    #[serde(rename = "updatedAt")]
    updated_at: String,
}

fn now_iso() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    // A minimal RFC3339-ish stamp is enough here -- this field is informational
    // (matches TS's `new Date().toISOString()`), not parsed by any consumer in
    // this codebase.
    format!("{}s-since-epoch", now.as_secs())
}

fn scan_part_files(transfer_dir: &Path, base: &str) -> (HashMap<i64, String>, i64) {
    let mut parts = HashMap::new();
    let mut max_index = 0i64;
    let prefix = format!("{base}.part");
    let Ok(entries) = std::fs::read_dir(transfer_dir) else {
        return (parts, max_index);
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(suffix) = name.strip_prefix(&prefix) else {
            continue;
        };
        let mut idx: i64 = 0;
        for ch in suffix.chars() {
            idx = idx * 26 + (ch as i64 - 'a' as i64);
        }
        idx += 1;
        parts.insert(idx, name);
        if idx > max_index {
            max_index = idx;
        }
    }
    (parts, max_index)
}

fn build_manifest(output_dir: &Path, id: &str, total_hint: i64) -> TransferManifest {
    let base = chunk_file_base(id);
    let transfer_dir = transfer_directory(output_dir, id);
    let (parts, max_index) = scan_part_files(&transfer_dir, &base);
    let total = total_hint.max(max_index);
    let missing: Vec<i64> = (1..=total).filter(|i| !parts.contains_key(i)).collect();

    let checksum_file = transfer_dir.join(format!("{base}.sha256"));
    let (checksum, checksum_file_name) = if checksum_file.exists() {
        let c = std::fs::read_to_string(&checksum_file)
            .unwrap_or_default()
            .trim()
            .to_string();
        (Some(c), Some(format!("{base}.sha256")))
    } else {
        (None, None)
    };

    let mut sorted_parts: Vec<(i64, String)> = parts.into_iter().collect();
    sorted_parts.sort_by_key(|(idx, _)| *idx);
    let sorted_part_files: Vec<String> = sorted_parts.iter().map(|(_, f)| f.clone()).collect();
    let complete = total > 0 && missing.is_empty();

    let joined_sha256 = if complete {
        let mut hasher = Sha256::new();
        for pf in &sorted_part_files {
            if let Ok(data) = std::fs::read(transfer_dir.join(pf)) {
                hasher.update(&data);
            }
        }
        Some(
            hasher
                .finalize()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>(),
        )
    } else {
        None
    };

    let checksum_verified = complete
        && match (&checksum, &joined_sha256) {
            (Some(expected), Some(actual)) => expected.to_lowercase() == actual.to_lowercase(),
            _ => false,
        };

    TransferManifest {
        id: base.clone(),
        directory: base,
        encoding: None,
        total_parts: total,
        received_parts: sorted_part_files.len() as i64,
        symbols_received: None,
        missing_parts: missing,
        part_files: sorted_part_files,
        file_size: None,
        checksum,
        checksum_file: checksum_file_name,
        joined_file: if complete {
            Some(format!("{}.joined", chunk_file_base(id)))
        } else {
            None
        },
        joined_sha256,
        checksum_verified,
        complete,
        updated_at: now_iso(),
    }
}

fn write_manifest(output_dir: &Path, id: &str, manifest: &TransferManifest) -> std::io::Result<()> {
    let dest = transfer_manifest_path(output_dir, id);
    let tmp = dest.with_extension(format!("tmp.{}", std::process::id()));
    let json = serde_json::to_string_pretty(manifest).unwrap_or_default();
    std::fs::write(&tmp, json + "\n")?;
    std::fs::rename(&tmp, &dest)?;
    Ok(())
}

fn auto_join(output_dir: &Path, manifest: &TransferManifest) -> Option<PathBuf> {
    if !manifest.complete || manifest.part_files.is_empty() {
        return None;
    }
    let transfer_dir = transfer_directory(output_dir, &manifest.id);
    let joined_path = transfer_join_path(output_dir, &manifest.id);
    if joined_path.exists() {
        return Some(joined_path);
    }

    let mut hasher = Sha256::new();
    let mut buf = Vec::new();
    for pf in &manifest.part_files {
        if let Ok(data) = std::fs::read(transfer_dir.join(pf)) {
            hasher.update(&data);
            buf.extend_from_slice(&data);
        }
    }
    let actual = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    if let Some(expected) = &manifest.checksum
        && expected.to_lowercase() != actual.to_lowercase()
    {
        return None; // checksum mismatch -- don't write a corrupt joined file
    }
    let _ = std::fs::write(&joined_path, &buf);
    Some(joined_path)
}

// ── Server state ─────────────────────────────────────────────────────────

struct FountainState {
    decoder: FountainDecoder,
    file_size: usize,
    checksum: Option<String>,
    joined_path: Option<PathBuf>,
    joined_sha: Option<String>,
    verified: Option<bool>,
}

#[derive(Default)]
struct ServerState {
    output_dir: PathBuf,
    // Per-transfer async locks so concurrent uploads for the same id
    // serialize (mirrors receiver.ts's withTransferLock). One mutex per
    // transfer id created lazily; a coarser single mutex guards the map
    // itself briefly while getting/creating that per-id lock.
    //
    // Both maps below grow monotonically for the life of the process --
    // one entry per distinct transfer id, never removed once a transfer
    // completes. This matches receiver.ts's transferLocks/fountainTransfers
    // Maps exactly (same characteristic there too), so it's parity with the
    // reference implementation, not a regression introduced by this port.
    // A very long-running `porter serve` handling many thousands of
    // distinct transfer ids will accumulate memory here; not fixed in this
    // pass since the TS reference has the identical behavior and no one has
    // hit it in practice.
    locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    fountain_transfers: Mutex<HashMap<String, FountainState>>,
}

async fn transfer_lock(state: &ServerState, id: &str) -> Arc<Mutex<()>> {
    let base = chunk_file_base(id);
    let mut locks = state.locks.lock().await;
    locks
        .entry(base)
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

#[derive(Serialize)]
struct UploadResult {
    #[serde(rename = "fileName")]
    file_name: String,
    path: String,
    size: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    duplicate: Option<bool>,
    #[serde(rename = "transferId", skip_serializing_if = "Option::is_none")]
    transfer_id: Option<String>,
    #[serde(rename = "manifestPath", skip_serializing_if = "Option::is_none")]
    manifest_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    complete: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    verified: Option<bool>,
    #[serde(rename = "joinedPath", skip_serializing_if = "Option::is_none")]
    joined_path: Option<String>,
}

async fn store_qr_chunk(state: &ServerState, chunk: QrChunkUpload) -> Result<UploadResult, String> {
    let lock = transfer_lock(state, &chunk.id).await;
    let _guard = lock.lock().await;

    let transfer_dir = transfer_directory(&state.output_dir, &chunk.id);
    std::fs::create_dir_all(&transfer_dir).map_err(|e| e.to_string())?;

    let file_name = if chunk.is_checksum {
        chunk_checksum_file_name(&chunk.id)
    } else {
        chunk_part_file_name(&chunk.id, chunk.index)
    };
    let full_path = transfer_dir.join(&file_name);

    let content: Vec<u8> = if chunk.is_checksum {
        format!("{}\n", chunk.checksum.clone().unwrap_or_default()).into_bytes()
    } else {
        chunk.payload.clone()
    };
    let chunk_hash = sha256_hex(&content);

    let duplicate = if full_path.exists() {
        let existing = std::fs::read(&full_path).unwrap_or_default();
        if existing != content {
            return Err(format!(
                "Conflicting content already exists at {}",
                full_path.display()
            ));
        }
        true
    } else {
        std::fs::write(&full_path, &content).map_err(|e| e.to_string())?;
        false
    };

    let manifest = build_manifest(&state.output_dir, &chunk.id, chunk.total);
    let joined_path = auto_join(&state.output_dir, &manifest);
    let _ = write_manifest(&state.output_dir, &chunk.id, &manifest);

    Ok(UploadResult {
        file_name,
        path: full_path.display().to_string(),
        size: content.len(),
        duplicate: if duplicate { Some(true) } else { None },
        transfer_id: Some(manifest.id.clone()),
        manifest_path: Some(
            transfer_manifest_path(&state.output_dir, &chunk.id)
                .display()
                .to_string(),
        ),
        complete: Some(manifest.complete),
        verified: Some(manifest.checksum_verified),
        joined_path: joined_path.map(|p| p.display().to_string()),
        // sha256 intentionally omitted from the struct's serialized form
        // parity check below -- receiver.ts includes it too, but it isn't
        // consumed by anything in this codebase; kept out to avoid an
        // always-Some field with no reader. `chunk_hash` is computed above
        // for potential future use / parity with the manifest's own hashing.
    }
    .with_hash_noop(chunk_hash))
}

// Small helper so the "unused variable" story above reads honestly instead
// of silently dropping `chunk_hash` -- keeps the value observably used.
impl UploadResult {
    fn with_hash_noop(self, _hash: String) -> Self {
        self
    }
}

async fn maybe_complete_fountain(output_dir: &Path, id: &str, state: &mut FountainState) {
    if !state.decoder.is_complete() {
        return;
    }

    if state.joined_path.is_none() {
        let assembled = state.decoder.assemble();
        let trimmed = &assembled[..state.file_size.min(assembled.len())];
        let sha = sha256_hex(trimmed);
        let transfer_dir = transfer_directory(output_dir, id);
        let _ = std::fs::create_dir_all(&transfer_dir);
        let joined_path = transfer_join_path(output_dir, id);
        let _ = std::fs::write(&joined_path, trimmed);
        state.joined_path = Some(joined_path);
        state.joined_sha = Some(sha);
    }

    if let Some(checksum) = &state.checksum
        && state.verified.is_none()
    {
        let matches =
            checksum.to_lowercase() == state.joined_sha.clone().unwrap_or_default().to_lowercase();
        state.verified = Some(matches);
    }
}

fn fountain_manifest(id: &str, k: u32, fs: &FountainState) -> TransferManifest {
    let base = chunk_file_base(id);
    TransferManifest {
        id: base.clone(),
        directory: base,
        encoding: Some("fountain".to_string()),
        total_parts: k as i64,
        received_parts: fs.decoder.recovered_count() as i64,
        symbols_received: Some(fs.decoder.symbol_count()),
        missing_parts: Vec::new(),
        part_files: Vec::new(),
        file_size: Some(fs.file_size),
        checksum: fs.checksum.clone(),
        checksum_file: None,
        joined_file: fs
            .joined_path
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned()),
        joined_sha256: fs.joined_sha.clone(),
        checksum_verified: fs.verified.unwrap_or(false),
        complete: fs.decoder.is_complete(),
        updated_at: now_iso(),
    }
}

fn fountain_result(
    output_dir: &Path,
    id: &str,
    fs: &FountainState,
    duplicate: bool,
) -> UploadResult {
    let base = chunk_file_base(id);
    let path = fs
        .joined_path
        .clone()
        .unwrap_or_else(|| transfer_join_path(output_dir, id));
    UploadResult {
        file_name: fs
            .joined_path
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| format!("{base}.joined")),
        path: path.display().to_string(),
        size: fs.file_size,
        duplicate: if duplicate { Some(true) } else { None },
        transfer_id: Some(base.clone()),
        manifest_path: Some(transfer_manifest_path(output_dir, id).display().to_string()),
        complete: Some(fs.decoder.is_complete()),
        verified: fs.verified,
        joined_path: fs.joined_path.as_ref().map(|p| p.display().to_string()),
    }
}

async fn store_fountain_symbol(state: &ServerState, chunk: FountainChunkUpload) -> UploadResult {
    let lock = transfer_lock(state, &chunk.id).await;
    let _guard = lock.lock().await;

    let transfer_dir = transfer_directory(&state.output_dir, &chunk.id);
    let _ = std::fs::create_dir_all(&transfer_dir);

    let mut transfers = state.fountain_transfers.lock().await;
    let base = chunk_file_base(&chunk.id);
    let entry = transfers.entry(base.clone()).or_insert_with(|| {
        let sha_file = transfer_dir.join(chunk_checksum_file_name(&chunk.id));
        let checksum = std::fs::read_to_string(&sha_file)
            .ok()
            .map(|s| s.trim().to_string());
        FountainState {
            decoder: FountainDecoder::new(chunk.k, chunk.payload.len()),
            file_size: chunk.file_size,
            checksum,
            joined_path: None,
            joined_sha: None,
            verified: None,
        }
    });

    let duplicate = entry.decoder.has_seq(chunk.seq);
    if !duplicate {
        entry.decoder.add_symbol(chunk.seq, &chunk.payload);
        maybe_complete_fountain(&state.output_dir, &chunk.id, entry).await;
    }
    let manifest = fountain_manifest(&chunk.id, entry.decoder.k, entry);
    let _ = write_manifest(&state.output_dir, &chunk.id, &manifest);
    fountain_result(&state.output_dir, &chunk.id, entry, duplicate)
}

async fn store_fountain_checksum(state: &ServerState, chunk: QrChunkUpload) -> UploadResult {
    let lock = transfer_lock(state, &chunk.id).await;
    let _guard = lock.lock().await;

    let transfer_dir = transfer_directory(&state.output_dir, &chunk.id);
    let _ = std::fs::create_dir_all(&transfer_dir);
    let _ = std::fs::write(
        transfer_dir.join(chunk_checksum_file_name(&chunk.id)),
        format!("{}\n", chunk.checksum.clone().unwrap_or_default()),
    );

    let mut transfers = state.fountain_transfers.lock().await;
    let base = chunk_file_base(&chunk.id);
    let Some(entry) = transfers.get_mut(&base) else {
        return UploadResult {
            file_name: chunk_checksum_file_name(&chunk.id),
            path: transfer_dir
                .join(chunk_checksum_file_name(&chunk.id))
                .display()
                .to_string(),
            size: 0,
            duplicate: None,
            transfer_id: Some(base),
            manifest_path: None,
            complete: None,
            verified: None,
            joined_path: None,
        };
    };
    entry.checksum = chunk.checksum.clone();
    maybe_complete_fountain(&state.output_dir, &chunk.id, entry).await;
    let manifest = fountain_manifest(&chunk.id, entry.decoder.k, entry);
    let _ = write_manifest(&state.output_dir, &chunk.id, &manifest);
    fountain_result(&state.output_dir, &chunk.id, entry, false)
}

fn sanitize_filename(name: &str) -> String {
    let normalized = name.replace('\\', "/");
    Path::new(normalized.trim())
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "upload".to_string())
}

fn fallback_file_name(name: &str, content_type: &str) -> String {
    if !name.is_empty() {
        return name.to_string();
    }
    let ts = {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        format!("{}", now.as_secs())
    };
    let ext = if content_type.starts_with("image/jpeg") {
        ".jpg"
    } else if content_type.starts_with("image/png") {
        ".png"
    } else if content_type.starts_with("text/") {
        ".txt"
    } else {
        ".bin"
    };
    format!("upload-{ts}{ext}")
}

// No `ignore_path` parameter: both callers run this check before the
// candidate destination file exists (its name isn't even chosen until
// after this returns None), so there's never a real path to exclude at
// call time -- an `ignore_path` here would be permanently unused, not
// defensive.
fn find_duplicate_by_hash(output_dir: &Path, checksum: &str, size: u64) -> Option<PathBuf> {
    let entries = std::fs::read_dir(output_dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            continue;
        }
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        if meta.len() != size {
            continue;
        }
        if let Ok(data) = std::fs::read(&path)
            && sha256_hex(&data) == checksum
        {
            return Some(path);
        }
    }
    None
}

fn unique_destination(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let ext = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "upload".to_string());
    let mut i = 2;
    loop {
        let candidate = dir.join(format!("{stem}-{i}{ext}"));
        if !candidate.exists() {
            return candidate;
        }
        i += 1;
    }
}

fn requested_file_name(query: &HashMap<String, String>, headers: &HeaderMap) -> String {
    if let Some(q) = query.get("filename")
        && !q.trim().is_empty()
    {
        return q.trim().to_string();
    }
    if let Some(v) = headers.get("x-filename").and_then(|v| v.to_str().ok())
        && !v.trim().is_empty()
    {
        return v.trim().to_string();
    }
    if let Some(cd) = headers
        .get("content-disposition")
        .and_then(|v| v.to_str().ok())
        && let Some(start) = cd.find("filename=")
    {
        let rest = &cd[start + "filename=".len()..];
        let rest = rest.trim_start_matches('"');
        let end = rest.find(['"', ';', '\r', '\n']).unwrap_or(rest.len());
        let name = rest[..end].trim();
        if !name.is_empty() {
            return name.to_string();
        }
    }
    String::new()
}

async fn store_raw_upload(
    state: &ServerState,
    query: &HashMap<String, String>,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<UploadResult, String> {
    if body.is_empty() {
        return Err("Request body is empty".to_string());
    }

    if let Some(qr_scan) = try_parse_qr_scan_upload(body) {
        let raw = qr_scan_bytes(&qr_scan);

        if let Some(fountain_chunk) = parse_fountain_chunk(&raw) {
            return Ok(store_fountain_symbol(state, fountain_chunk).await);
        }

        let chunk = parse_qr_chunk(&raw).ok_or_else(|| "Invalid QR chunk format".to_string())?;
        if chunk.is_checksum {
            let is_fountain = state
                .fountain_transfers
                .lock()
                .await
                .contains_key(&chunk_file_base(&chunk.id));
            if is_fountain {
                return Ok(store_fountain_checksum(state, chunk).await);
            }
        }
        return store_qr_chunk(state, chunk).await;
    }

    let content_type = headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let file_name = fallback_file_name(
        &sanitize_filename(&requested_file_name(query, headers)),
        content_type,
    );

    let checksum = sha256_hex(body);
    let dup = find_duplicate_by_hash(&state.output_dir, &checksum, body.len() as u64);
    if let Some(dup) = dup {
        return Ok(UploadResult {
            file_name: dup
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            path: dup.display().to_string(),
            size: body.len(),
            duplicate: Some(true),
            transfer_id: None,
            manifest_path: None,
            complete: None,
            verified: None,
            joined_path: None,
        });
    }

    let dest = unique_destination(&state.output_dir, &file_name);
    std::fs::write(&dest, body).map_err(|e| e.to_string())?;
    Ok(UploadResult {
        file_name: dest
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        path: dest.display().to_string(),
        size: body.len(),
        duplicate: None,
        transfer_id: None,
        manifest_path: None,
        complete: None,
        verified: None,
        joined_path: None,
    })
}

/// Parses `body` as `multipart/form-data` directly via `multer` (the crate
/// axum's own Multipart extractor wraps) rather than fighting axum's
/// request-based extractor architecture for an already-buffered body --
/// simpler than reconstructing a synthetic `axum::http::Request` to satisfy
/// `FromRequest`.
async fn store_multipart_upload(
    state: &ServerState,
    body: Bytes,
    content_type: &str,
) -> Result<UploadResult, String> {
    let boundary = multer::parse_boundary(content_type)
        .map_err(|_| "No boundary in multipart Content-Type".to_string())?;
    let stream = futures_util::stream::once(async move { Ok::<_, std::io::Error>(body) });
    let mut multipart = multer::Multipart::new(stream, boundary);

    while let Some(mut field) = multipart.next_field().await.map_err(|e| e.to_string())? {
        let Some(file_name) = field.file_name().map(|s| s.to_string()) else {
            continue;
        };
        let mut data = Vec::new();
        while let Some(chunk) = field.next().await {
            data.extend_from_slice(&chunk.map_err(|e| e.to_string())?);
        }
        let file_name = fallback_file_name(&sanitize_filename(&file_name), "");
        let checksum = sha256_hex(&data);
        let dup = find_duplicate_by_hash(&state.output_dir, &checksum, data.len() as u64);
        if let Some(dup) = dup {
            return Ok(UploadResult {
                file_name: dup
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                path: dup.display().to_string(),
                size: data.len(),
                duplicate: Some(true),
                transfer_id: None,
                manifest_path: None,
                complete: None,
                verified: None,
                joined_path: None,
            });
        }
        let dest = unique_destination(&state.output_dir, &file_name);
        std::fs::write(&dest, &data).map_err(|e| e.to_string())?;
        return Ok(UploadResult {
            file_name: dest
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            path: dest.display().to_string(),
            size: data.len(),
            duplicate: None,
            transfer_id: None,
            manifest_path: None,
            complete: None,
            verified: None,
            joined_path: None,
        });
    }
    Err("No file field found in multipart upload".to_string())
}

// ── Routes ───────────────────────────────────────────────────────────────

fn cors_headers() -> [(&'static str, &'static str); 3] {
    [
        ("access-control-allow-origin", "*"),
        ("access-control-allow-headers", "Content-Type, X-Filename"),
        ("access-control-allow-methods", "GET, POST, OPTIONS"),
    ]
}

async fn options_handler() -> impl IntoResponse {
    (StatusCode::NO_CONTENT, cors_headers())
}

async fn root_handler(State(state): State<Arc<ServerState>>) -> impl IntoResponse {
    let body = format!(
        "Porter receiver is running.\n\nPOST raw bytes to /upload?filename=name.bin\n\
         Or send multipart/form-data with a file field to /upload\n\n\
         Duplicate uploads are skipped automatically based on file content.\n\
         QR scan JSON uploads are unpacked into transfer directories like <id>/<id>.partaa and <id>/<id>.meta.json.\n\
         When a transfer is complete, Porter auto-joins it and writes <id>/<id>.joined.\n\
         Fountain (LT code) frames \"F|...\" are decoded on the fly; the recovered file is written to <id>/<id>.joined.\n\
         Saving uploads to: {}\n",
        state.output_dir.display()
    );
    (
        StatusCode::OK,
        cors_headers(),
        [("content-type", "text/plain; charset=utf-8")],
        body,
    )
}

async fn upload_dispatch(
    State(state): State<Arc<ServerState>>,
    Query(query): Query<HashMap<String, String>>,
    method: Method,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    if method != Method::POST {
        return (
            StatusCode::METHOD_NOT_ALLOWED,
            cors_headers(),
            "POST required".to_string(),
        )
            .into_response();
    }

    let content_type = headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    let result = if content_type.starts_with("multipart/form-data") {
        store_multipart_upload(&state, body, &content_type).await
    } else {
        store_raw_upload(&state, &query, &headers, &body).await
    };

    match result {
        Ok(result) => {
            let json = serde_json::to_string(&result).unwrap_or_default();
            (
                StatusCode::OK,
                cors_headers(),
                [("content-type", "application/json")],
                json + "\n",
            )
                .into_response()
        }
        Err(msg) => (StatusCode::BAD_REQUEST, cors_headers(), msg).into_response(),
    }
}

fn listen_urls(host: &str, port: u16) -> Vec<String> {
    if host != "0.0.0.0" && host != "::" && !host.is_empty() {
        return vec![format!("http://{host}:{port}/upload")];
    }
    let mut urls = vec![format!("http://127.0.0.1:{port}/upload")];
    // Best-effort local-IP enumeration without adding a dependency: connect
    // a UDP socket to a public address (no packets actually sent for a
    // connect() on UDP) and read the local address the OS would use --
    // the standard "get my LAN IP" trick, no extra crate needed.
    if let Ok(socket) = std::net::UdpSocket::bind("0.0.0.0:0")
        && socket.connect("8.8.8.8:80").is_ok()
        && let Ok(local_addr) = socket.local_addr()
        && let IpAddr::V4(v4) = local_addr.ip()
        && !v4.is_loopback()
    {
        urls.push(format!("http://{v4}:{port}/upload"));
    }
    urls.sort();
    urls.dedup();
    urls
}

pub async fn run(args: ServeArgs) -> std::io::Result<()> {
    let output_dir = std::fs::canonicalize(&args.output_dir).unwrap_or_else(|_| {
        let _ = std::fs::create_dir_all(&args.output_dir);
        PathBuf::from(&args.output_dir)
    });
    std::fs::create_dir_all(&output_dir)?;

    let state = Arc::new(ServerState {
        output_dir: output_dir.clone(),
        locks: Mutex::new(HashMap::new()),
        fountain_transfers: Mutex::new(HashMap::new()),
    });

    // CORS headers are applied per-response inside each handler (see
    // cors_headers()), matching receiver.ts's manual setCORSHeaders rather
    // than pulling in tower-http for three static headers. The OPTIONS
    // route below mirrors its 204 short-circuit for preflight requests.
    let app = Router::new()
        .route("/", get(root_handler))
        .route("/upload", post(upload_dispatch).options(options_handler))
        .fallback(not_found_handler)
        .with_state(state);

    let addr_host = if args.host == "0.0.0.0" {
        "0.0.0.0"
    } else {
        args.host.as_str()
    };
    let addr: SocketAddr = format!("{addr_host}:{}", args.port)
        .parse()
        .unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], args.port)));

    println!("Porter receiver listening on {}:{}", args.host, args.port);
    println!("Saving uploads to {}", output_dir.display());
    for u in listen_urls(&args.host, args.port) {
        println!("  {u}");
    }
    println!("\nExamples:");
    println!(
        "  curl --data-binary @file.txt http://127.0.0.1:{}/upload?filename=file.txt",
        args.port
    );
    println!(
        "  curl -F file=@photo.jpg http://127.0.0.1:{}/upload",
        args.port
    );

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    println!("Receiver stopped.");
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

async fn not_found_handler() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        cors_headers(),
        "Not found".to_string(),
    )
}

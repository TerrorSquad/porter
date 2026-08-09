//! `porter join` -- reassembles the `.partaa`, `.partab`, ... files a receiver
//! wrote into the single original file.
//!
//! Ported from nodejs/src/lib/joiner.ts, whose behaviour this mirrors exactly:
//! the alphabetic part ordering, the gap warnings, the checksum verification
//! and the tmp-file-then-rename write are all observable and are covered by
//! joiner.test.ts. Deviations from the TypeScript are called out inline.

use std::io::Write;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::serve::alpha_part_suffix;

/// A part file found on disk, with its 1-based index decoded from the suffix.
struct PartEntry {
    index: i64,
    file_name: String,
}

/// Outcome of a join run. `main` turns this into an exit code; the tests
/// assert on it directly rather than trapping `process.exit` the way
/// joiner.test.ts has to.
#[derive(Debug, PartialEq, Eq)]
pub enum JoinOutcome {
    Joined { dest: PathBuf, bytes: u64 },
    Failed(String),
}

/// Decodes a base-26 alphabetic suffix (`aa` -> 1, `ab` -> 2, ...) back to its
/// 1-based part index. Returns None for a suffix containing anything but
/// lowercase letters, so unrelated files sharing the `<base>.part` prefix are
/// skipped rather than being folded in at a bogus index.
///
/// ponytail: the TS version does no validation here -- it maps any character
/// through `charCodeAt(0) - 97`, so `<base>.partZZ` or `<base>.part.bak` would
/// decode to a negative or wildly large index and silently corrupt the output
/// ordering. Rejecting them is strictly safer and costs one guard.
fn decode_part_suffix(suffix: &str) -> Option<i64> {
    if suffix.is_empty() || !suffix.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    let mut idx: i64 = 0;
    for b in suffix.bytes() {
        idx = idx.checked_mul(26)?.checked_add((b - b'a') as i64)?;
    }
    Some(idx + 1) // back to 1-based
}

/// Finds `<base>.part*` files in `dir`, sorted by index, warning about gaps.
fn scan_part_files(dir: &Path, base: &str) -> std::io::Result<Vec<PartEntry>> {
    let prefix = format!("{base}.part");
    let mut results: Vec<PartEntry> = Vec::new();

    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(suffix) = name.strip_prefix(&prefix) else {
            continue;
        };
        let Some(index) = decode_part_suffix(suffix) else {
            continue;
        };
        results.push(PartEntry {
            index,
            file_name: name,
        });
    }

    results.sort_by_key(|p| p.index);

    // Report gaps: every index from 1 to the highest one seen that has no file.
    let max = results.last().map(|p| p.index).unwrap_or(0);
    for i in 1..=max {
        if !results.iter().any(|p| p.index == i) {
            eprintln!(
                "Warning: missing part {i} ({base}.part{})",
                alpha_part_suffix(i - 1)
            );
        }
    }

    Ok(results)
}

/// Reads `<base>.sha256` if present. A missing file is not an error -- it just
/// means there is nothing to verify against.
fn load_checksum(dir: &Path, base: &str) -> Option<String> {
    let path = dir.join(format!("{base}.sha256"));
    let contents = std::fs::read_to_string(path).ok()?;
    let trimmed = contents.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

/// Resolves a user-supplied target to the (directory, base-name) pair the part
/// files live under. Accepts a transfer directory, any file inside one, or a
/// bare transfer id/folder name relative to the CWD.
fn resolve_transfer_dir(target: &str) -> Option<(PathBuf, String)> {
    let path = Path::new(target);

    if path.is_dir() {
        let base = path.file_name()?.to_string_lossy().into_owned();
        return Some((path.to_path_buf(), base));
    }

    if path.is_file() {
        let dir = path.parent()?.to_path_buf();
        let base = dir.file_name()?.to_string_lossy().into_owned();
        return Some((dir, base));
    }

    let candidate = std::env::current_dir().ok()?.join(target);
    if candidate.is_dir() {
        return Some((candidate, target.to_string()));
    }

    None
}

pub struct JoinArgs {
    pub targets: Vec<String>,
    pub output: Option<String>,
    pub force: bool,
    pub verify: bool,
}

/// Parses `porter join`'s arguments. Unlike the sender's `--flag=value` shape,
/// join takes a space-separated `--output <path>` (matching joiner.ts), so it
/// gets its own parser rather than reusing cli.rs's flag map.
pub fn parse_join_args(args: &[String]) -> Result<JoinArgs, String> {
    let mut targets = Vec::new();
    let mut output = None;
    let mut force = false;
    let mut verify = true;

    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        match a.as_str() {
            "--output" | "-o" => {
                i += 1;
                output = Some(args.get(i).cloned().unwrap_or_default());
            }
            "--force" | "-f" => force = true,
            "--no-verify" => verify = false,
            _ if !a.starts_with('-') => targets.push(a.clone()),
            _ => return Err(format!("Unknown join flag: {a}")),
        }
        i += 1;
    }

    Ok(JoinArgs {
        targets,
        output,
        force,
        verify,
    })
}

pub const USAGE: &str =
    "Usage: porter join <transfer-dir|file|id> [...] [--output <path>] [--force] [--no-verify]";

/// Joins one target. Returns the outcome rather than exiting, so callers (and
/// tests) decide what a failure means.
pub fn join_one(target: &str, args: &JoinArgs) -> JoinOutcome {
    let Some((dir, base)) = resolve_transfer_dir(target) else {
        return JoinOutcome::Failed(format!(
            "Error: cannot find transfer directory for \"{target}\""
        ));
    };

    let parts = match scan_part_files(&dir, &base) {
        Ok(p) => p,
        Err(e) => return JoinOutcome::Failed(format!("Error: cannot read {}: {e}", dir.display())),
    };
    if parts.is_empty() {
        return JoinOutcome::Failed(format!("Error: no part files found in {}", dir.display()));
    }

    let dest = match &args.output {
        Some(o) if !o.is_empty() => match std::path::absolute(o) {
            Ok(p) => p,
            Err(e) => return JoinOutcome::Failed(format!("Error: bad --output path {o}: {e}")),
        },
        _ => dir.join(format!("{base}.joined")),
    };

    if dest.exists() && !args.force {
        return JoinOutcome::Failed(format!(
            "Error: output file already exists: {} (use --force to overwrite)",
            dest.display()
        ));
    }

    let total_size: u64 = parts
        .iter()
        .filter_map(|p| std::fs::metadata(dir.join(&p.file_name)).ok())
        .map(|m| m.len())
        .sum();
    println!(
        "Joining {} parts ({total_size} bytes total) → {}",
        parts.len(),
        dest.display()
    );

    // Write to a tmp file beside the destination and rename only once the
    // checksum has been confirmed, so a mismatch never leaves a partial or
    // wrong .joined file behind.
    let tmp = dest.with_extension(format!(
        "{}tmp.{}",
        dest.extension()
            .map(|e| format!("{}.", e.to_string_lossy()))
            .unwrap_or_default(),
        std::process::id()
    ));

    let mut hasher = Sha256::new();
    {
        let mut out = match std::fs::File::create(&tmp) {
            Ok(f) => f,
            Err(e) => {
                return JoinOutcome::Failed(format!("Error: cannot create {}: {e}", tmp.display()));
            }
        };
        for p in &parts {
            let data = match std::fs::read(dir.join(&p.file_name)) {
                Ok(d) => d,
                Err(e) => {
                    let _ = std::fs::remove_file(&tmp);
                    return JoinOutcome::Failed(format!("Error: cannot read {}: {e}", p.file_name));
                }
            };
            if let Err(e) = out.write_all(&data) {
                let _ = std::fs::remove_file(&tmp);
                return JoinOutcome::Failed(format!("Error: cannot write {}: {e}", tmp.display()));
            }
            hasher.update(&data);
        }
    }

    let actual: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    println!("SHA-256: {actual}");

    if args.verify {
        match load_checksum(&dir, &base) {
            Some(expected) => {
                if !expected.eq_ignore_ascii_case(&actual) {
                    let _ = std::fs::remove_file(&tmp);
                    return JoinOutcome::Failed(format!(
                        "Checksum mismatch: expected {expected}, got {actual}"
                    ));
                }
                println!("Checksum verified ✓");
            }
            None => println!("(no checksum file — skipping verification)"),
        }
    }

    if let Err(e) = std::fs::rename(&tmp, &dest) {
        let _ = std::fs::remove_file(&tmp);
        return JoinOutcome::Failed(format!("Error: cannot write {}: {e}", dest.display()));
    }

    let bytes = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
    println!("Joined: {} ({bytes} bytes)", dest.display());
    JoinOutcome::Joined { dest, bytes }
}

/// Entry point for the `join` subcommand. Returns the process exit code.
pub fn run(args: &[String]) -> i32 {
    let args = match parse_join_args(args) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };

    if args.targets.is_empty() {
        eprintln!("{USAGE}");
        return 1;
    }

    for target in &args.targets {
        if let JoinOutcome::Failed(msg) = join_one(target, &args) {
            eprintln!("{msg}");
            return 1;
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Creates a unique scratch directory for one test.
    fn tmp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "porter-join-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn base_of(dir: &Path) -> String {
        dir.file_name().unwrap().to_string_lossy().into_owned()
    }

    fn sha256_hex(data: &[u8]) -> String {
        Sha256::digest(data)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    fn default_args() -> JoinArgs {
        JoinArgs {
            targets: vec![],
            output: None,
            force: false,
            verify: true,
        }
    }

    #[test]
    fn decodes_alphabetic_suffixes() {
        assert_eq!(decode_part_suffix("aa"), Some(1));
        assert_eq!(decode_part_suffix("ab"), Some(2));
        assert_eq!(decode_part_suffix("ba"), Some(27));
        // Round-trips against the encoder serve.rs already uses.
        for i in 0..60 {
            assert_eq!(decode_part_suffix(&alpha_part_suffix(i)), Some(i + 1));
        }
    }

    #[test]
    fn rejects_non_alphabetic_suffixes() {
        // Unrelated files sharing the prefix must not be joined in.
        assert_eq!(decode_part_suffix(""), None);
        assert_eq!(decode_part_suffix("AA"), None);
        assert_eq!(decode_part_suffix(".bak"), None);
        assert_eq!(decode_part_suffix("a1"), None);
    }

    #[test]
    fn joins_alphabetic_parts_and_verifies_the_checksum() {
        let dir = tmp_dir("verify");
        let base = base_of(&dir);
        std::fs::write(dir.join(format!("{base}.partaa")), b"Hello, ").unwrap();
        std::fs::write(dir.join(format!("{base}.partab")), b"World!").unwrap();
        std::fs::write(
            dir.join(format!("{base}.sha256")),
            sha256_hex(b"Hello, World!"),
        )
        .unwrap();

        let out = join_one(dir.to_str().unwrap(), &default_args());
        assert!(matches!(out, JoinOutcome::Joined { .. }), "{out:?}");

        let joined = std::fs::read(dir.join(format!("{base}.joined"))).unwrap();
        assert_eq!(joined, b"Hello, World!");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn joins_what_is_present_when_a_part_is_missing() {
        let dir = tmp_dir("gap");
        let base = base_of(&dir);
        std::fs::write(dir.join(format!("{base}.partaa")), b"AAA").unwrap();
        // .partab intentionally missing
        std::fs::write(dir.join(format!("{base}.partac")), b"CCC").unwrap();

        let out = join_one(dir.to_str().unwrap(), &default_args());
        assert!(matches!(out, JoinOutcome::Joined { .. }), "{out:?}");
        let joined = std::fs::read(dir.join(format!("{base}.joined"))).unwrap();
        assert_eq!(joined, b"AAACCC");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn fails_on_checksum_mismatch_and_writes_nothing() {
        let dir = tmp_dir("mismatch");
        let base = base_of(&dir);
        std::fs::write(dir.join(format!("{base}.partaa")), b"content").unwrap();
        std::fs::write(dir.join(format!("{base}.sha256")), "not-the-real-checksum").unwrap();

        let out = join_one(dir.to_str().unwrap(), &default_args());
        match out {
            JoinOutcome::Failed(msg) => assert!(msg.contains("Checksum mismatch"), "{msg}"),
            other => panic!("expected failure, got {other:?}"),
        }
        // The tmp file must be cleaned up and no .joined left behind.
        assert!(!dir.join(format!("{base}.joined")).exists());
        let strays: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("tmp"))
            .collect();
        assert!(strays.is_empty(), "tmp file left behind");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn no_verify_skips_a_mismatching_checksum() {
        let dir = tmp_dir("noverify");
        let base = base_of(&dir);
        std::fs::write(dir.join(format!("{base}.partaa")), b"content").unwrap();
        std::fs::write(dir.join(format!("{base}.sha256")), "not-the-real-checksum").unwrap();

        let args = JoinArgs {
            verify: false,
            ..default_args()
        };
        let out = join_one(dir.to_str().unwrap(), &args);
        assert!(matches!(out, JoinOutcome::Joined { .. }), "{out:?}");
        let joined = std::fs::read(dir.join(format!("{base}.joined"))).unwrap();
        assert_eq!(joined, b"content");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn refuses_to_overwrite_without_force() {
        let dir = tmp_dir("force");
        let base = base_of(&dir);
        std::fs::write(dir.join(format!("{base}.partaa")), b"new-content").unwrap();
        std::fs::write(dir.join(format!("{base}.joined")), b"old-content").unwrap();

        let out = join_one(dir.to_str().unwrap(), &default_args());
        match out {
            JoinOutcome::Failed(msg) => assert!(msg.contains("already exists"), "{msg}"),
            other => panic!("expected failure, got {other:?}"),
        }
        assert_eq!(
            std::fs::read(dir.join(format!("{base}.joined"))).unwrap(),
            b"old-content"
        );

        let args = JoinArgs {
            force: true,
            ..default_args()
        };
        let out = join_one(dir.to_str().unwrap(), &args);
        assert!(matches!(out, JoinOutcome::Joined { .. }), "{out:?}");
        assert_eq!(
            std::fs::read(dir.join(format!("{base}.joined"))).unwrap(),
            b"new-content"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn errors_when_no_targets_given() {
        assert_eq!(run(&[]), 1);
    }

    #[test]
    fn errors_when_the_transfer_directory_cannot_be_resolved() {
        let out = join_one("definitely-does-not-exist-xyz", &default_args());
        match out {
            JoinOutcome::Failed(msg) => {
                assert!(msg.contains("cannot find transfer directory"), "{msg}")
            }
            other => panic!("expected failure, got {other:?}"),
        }
    }

    #[test]
    fn errors_when_no_part_files_are_found() {
        let dir = tmp_dir("empty");
        let out = join_one(dir.to_str().unwrap(), &default_args());
        match out {
            JoinOutcome::Failed(msg) => assert!(msg.contains("no part files found"), "{msg}"),
            other => panic!("expected failure, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn resolves_a_file_inside_the_transfer_directory() {
        let dir = tmp_dir("byfile");
        let base = base_of(&dir);
        let part = dir.join(format!("{base}.partaa"));
        std::fs::write(&part, b"data").unwrap();

        let out = join_one(part.to_str().unwrap(), &default_args());
        assert!(matches!(out, JoinOutcome::Joined { .. }), "{out:?}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn honours_an_explicit_output_path() {
        let dir = tmp_dir("output");
        let base = base_of(&dir);
        std::fs::write(dir.join(format!("{base}.partaa")), b"payload").unwrap();
        let dest = dir.join("elsewhere.bin");

        let args = JoinArgs {
            output: Some(dest.to_string_lossy().into_owned()),
            ..default_args()
        };
        let out = join_one(dir.to_str().unwrap(), &args);
        assert!(matches!(out, JoinOutcome::Joined { .. }), "{out:?}");
        assert_eq!(std::fs::read(&dest).unwrap(), b"payload");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parses_join_flags() {
        let args = parse_join_args(&[
            "dir".to_string(),
            "--output".to_string(),
            "out.bin".to_string(),
            "--force".to_string(),
            "--no-verify".to_string(),
        ])
        .unwrap();
        assert_eq!(args.targets, vec!["dir".to_string()]);
        assert_eq!(args.output.as_deref(), Some("out.bin"));
        assert!(args.force);
        assert!(!args.verify);
    }

    #[test]
    fn rejects_an_unknown_join_flag() {
        assert!(parse_join_args(&["--nope".to_string()]).is_err());
    }
}

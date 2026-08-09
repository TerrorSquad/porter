//! CLI argument parsing. Hand-rolled, matching porter.ts's own approach --
//! ~15 flags with simple `--flag=value`/`--flag` shapes don't need a
//! dependency like clap. Mirrors the flag surface of nodejs/src/porter.ts
//! (sender) and runReceiver's flag reads in nodejs/src/lib/receiver.ts
//! (serve) and joiner.ts (join). `join` takes a space-separated
//! `--output <path>`, so its tail is handed to join::parse_join_args rather
//! than the `--flag=value` parser here.

use crate::qrtypes::EccLevel;

pub enum Command {
    Send(SendArgs),
    Serve(ServeArgs),
    /// Raw argv tail after `join`; parsed by join::parse_join_args, which
    /// handles the space-separated `--output <path>` shape this module's
    /// `--flag=value` parser cannot express.
    Join(Vec<String>),
}

pub struct SendArgs {
    pub input_files: Vec<String>,
    pub base64: bool,
    pub verify: Option<String>,
    pub split_aware: bool,
    pub invert: bool,
    pub ecc_level: EccLevel,
    pub multi: Option<MultiQr>,
    pub fountain: bool,
    pub no_info: bool,
    pub speed: f64,
    pub buffer: i32,
    pub slideshow: bool,
    pub reset: bool,
    pub resume: bool,
    /// Skip the long-transfer confirmation prompt (for non-interactive use).
    pub yes: bool,
}

pub enum MultiQr {
    Auto,
    Count(u32),
}

pub struct ServeArgs {
    pub host: String,
    pub port: u16,
    pub output_dir: String,
}

/// Splits argv into (flag_name_without_dashes -> value). A bare `--flag`
/// (no `=`) maps to "true", matching porter.ts's own flag parser.
fn parse_flags(args: &[String]) -> std::collections::HashMap<String, String> {
    let mut flags = std::collections::HashMap::new();
    for a in args {
        if let Some(rest) = a.strip_prefix("--") {
            match rest.split_once('=') {
                Some((k, v)) => {
                    flags.insert(k.to_string(), v.to_string());
                }
                None => {
                    flags.insert(rest.to_string(), "true".to_string());
                }
            }
        }
    }
    flags
}

fn flag_is_true(flags: &std::collections::HashMap<String, String>, key: &str) -> bool {
    flags.get(key).map(|v| v == "true").unwrap_or(false)
}

pub fn parse(args: &[String]) -> Command {
    if args.first().map(String::as_str) == Some("join") {
        return Command::Join(args[1..].to_vec());
    }

    if args.first().map(String::as_str) == Some("serve") {
        let rest = &args[1..];
        let flags = parse_flags(rest);
        return Command::Serve(ServeArgs {
            host: flags
                .get("host")
                .cloned()
                .unwrap_or_else(|| "0.0.0.0".to_string()),
            port: flags
                .get("port")
                .and_then(|v| v.parse().ok())
                .unwrap_or(8080),
            output_dir: flags
                .get("output-dir")
                .cloned()
                .unwrap_or_else(|| "received".to_string()),
        });
    }

    let flags = parse_flags(args);
    let input_files: Vec<String> = args
        .iter()
        .filter(|a| !a.starts_with("--"))
        .cloned()
        .collect();

    let ecc_level = flags
        .get("ecc")
        .and_then(|v| EccLevel::parse(v))
        .unwrap_or(EccLevel::L);

    let multi = flags.get("multi").and_then(|v| {
        let lower = v.to_lowercase();
        if lower == "auto" {
            Some(MultiQr::Auto)
        } else {
            lower
                .parse::<u32>()
                .ok()
                .filter(|n| (1..=4).contains(n))
                .map(MultiQr::Count)
        }
    });

    let speed = flags
        .get("speed")
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|v| *v > 0.0)
        .unwrap_or(0.5);
    let buffer = flags
        .get("buffer")
        .and_then(|v| v.parse::<i32>().ok())
        .unwrap_or(10);

    Command::Send(SendArgs {
        input_files,
        base64: flag_is_true(&flags, "base64"),
        verify: flags.get("verify").cloned(),
        split_aware: flag_is_true(&flags, "split-aware"),
        invert: flag_is_true(&flags, "invert"),
        ecc_level,
        multi,
        fountain: flag_is_true(&flags, "fountain"),
        no_info: flag_is_true(&flags, "no-info"),
        speed,
        buffer,
        slideshow: flag_is_true(&flags, "slideshow"),
        reset: flag_is_true(&flags, "reset"),
        resume: flag_is_true(&flags, "resume"),
        yes: flag_is_true(&flags, "yes"),
    })
}

pub fn print_usage() {
    println!("\x1b[1mQR DATA PORTER\x1b[0m");
    println!("Usage:");
    println!("  porter <file> [options]");
    println!("  porter <file.part*.txt|file.partaa|...> [options]");
    println!("  echo 'data' | porter [options]");
    println!("\nOptions:");
    println!("  --slideshow       Start in slideshow mode");
    println!("  --base64          Enable Base64 encoding (for binary files)");
    println!("  --verify=<file>   Verify against SHA256 checksum file");
    println!("  --split-aware     Auto-detect and concatenate .part*.txt or .partaa files");
    println!("  --invert          Invert QR code colors");
    println!("  --ecc=L|M|Q|H     Error correction level (Default: L)");
    println!("  --multi=N|auto    Render N QR codes in a grid (1-4, or 'auto')");
    println!("                    Speeds up transfer: auto-detected or manual");
    println!("  --fountain        Use fountain (LT code) coding instead of sequential");
    println!("                    chunks: the receiver can reconstruct the file from");
    println!("                    ANY sufficient subset of frames, in any order.");
    println!("                    Best for long/lossy scans. --base64 has no effect.");
    println!("  --no-info         Hide the info sidebar (chunk/progress/etc.)");
    println!("  --speed=<seconds> QR code delay (Default: 0.5)");
    println!("                    0.5 = 2 chunks/sec (default, works everywhere)");
    println!("                    0.3 = 3.3 chunks/sec (good lighting)");
    println!("                    0.2 = 5 chunks/sec (bright light + steady)");
    println!("                    0.1 = 10 chunks/sec (optimal conditions)");
    println!("  --buffer=10       Vertical buffer lines");
    println!("  --resume          Persist/restore slideshow position via .porter_history");
    println!("                    (off by default -- no disk trace unless requested)");
    println!("  --reset           Ignore any saved .porter_history position (needs --resume)");
    println!("  --yes             Skip the confirmation prompt for very long transfers");
    println!();
    println!("\x1b[1mSubcommands:\x1b[0m");
    println!("  porter serve [--port=8080] [--host=0.0.0.0] [--output-dir=received]");
    println!("              Start an HTTP receiver. Accepts QR scan JSON uploads,");
    println!("              raw file uploads, and multipart/form-data.");
    println!("              Reconstructs multi-part and fountain transfers automatically.");
    println!("  porter join <transfer-dir|file|id> [...] [--output <path>] [--force]");
    println!("              [--no-verify]");
    println!("              Join previously received .partXX files into a single file.");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_serve_subcommand_with_defaults() {
        let args = vec!["serve".to_string()];
        match parse(&args) {
            Command::Serve(s) => {
                assert_eq!(s.host, "0.0.0.0");
                assert_eq!(s.port, 8080);
                assert_eq!(s.output_dir, "received");
            }
            _ => panic!("expected Serve"),
        }
    }

    #[test]
    fn parses_serve_subcommand_with_overrides() {
        let args = vec![
            "serve".to_string(),
            "--port=9000".to_string(),
            "--host=127.0.0.1".to_string(),
            "--output-dir=/tmp/out".to_string(),
        ];
        match parse(&args) {
            Command::Serve(s) => {
                assert_eq!(s.host, "127.0.0.1");
                assert_eq!(s.port, 9000);
                assert_eq!(s.output_dir, "/tmp/out");
            }
            _ => panic!("expected Serve"),
        }
    }

    #[test]
    fn parses_send_args_and_defaults() {
        let args = vec![
            "file.txt".to_string(),
            "--fountain".to_string(),
            "--speed=0.2".to_string(),
        ];
        match parse(&args) {
            Command::Send(s) => {
                assert_eq!(s.input_files, vec!["file.txt".to_string()]);
                assert!(s.fountain);
                assert_eq!(s.speed, 0.2);
                assert_eq!(s.ecc_level, EccLevel::L);
                assert!(!s.resume);
            }
            _ => panic!("expected Send"),
        }
    }

    #[test]
    fn parses_multi_auto_and_numeric() {
        let args = vec!["f".to_string(), "--multi=auto".to_string()];
        match parse(&args) {
            Command::Send(s) => assert!(matches!(s.multi, Some(MultiQr::Auto))),
            _ => panic!("expected Send"),
        }

        let args = vec!["f".to_string(), "--multi=3".to_string()];
        match parse(&args) {
            Command::Send(s) => assert!(matches!(s.multi, Some(MultiQr::Count(3)))),
            _ => panic!("expected Send"),
        }

        let args = vec!["f".to_string(), "--multi=9".to_string()];
        match parse(&args) {
            Command::Send(s) => assert!(s.multi.is_none()),
            _ => panic!("expected Send"),
        }
    }
}

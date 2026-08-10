mod chunker;
mod cli;
mod constants;
mod fountain;
mod join;
mod qrtypes;
mod renderer;
mod serve;
mod state;
mod tui;

use std::io::{IsTerminal, Read, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use crossterm::terminal;

use chunker::{ChunkOptions, Chunker};
use cli::{Command, MultiQr, SendArgs, ServeArgs};
use fountain::{FountainChunker, FountainLayoutOptions};
use tui::{App, InputMode, RenderOptions};

// DEC synchronized-output (private mode 2026): tells the terminal to buffer
// everything between BSU/ESU and composite it in one repaint. ratatui has no
// built-in support for this (verified: nothing in ratatui-core/
// ratatui-crossterm wraps draws in it), so the markers are written directly
// to stdout around each `terminal.draw()` call -- CrosstermBackend's default
// writer is the same stdout handle, so the writes interleave correctly as
// long as stdout is flushed before/after. See docs/adr/0004-sender-language-
// rust.md: this is what prevents camera-visible tearing mid-frame.
const SYNC_BEGIN: &[u8] = b"\x1b[?2026h";
const SYNC_END: &[u8] = b"\x1b[?2026l";

/// Upper bound on codes per frame, for `--multi=auto` and the `]` key alike.
/// Not a layout limit -- `effective_multi_qr` clamps to what fits -- just a
/// sane ceiling so a held-down key can't run the request count away.
const MAX_MULTI_QR: u32 = 64;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match cli::parse(&args) {
        Command::Send(send_args) => run_sender(send_args),
        Command::Serve(serve_args) => run_serve(serve_args),
        // join owns its own arg parsing (space-separated `--output <path>`,
        // unlike the sender's `--flag=value`), so cli::parse hands the raw
        // tail straight through.
        Command::Join(join_args) => std::process::exit(join::run(&join_args)),
    }
}

fn run_serve(args: ServeArgs) {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("failed to build tokio runtime");
    if let Err(e) = rt.block_on(serve::run(args)) {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------------------
// Input handling: single file, multi-part concatenation, or stdin. Direct
// port of porter.ts's input-handling block (porter.ts:61-202). Unchanged by
// the ratatui rewrite -- this is file I/O, not terminal presentation.
// ---------------------------------------------------------------------------

struct InputContent {
    content: Vec<u8>,
    file_name: String,
}

fn part_suffix_regex_matches(name: &str) -> bool {
    // Matches `.part\d+` or `.part[a-z]{2}` at the end of the filename,
    // mirroring porter.ts's /\.part(?:\d+|[a-z]{2})$/.
    if let Some(idx) = name.rfind(".part") {
        let suffix = &name[idx + 5..];
        if !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit()) {
            return true;
        }
        if suffix.len() == 2 && suffix.chars().all(|c| c.is_ascii_lowercase()) {
            return true;
        }
    }
    false
}

fn strip_part_suffix(name: &str) -> String {
    if let Some(idx) = name.rfind(".part") {
        let suffix = &name[idx + 5..];
        let is_numeric = !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit());
        let is_alpha = suffix.len() == 2 && suffix.chars().all(|c| c.is_ascii_lowercase());
        if is_numeric || is_alpha {
            return name[..idx].to_string();
        }
    }
    name.to_string()
}

fn gather_input(send_args: &SendArgs) -> Result<InputContent, String> {
    let stdin_is_tty = std::io::stdin().is_terminal();

    if !stdin_is_tty && send_args.input_files.is_empty() {
        let mut content = Vec::new();
        std::io::stdin()
            .read_to_end(&mut content)
            .map_err(|e| format!("Error reading from stdin: {e}"))?;
        return Ok(InputContent {
            content,
            file_name: "stdin-stream".to_string(),
        });
    }

    if !send_args.input_files.is_empty() {
        let first_file = &send_args.input_files[0];
        let file_name_only = Path::new(first_file)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| first_file.clone());
        let base_name = strip_part_suffix(&file_name_only);

        if send_args.split_aware || part_suffix_regex_matches(&file_name_only) {
            let dir = Path::new(first_file).parent().unwrap_or(Path::new("."));
            let dir = if dir.as_os_str().is_empty() {
                Path::new(".")
            } else {
                dir
            };
            let mut part_files: Vec<String> = std::fs::read_dir(dir)
                .map_err(|e| format!("Error reading directory {}: {e}", dir.display()))?
                .filter_map(|e| e.ok())
                .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
                .filter(|f| f.contains(&base_name) && part_suffix_regex_matches(f))
                .collect();

            part_files.sort_by(|a, b| {
                let num_a = a.rsplit(".part").next().and_then(|s| s.parse::<u64>().ok());
                let num_b = b.rsplit(".part").next().and_then(|s| s.parse::<u64>().ok());
                match (num_a, num_b) {
                    (Some(na), Some(nb)) => na.cmp(&nb),
                    _ => a.cmp(b),
                }
            });

            let mut content = Vec::new();
            for f in &part_files {
                let path = dir.join(f);
                let mut bytes =
                    std::fs::read(&path).map_err(|e| format!("Error reading file {f}: {e}"))?;
                content.append(&mut bytes);
            }

            let file_name = if base_name.ends_with(".tar.xz.enc") {
                base_name.clone()
            } else {
                format!("{base_name}.enc")
            };
            return Ok(InputContent { content, file_name });
        }

        let path = Path::new(first_file);
        if !path.exists() {
            return Err(format!("Error: File not found: {first_file}"));
        }
        let content =
            std::fs::read(path).map_err(|e| format!("Error reading {first_file}: {e}"))?;
        let file_name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| first_file.clone());
        return Ok(InputContent { content, file_name });
    }

    cli::print_usage();
    std::process::exit(1);
}

enum ChunkerKind {
    Sequential(Chunker),
    Fountain(FountainChunker),
}

fn layout(
    kind: &mut ChunkerKind,
    rows: i32,
    send_args: &SendArgs,
    use_base64: bool,
    provided_checksum: Option<String>,
) {
    match kind {
        ChunkerKind::Sequential(c) => {
            c.calculate_layout(
                rows,
                &ChunkOptions {
                    buffer: send_args.buffer,
                    use_base64,
                    add_header: true,
                    ecc_level: send_args.ecc_level,
                    add_checksum: send_args.verify.is_some(),
                    provided_checksum,
                },
            );
        }
        ChunkerKind::Fountain(c) => {
            c.calculate_layout(
                rows,
                &FountainLayoutOptions {
                    buffer: send_args.buffer,
                    ecc_level: send_args.ecc_level,
                },
            );
        }
    }
}

fn materialize_chunks(kind: &ChunkerKind) -> (Vec<String>, i32) {
    match kind {
        ChunkerKind::Sequential(c) => (c.chunks.clone(), c.version),
        ChunkerKind::Fountain(c) => {
            let chunks: Vec<String> = (0..c.total_frames).map(|i| c.frame(i)).collect();
            (chunks, c.version)
        }
    }
}

/// Warns before starting a transfer that will take impractically long.
///
/// QR is a low-bandwidth channel, so a large file runs for hours -- worth
/// knowing before the slideshow starts rather than 90 minutes in. Fountain
/// also needs materially more than K *distinct* symbols before peeling
/// completes (measured 1.33x-1.69x K over K=50..20000), and a receiver
/// rescanning a looping slideshow collects duplicates on top of that, so the
/// realistic scan time is well above one pass of the pool.
fn long_transfer_warning(kind: &ChunkerKind, frame_count: usize, speed: f64) -> Option<String> {
    const WARN_ABOVE_SECS: f64 = 15.0 * 60.0;
    /// Distinct symbols peeling needs, as a multiple of K. Measured across
    /// K=50..20000 against the shared degree table: 1.33x-1.69x.
    const PEELING_OVERHEAD: f64 = 1.5;

    let one_pass_secs = frame_count as f64 * speed;
    let (needed_secs, detail) = match kind {
        ChunkerKind::Fountain(c) => {
            // Peeling needs ~1.5x K distinct symbols (measured 1.33-1.69x);
            // a receiver scanning a looping slideshow re-sees symbols it
            // already has, so treat one full pass as the floor.
            let to_decode = (c.k as f64 * PEELING_OVERHEAD * speed).max(one_pass_secs);
            (
                to_decode,
                format!(
                    "  fountain: {} blocks, {frame_count} frames in the pool\n  \
                     the receiver needs ~{} distinct symbols before it can decode",
                    c.k,
                    (c.k as f64 * PEELING_OVERHEAD).ceil() as u64,
                ),
            )
        }
        ChunkerKind::Sequential(_) => (
            one_pass_secs,
            format!("  sequential: {frame_count} frames, every one must be scanned"),
        ),
    };

    if needed_secs < WARN_ABOVE_SECS {
        return None;
    }

    Some(format!(
        "Warning: this transfer will take a long time.\n{detail}\n  \
         estimated: {} at {speed:.2}s per frame (best case, no missed frames)",
        format_duration(needed_secs),
    ))
}

fn format_duration(secs: f64) -> String {
    let total = secs.round() as u64;
    match (total / 3600, (total % 3600) / 60) {
        (0, m) => format!("{m}m"),
        (h, m) => format!("{h}h {m}m"),
    }
}

/// Blocks on a y/N answer. Returns false on EOF (non-interactive stdin), so
/// a piped/CI invocation aborts rather than silently starting a multi-hour
/// slideshow -- `--yes` is the way to opt in without a terminal.
fn confirm_proceed() -> bool {
    eprint!("Continue? [y/N] ");
    use std::io::Write;
    let _ = std::io::stderr().flush();

    let mut answer = String::new();
    match std::io::stdin().read_line(&mut answer) {
        Ok(0) | Err(_) => false,
        Ok(_) => matches!(answer.trim(), "y" | "Y" | "yes" | "Yes"),
    }
}

fn run_sender(send_args: SendArgs) {
    let input = match gather_input(&send_args) {
        Ok(input) => input,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(1);
        }
    };

    if input.content.is_empty() {
        eprintln!("Error: Input is empty.");
        std::process::exit(1);
    }

    let (_term_cols, term_rows) = terminal::size().unwrap_or((80, 24));

    // `auto` requests the ceiling rather than a fixed guess: effective_multi_qr
    // already walks the count down to whatever the terminal actually fits, so
    // asking for the maximum makes "auto" mean "fill the space". The old
    // constant 4 under-filled a wide, short window (a dropdown terminal fits
    // several codes across but only one down) and over-asked on a small one --
    // the fit check papered over the latter, never the former.
    let multi_qr = send_args.multi.as_ref().map(|m| match m {
        MultiQr::Auto => MAX_MULTI_QR,
        MultiQr::Count(n) => *n,
    });

    // Sequential text (T) mode assumes 1 input byte -> 1 output byte when
    // sizing chunks to fit a QR's capacity. Binary content read as UTF-8
    // "lossy" (std::str::from_utf8/String::from_utf8_lossy) replaces every
    // invalid byte with U+FFFD, which is 3 bytes in UTF-8 -- so a
    // byte-for-byte-sized chunk of binary data can balloon well past the
    // capacity it was sized for, overflowing the chosen QR version/ECC.
    // Fountain mode is unaffected (always base64, per fountain.ts). Detect
    // this at the trust boundary (real input, not internal state) and
    // auto-enable --base64 rather than let it silently corrupt or panic.
    let effective_base64 =
        if !send_args.fountain && !send_args.base64 && std::str::from_utf8(&input.content).is_err()
        {
            eprintln!("Note: input isn't valid UTF-8; enabling --base64 automatically.");
            true
        } else {
            send_args.base64
        };

    // --verify=<file>: read an externally-supplied checksum to send instead
    // of the locally computed one -- matches porter.ts's providedChecksum
    // (porter.ts:255-262). Read once here rather than per-layout-call
    // (layout() re-runs on every terminal resize).
    let provided_checksum = send_args.verify.as_ref().and_then(|path| {
        match std::fs::read_to_string(path) {
            Ok(contents) => {
                // sha256sum-style output is "<hash>  <filename>"; TS takes
                // everything before the double space. A bare hash (no
                // filename suffix) also works since split on "  " with no
                // match just returns the whole trimmed string.
                let hash = contents.split("  ").next().unwrap_or(&contents).trim();
                Some(hash.to_string())
            }
            Err(e) => {
                eprintln!("Warning: Could not read checksum file {path}: {e}");
                None
            }
        }
    });

    let mut kind = if send_args.fountain {
        ChunkerKind::Fountain(FountainChunker::new(input.content.clone()))
    } else {
        ChunkerKind::Sequential(Chunker::new(input.content.clone()))
    };
    layout(
        &mut kind,
        term_rows as i32,
        &send_args,
        effective_base64,
        provided_checksum.clone(),
    );

    let (chunks, version) = materialize_chunks(&kind);

    let mut app = App::new(
        input.file_name.clone(),
        RenderOptions {
            speed: send_args.speed,
            is_slideshow: send_args.slideshow,
            use_inverted: send_args.invert,
            ecc_level: send_args.ecc_level,
            multi_qr,
            no_info: send_args.no_info,
        },
    );
    app.set_chunks(chunks, version);

    if !send_args.reset {
        let saved = state::load_progress(send_args.resume, &input.file_name);
        if saved > 0 && saved < app.chunks.len() {
            app.index = saved;
        }
    }

    if let Some(warning) = long_transfer_warning(&kind, app.chunks.len(), send_args.speed) {
        eprintln!("{warning}");
        if !send_args.yes && !confirm_proceed() {
            eprintln!("Aborted.");
            return;
        }
    }

    let mut terminal = ratatui::init();
    let result = event_loop(
        &mut terminal,
        &mut app,
        &mut kind,
        &send_args,
        &input.file_name,
        effective_base64,
        provided_checksum,
    );
    ratatui::restore();

    if let Err(e) = result {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}

fn draw_frame(terminal: &mut ratatui::DefaultTerminal, app: &App) -> std::io::Result<()> {
    let mut stdout = std::io::stdout();
    stdout.write_all(SYNC_BEGIN)?;
    stdout.flush()?;
    terminal.draw(|frame| tui::render(frame, app))?;
    let mut stdout = std::io::stdout();
    stdout.write_all(SYNC_END)?;
    stdout.flush()?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn event_loop(
    terminal: &mut ratatui::DefaultTerminal,
    app: &mut App,
    kind: &mut ChunkerKind,
    send_args: &SendArgs,
    file_name: &str,
    use_base64: bool,
    provided_checksum: Option<String>,
) -> std::io::Result<()> {
    draw_frame(terminal, app)?;

    let mut speed = send_args.speed;
    let mut last_tick = Instant::now();
    let mut frame_count: u64 = 0;
    let mut countdown_until: Option<Instant> = None;

    // Gap-fill mode: when Some, the slideshow loops only these indices
    // (wrapping) instead of 0..chunks.len(). New control (`G`), no TS
    // reference -- see this session's plan for the design.
    let mut gap_fill: Option<Vec<usize>> = None;
    let mut gap_fill_cursor: usize = 0;

    loop {
        // Drive the 3-2-1 countdown (before switching into slideshow mode
        // from a manual pause, matching porter.ts's showCountdown) as part
        // of the normal frame loop rather than a separate blocking
        // print+sleep function -- keeps it inside ratatui's draw lifecycle.
        if let Some(until) = countdown_until {
            let remaining = until.saturating_duration_since(Instant::now());
            let n = (remaining.as_secs_f64().ceil() as u8).clamp(0, 3);
            if n == 0 {
                countdown_until = None;
                app.countdown = None;
                app.options.is_slideshow = true;
                last_tick = Instant::now();
                draw_frame(terminal, app)?;
            } else {
                app.countdown = Some(n);
                draw_frame(terminal, app)?;
                if event::poll(Duration::from_millis(200))? {
                    // Don't blanket-swallow input during the countdown: Q/
                    // Ctrl-C must still quit immediately (previously silently
                    // discarded, forcing a wait-out), and Esc cancels back to
                    // paused instead of counting down to nothing useful.
                    // Everything else is still swallowed -- e.g. accidental
                    // repeated 's' presses shouldn't stack countdowns.
                    if let Event::Key(key) = event::read()? {
                        match key.code {
                            KeyCode::Char('q') => {
                                state::save_progress(send_args.resume, file_name, app.index);
                                return Ok(());
                            }
                            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                                state::save_progress(send_args.resume, file_name, app.index);
                                return Ok(());
                            }
                            KeyCode::Esc => {
                                countdown_until = None;
                                app.countdown = None;
                                draw_frame(terminal, app)?;
                            }
                            _ => {}
                        }
                    }
                }
                continue;
            }
        }

        let poll_timeout = if app.options.is_slideshow {
            let elapsed = last_tick.elapsed();
            let interval = Duration::from_secs_f64(speed.max(0.05));
            if elapsed >= interval {
                let (term_width, term_height) = terminal::size().unwrap_or((80, 24));
                advance_slideshow(
                    app,
                    &mut gap_fill,
                    &mut gap_fill_cursor,
                    term_width,
                    term_height,
                );
                draw_frame(terminal, app)?;
                last_tick = Instant::now();
                frame_count += 1;
                if frame_count.is_multiple_of(20) {
                    state::save_progress(send_args.resume, file_name, app.index);
                }
                Duration::from_millis(50)
            } else {
                interval - elapsed
            }
        } else {
            Duration::from_millis(200)
        };

        if event::poll(poll_timeout)? {
            match event::read()? {
                Event::Resize(_, rows) => {
                    layout(
                        kind,
                        rows as i32,
                        send_args,
                        use_base64,
                        provided_checksum.clone(),
                    );
                    let (chunks, version) = materialize_chunks(kind);
                    app.set_chunks(chunks, version);
                    draw_frame(terminal, app)?;
                }
                Event::Key(key) => {
                    let outcome = handle_key(
                        key.code,
                        key.modifiers,
                        app,
                        &mut speed,
                        &mut gap_fill,
                        &mut gap_fill_cursor,
                        send_args,
                        file_name,
                    );
                    match outcome {
                        KeyOutcome::Quit => break,
                        KeyOutcome::StartCountdown => {
                            countdown_until = Some(Instant::now() + Duration::from_secs(3));
                        }
                        KeyOutcome::Continue => {}
                    }
                    draw_frame(terminal, app)?;
                }
                _ => {}
            }
        }
    }

    Ok(())
}

fn advance_slideshow(
    app: &mut App,
    gap_fill: &mut Option<Vec<usize>>,
    cursor: &mut usize,
    term_width: u16,
    term_height: u16,
) {
    if let Some(indices) = gap_fill {
        if indices.is_empty() {
            return;
        }
        *cursor = (*cursor + 1) % indices.len();
        app.index = indices[*cursor];
        return;
    }

    // move_next wraps, so a loop is simply "the index went backwards".
    // Detecting it this way also counts a multi-QR pass that straddles the
    // end (index 1550 + 8 codes -> 2) as one loop, which the old
    // `index + 1 >= len` check missed entirely.
    let before = app.index;
    app.move_next(term_width, term_height);
    if app.index <= before {
        app.loop_count += 1;
    }
}

enum KeyOutcome {
    Continue,
    StartCountdown,
    Quit,
}

#[allow(clippy::too_many_arguments)]
fn handle_key(
    code: KeyCode,
    modifiers: KeyModifiers,
    app: &mut App,
    speed: &mut f64,
    gap_fill: &mut Option<Vec<usize>>,
    gap_fill_cursor: &mut usize,
    send_args: &SendArgs,
    file_name: &str,
) -> KeyOutcome {
    // Text-entry modes (J/G) intercept all keys until Enter/Esc, replacing
    // the old blocking stdin().read_line() prompts with a live, cancellable,
    // backspace-able status-line editor (tui::StatusLineWidget renders the
    // buffer as it's typed). Matched by discriminant (not by borrowing the
    // buffer directly) so `app` stays free to pass into the commit helpers
    // below without fighting the borrow checker over `app.input_mode`.
    let is_jump = matches!(app.input_mode, InputMode::JumpToChunk(_));
    let is_gap_fill = matches!(app.input_mode, InputMode::GapFillList(_));
    if is_jump || is_gap_fill {
        match code {
            KeyCode::Enter => {
                let text = match &app.input_mode {
                    InputMode::JumpToChunk(s) | InputMode::GapFillList(s) => s.clone(),
                    InputMode::Normal => unreachable!(),
                };
                app.input_mode = InputMode::Normal;
                if is_jump {
                    app_commit_jump(&text, app, send_args, file_name);
                } else {
                    app_commit_gap_fill(&text, app, gap_fill, gap_fill_cursor);
                }
            }
            KeyCode::Esc => {
                app.input_mode = InputMode::Normal;
            }
            KeyCode::Backspace => {
                if let InputMode::JumpToChunk(s) | InputMode::GapFillList(s) = &mut app.input_mode {
                    s.pop();
                }
            }
            KeyCode::Char(c) => {
                if let InputMode::JumpToChunk(s) | InputMode::GapFillList(s) = &mut app.input_mode {
                    s.push(c);
                }
            }
            _ => {}
        }
        return KeyOutcome::Continue;
    }

    let (term_width, term_height) = terminal::size().unwrap_or((80, 24));
    let shift = modifiers.contains(KeyModifiers::SHIFT);

    match code {
        KeyCode::Right | KeyCode::Char('l') if shift => {
            app.move_by(100);
            state::save_progress(send_args.resume, file_name, app.index);
        }
        KeyCode::Left | KeyCode::Char('h') if shift => {
            app.move_by(-100);
            state::save_progress(send_args.resume, file_name, app.index);
        }
        KeyCode::Right
        | KeyCode::Up
        | KeyCode::Char('l')
        | KeyCode::Char('k')
        | KeyCode::Char(' ') => {
            app.move_next(term_width, term_height);
            state::save_progress(send_args.resume, file_name, app.index);
        }
        KeyCode::Left | KeyCode::Down | KeyCode::Char('h') | KeyCode::Char('j') => {
            app.move_prev(term_width, term_height);
            state::save_progress(send_args.resume, file_name, app.index);
        }
        KeyCode::Char('q') => {
            state::save_progress(send_args.resume, file_name, app.index);
            return KeyOutcome::Quit;
        }
        KeyCode::Char('c') if modifiers.contains(KeyModifiers::CONTROL) => {
            state::save_progress(send_args.resume, file_name, app.index);
            return KeyOutcome::Quit;
        }
        KeyCode::Char('s') => {
            if !app.options.is_slideshow {
                state::save_progress(send_args.resume, file_name, app.index);
                return KeyOutcome::StartCountdown;
            } else {
                app.options.is_slideshow = false;
                state::save_progress(send_args.resume, file_name, app.index);
            }
        }
        KeyCode::Char('+') | KeyCode::Char('=') => {
            *speed = (*speed - 0.05).max(0.05);
        }
        KeyCode::Char('-') => {
            *speed += 0.05;
        }
        // Live `--multi` adjustment. The requested count is stored as-is and
        // effective_multi_qr still decides what actually fits, so asking for
        // more than the terminal can take is harmless -- the sidebar's (xN)
        // shows what landed.
        KeyCode::Char(']') => {
            let current = app.options.multi_qr.unwrap_or(1);
            app.options.multi_qr = Some((current + 1).min(MAX_MULTI_QR));
            let fitted = app.effective_multi_qr(term_width, term_height);
            app.status_message = Some(format!(
                "Grid: {current} -> requested {}, showing {fitted}.",
                current + 1
            ));
        }
        KeyCode::Char('[') => {
            let current = app.options.multi_qr.unwrap_or(1);
            let next = current.saturating_sub(1).max(1);
            app.options.multi_qr = Some(next);
            let fitted = app.effective_multi_qr(term_width, term_height);
            app.status_message = Some(format!(
                "Grid: {current} -> requested {next}, showing {fitted}."
            ));
        }
        KeyCode::Char('g') | KeyCode::Char('G') => {
            if gap_fill.is_some() {
                *gap_fill = None;
                *gap_fill_cursor = 0;
                app.status_message = Some("Gap-fill mode cleared.".to_string());
            } else {
                app.input_mode = InputMode::GapFillList(String::new());
            }
        }
        KeyCode::Char('J') => {
            app.input_mode = InputMode::JumpToChunk(String::new());
        }
        KeyCode::Char('i') | KeyCode::Char('I') => {
            let before = app.effective_multi_qr(term_width, term_height);
            app.options.no_info = !app.options.no_info;
            // Hiding the sidebar hands its columns back to the grid, which can
            // fit another code straight away. Say so when it does -- otherwise
            // the extra QR appears with no explanation. Only worth a message
            // while the sidebar is on screen to read it, or when it just left.
            let after = app.effective_multi_qr(term_width, term_height);
            if after != before {
                app.status_message = Some(format!(
                    "Info {}: grid {before} -> {after}.",
                    if app.options.no_info {
                        "hidden"
                    } else {
                        "shown"
                    }
                ));
            }
        }
        _ => {}
    }
    KeyOutcome::Continue
}

fn app_commit_jump(text: &str, app: &mut App, send_args: &SendArgs, file_name: &str) {
    if let Ok(n) = text.trim().parse::<usize>()
        && n >= 1
        && n <= app.chunks.len()
    {
        app.index = n - 1;
        state::save_progress(send_args.resume, file_name, app.index);
        app.status_message = None;
        return;
    }
    app.status_message = Some(format!("Invalid chunk number: {text:?}"));
}

fn app_commit_gap_fill(
    text: &str,
    app: &mut App,
    gap_fill: &mut Option<Vec<usize>>,
    gap_fill_cursor: &mut usize,
) {
    let indices = parse_index_list(text.trim(), app.chunks.len());
    if indices.is_empty() {
        app.status_message = Some("No valid indices parsed.".to_string());
        return;
    }
    *gap_fill_cursor = 0;
    *gap_fill = Some(indices);
    app.status_message = Some("Gap-fill mode active.".to_string());
}

/// Parses a comma/range list like "5,12-15,40" into 0-based indices,
/// clamped to `[0, total)`. New control (`G`, gap-fill mode) -- no TS
/// reference to port, designed fresh per the original feature request.
fn parse_index_list(s: &str, total: usize) -> Vec<usize> {
    let mut out = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((a, b)) = part.split_once('-') {
            if let (Ok(a), Ok(b)) = (a.trim().parse::<usize>(), b.trim().parse::<usize>()) {
                let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
                for n in lo..=hi {
                    if n >= 1 && n <= total {
                        out.push(n - 1);
                    }
                }
            }
        } else if let Ok(n) = part.parse::<usize>()
            && n >= 1
            && n <= total
        {
            out.push(n - 1);
        }
    }
    out
}

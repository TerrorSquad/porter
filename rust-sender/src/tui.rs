//! Full ratatui TUI: widget tree (QR grid, sidebar, status/input line),
//! app state, and top-level render dispatch. Replaces the old ANSI-string
//! `Renderer` -- the QR encoding itself (`renderer::build_qr_lines`) is
//! reused verbatim; only how the resulting lines get placed on screen
//! changes (ratatui `Buffer` cells instead of cursor-position escapes).

use ratatui::Frame;
use ratatui::buffer::Buffer;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style, Stylize};
use ratatui::text::Line;
use ratatui::widgets::{Block, Paragraph, Widget};

use crate::qrtypes::EccLevel;
use crate::renderer::build_qr_lines;

const GRID_GAP_X: u16 = 2;
const GRID_GAP_Y: u16 = 1;
const SIDEBAR_WIDTH: u16 = 32;

/// Text-entry state for `J` (jump-to-chunk) and `G` (gap-fill list) --
/// replaces the old blocking `stdin().read_line()` prompts with a real
/// status-line editor the event loop drives character-by-character.
pub enum InputMode {
    Normal,
    JumpToChunk(String),
    GapFillList(String),
}

pub struct RenderOptions {
    pub speed: f64,
    pub is_slideshow: bool,
    pub use_inverted: bool,
    pub ecc_level: EccLevel,
    pub multi_qr: Option<u32>,
    pub no_info: bool,
}

/// All sender state the UI reads. Owns what `Renderer` used to own
/// (`index`/`chunks`/`version`/`options`) plus the layout math that used to
/// live on `Renderer` as methods -- pure state/computation, no I/O, so it
/// moved here unchanged rather than being rewritten.
pub struct App {
    pub index: usize,
    pub chunks: Vec<String>,
    pub version: i32,
    // Stored but not currently rendered, mirroring the pre-TUI Renderer's
    // own fileName (also stored, also never shown) -- kept for parity and
    // future use (e.g. a window/status-bar title).
    #[allow(dead_code)]
    pub file_name: String,
    pub options: RenderOptions,
    pub input_mode: InputMode,
    pub countdown: Option<u8>,
    pub status_message: Option<String>,
    pub started_at: std::time::Instant,
    /// Times the slideshow has wrapped back to the first chunk. Only
    /// advanced by `advance_slideshow` in main.rs, never by manual
    /// next/prev -- manual scrubbing past the end isn't "a loop".
    pub loop_count: u64,
}

impl App {
    pub fn new(file_name: String, options: RenderOptions) -> Self {
        App {
            index: 0,
            chunks: Vec::new(),
            version: 2,
            file_name,
            options,
            input_mode: InputMode::Normal,
            countdown: None,
            status_message: None,
            started_at: std::time::Instant::now(),
            loop_count: 0,
        }
    }

    pub fn set_chunks(&mut self, chunks: Vec<String>, version: i32) {
        self.chunks = chunks;
        self.version = version;
        if self.index >= self.chunks.len() {
            self.index = 0;
        }
    }

    /// Scrub by `step` frames, clamped to the ends. Used by `Shift+←/→`,
    /// where overshooting to the far end is the point and wrapping would be
    /// disorienting -- plain next/prev wrap instead (see `move_next`).
    pub fn move_by(&mut self, step: i32) {
        if step >= 0 {
            self.index = (self.index + step as usize).min(self.chunks.len().saturating_sub(1));
        } else {
            self.index = self.index.saturating_sub((-step) as usize);
        }
    }

    /// Step `n` frames with wraparound, where `n` is however many codes are
    /// on screen. Clamping here left `→` dead at the last chunk with no way
    /// back to the first: the slideshow wraps (see `advance_slideshow`), so
    /// manual stepping wrapping too is what the user already expects.
    fn move_wrapping(&mut self, step: usize, forward: bool) {
        let len = self.chunks.len();
        if len == 0 {
            return;
        }
        let step = step.max(1) % len.max(1);
        self.index = if forward {
            (self.index + step) % len
        } else {
            (self.index + len - step) % len
        };
    }

    pub fn move_next(&mut self, term_width: u16, term_height: u16) {
        let step = self.effective_multi_qr(term_width, term_height) as usize;
        self.move_wrapping(step, true);
    }

    pub fn move_prev(&mut self, term_width: u16, term_height: u16) {
        let step = self.effective_multi_qr(term_width, term_height) as usize;
        self.move_wrapping(step, false);
    }

    fn qr_column_width(&self) -> u16 {
        let module_count = self.version * 4 + 17;
        (module_count + 3) as u16
    }

    fn qr_row_height(&self) -> u16 {
        (self.version * 2 + 10) as u16
    }

    /// Lays `n` codes out in the widest grid the terminal can take, rather
    /// than a square one.
    ///
    /// A QR is square but terminals are wide, and the QR *version* is chosen
    /// from terminal height alone -- so height is the scarce axis and width is
    /// usually going spare. A square grid demanded rows it could not have:
    /// `--multi=2` asked for 2x2 at 314x159 when a 1x2 at 314x79 fits an
    /// ordinary wide terminal, so it silently fell back to a single code and
    /// looked like a no-op. Filling columns first spends the axis that is
    /// actually free.
    /// Grid for `n` codes, preferring the layout that fits `term_width`.
    ///
    /// Columns are tried widest-first: a single row spends only width, which
    /// is the axis that is actually free, and taller grids are used only when
    /// the codes genuinely will not fit side by side.
    fn grid_dimensions_for(&self, n: u32, term_width: u16) -> (u16, u16, u16, u16) {
        let n = n.max(1) as u16;
        let mut chosen = (1u16, n);

        for cols in (1..=n).rev() {
            let rows = n.div_ceil(cols);
            let width = cols * self.qr_column_width() + (cols - 1) * GRID_GAP_X;
            if width <= term_width {
                chosen = (cols, rows);
                break;
            }
        }

        let (cols, rows) = chosen;
        let width = cols * self.qr_column_width() + (cols - 1) * GRID_GAP_X;
        let height = rows * self.qr_row_height() + (rows - 1) * GRID_GAP_Y;
        (cols, rows, width, height)
    }

    /// How many codes actually fit, given the *terminal* size. The bottom row
    /// is always the status line, so it's subtracted here rather than by each
    /// caller -- when only `render` did it, the navigation step (`move_next`)
    /// could disagree with the number of codes on screen and skip or repeat a
    /// frame at the size boundary.
    pub fn effective_multi_qr(&self, term_width: u16, term_height: u16) -> u32 {
        let grid_height = term_height.saturating_sub(1);
        let configured = self.options.multi_qr.unwrap_or(1);
        let mut n = configured;
        while n > 1 {
            let (_, _, width, height) = self.grid_dimensions_for(n, term_width);
            if width <= term_width && height <= grid_height {
                return n;
            }
            n -= 1;
        }
        1
    }
}

struct QrData {
    lines: Vec<String>,
    is_checksum: bool,
}

/// Renders the QR half-block grid at the top-left of `area`, matching the
/// old `render_multi_qr`'s grid math (same gaps, same cols/rows layout).
struct QrGridWidget<'a> {
    qr_data: &'a [QrData],
    cols: u16,
    use_inverted: bool,
}

impl Widget for QrGridWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let qr_width = self
            .qr_data
            .first()
            .and_then(|d| d.lines.first())
            .map(|l| l.chars().count() as u16)
            .unwrap_or(0);
        let max_qr_height = self
            .qr_data
            .iter()
            .map(|d| d.lines.len() as u16)
            .max()
            .unwrap_or(0);
        // `--invert`: swap fg/bg via ratatui Style, matching the old raw
        // `\x1b[7m` (reverse video) escape's visual effect without baking
        // ANSI bytes into the QR-line strings themselves (see
        // renderer::build_qr_lines's doc comment for why that would break).
        let style = if self.use_inverted {
            Style::default().add_modifier(Modifier::REVERSED)
        } else {
            Style::default()
        };

        for (q_idx, qr) in self.qr_data.iter().enumerate() {
            let col = q_idx as u16 % self.cols;
            let row = q_idx as u16 / self.cols;
            let x = area.x + col * (qr_width + GRID_GAP_X);
            let y = area.y + row * (max_qr_height + GRID_GAP_Y);

            for (line_idx, line) in qr.lines.iter().enumerate() {
                let ly = y + line_idx as u16;
                if ly >= area.y + area.height {
                    continue;
                }
                buf.set_string(x, ly, line, style);
            }
        }
    }
}

/// Bordered info panel: chunk/progress/version/ETA/ECC/controls. Same
/// fields as the old `render_sidebar`, styled via ratatui's `Style` instead
/// of raw ANSI codes -- this is the part of the UI where "real ratatui"
/// (bordered panel vs. bare cursor-positioned text) is most visible.
struct SidebarWidget<'a> {
    app: &'a App,
    primary_is_checksum: bool,
    codes_rendered: usize,
}

impl Widget for SidebarWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let block = Block::bordered().title(" Porter ");
        let inner = block.inner(area);
        block.render(area, buf);

        let progress =
            (((self.app.index + 1) as f64 / self.app.chunks.len() as f64) * 100.0).round() as i32;
        let multi_str = if self.codes_rendered > 1 {
            format!(" (×{})", self.codes_rendered)
        } else {
            String::new()
        };
        // The grid wraps past the end of the pool, so the range can too --
        // show it as `1550–8` rather than pretending it stopped at the last
        // chunk.
        let len = self.app.chunks.len().max(1);
        let end_chunk = (self.app.index + self.codes_rendered - 1) % len + 1;
        let chunk_range = if self.codes_rendered > 1 {
            format!("{}–{}", self.app.index + 1, end_chunk)
        } else {
            format!("{}", self.app.index + 1)
        };
        let eta = ((self.app.chunks.len() - self.app.index) as f64 * self.app.options.speed).round()
            as i64;
        let elapsed = format_duration(self.app.started_at.elapsed());

        let mut lines = vec![
            Line::from(vec![
                "📦 CHUNK: ".green().bold(),
                format!("{chunk_range} / {}{multi_str}", self.app.chunks.len()).into(),
            ]),
            Line::from(vec![
                "📊 PROG:  ".green().bold(),
                format!("{progress}%").into(),
            ]),
            Line::raw(""),
            Line::from(vec![
                "📏 VER:   ".yellow().bold(),
                format!("{}", self.app.version).into(),
            ]),
            Line::from(vec!["⏳ ETA:   ".yellow().bold(), format!("{eta}s").into()]),
            Line::from(vec!["🕐 TIME:  ".yellow().bold(), elapsed.into()]),
            Line::from(vec![
                "🔁 LOOPS: ".yellow().bold(),
                format!("{}", self.app.loop_count).into(),
            ]),
            if self.primary_is_checksum {
                Line::from("✓ CHECKSUM".magenta().bold())
            } else {
                Line::from(vec![
                    "🛡️  ECC:   ".magenta().bold(),
                    format!("{}", self.app.options.ecc_level).into(),
                ])
            },
            Line::raw(""),
            Line::from("🕹️  CONTROLS:".blue().bold()),
            Line::from("   Next:  [L]/[→]"),
            Line::from("   Back:  [H]/[←]"),
            Line::from("   Scrub: [Shift+←→]"),
            Line::from("   Jump:  [J]  Gap-fill: [G]"),
            Line::from("   Speed: [+]/[-]"),
            Line::from("   Grid:  [[]/[]]"),
            Line::from("   Info:  [I]  Auto: [S]"),
            Line::from("   Quit:  [Q]"),
        ];

        if let Some(n) = self.app.countdown {
            lines.push(Line::raw(""));
            lines.push(Line::from(format!("Resuming in {n}...").yellow().bold()));
        }

        Paragraph::new(lines).render(inner, buf);
    }
}

/// Bottom status/input line -- replaces the old blocking `read_line()`
/// prompts for `J`/`G` with a live, cancellable, backspace-able editor
/// rendered as part of the normal frame. Also carries the 3-2-1
/// slideshow-resume countdown when there's no sidebar to show it in
/// (`--no-info` or a too-narrow terminal) -- the sidebar is the normal
/// home for it (see `SidebarWidget`), this is the fallback so it's never
/// silently invisible.
struct StatusLineWidget<'a> {
    app: &'a App,
    show_countdown: bool,
}

impl Widget for StatusLineWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        if self.show_countdown
            && let Some(n) = self.app.countdown
        {
            Paragraph::new(Line::from(format!("Resuming in {n}...").yellow().bold()))
                .render(area, buf);
            return;
        }

        let line = match &self.app.input_mode {
            InputMode::Normal => match &self.app.status_message {
                Some(msg) => Line::from(msg.as_str()),
                None => Line::from("Ready. Press [Q] to quit, [S] to toggle slideshow.".dim()),
            },
            InputMode::JumpToChunk(buf_str) => Line::from(vec![
                format!("Jump to chunk (1-{}): ", self.app.chunks.len()).bold(),
                format!("{buf_str}█").into(),
            ]),
            InputMode::GapFillList(buf_str) => Line::from(vec![
                "Gap-fill list (e.g. 5,12-15,40): ".bold(),
                format!("{buf_str}█").into(),
            ]),
        };
        Paragraph::new(line).render(area, buf);
    }
}

struct TooSmallWidget {
    term_width: u16,
    term_height: u16,
    min_width: u16,
    min_height: u16,
}

impl Widget for TooSmallWidget {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let lines = vec![
            Line::from("Error: Terminal too small".red().bold()),
            Line::from(format!(
                "Current: {}×{}, Minimum: {}×{}",
                self.term_width, self.term_height, self.min_width, self.min_height
            )),
        ];
        Paragraph::new(lines).render(area, buf);
    }
}

struct NoContentWidget;

impl Widget for NoContentWidget {
    fn render(self, area: Rect, buf: &mut Buffer) {
        Paragraph::new("No content to display.").render(area, buf);
    }
}

/// Shown when a chunk's payload doesn't fit the chosen QR version/ECC --
/// e.g. binary content read as lossy UTF-8 inflated past its expected byte
/// size (see renderer::build_qr_lines's doc comment). Surfaced on screen
/// instead of crashing the process; the slideshow can still move past this
/// one bad frame via the normal next/prev controls.
struct EncodeErrorWidget<'a> {
    message: &'a str,
}

impl Widget for EncodeErrorWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let lines = vec![
            Line::from("Error: QR encoding failed for this chunk".red().bold()),
            Line::from(self.message),
            Line::from(
                "Try a smaller --multi, higher terminal size, or --base64 for binary input.".dim(),
            ),
        ];
        Paragraph::new(lines).render(area, buf);
    }
}

/// Top-level render dispatch: builds the layout (QR grid + optional
/// sidebar, matching the old side-by-side-or-below fallback) and renders
/// each region's widget. Called once per frame from the event loop in
/// `main.rs`, wrapped in DEC synchronized-output markers there (ratatui has
/// no built-in support for that -- see docs/adr/0004 and this session's
/// plan for why the markers are written directly around `terminal.draw`).
pub fn render(frame: &mut Frame, app: &App) {
    let area = frame.area();
    const MIN_WIDTH: u16 = 40;
    const MIN_HEIGHT: u16 = 24;

    if area.width < MIN_WIDTH || area.height < MIN_HEIGHT {
        frame.render_widget(
            TooSmallWidget {
                term_width: area.width,
                term_height: area.height,
                min_width: MIN_WIDTH,
                min_height: MIN_HEIGHT,
            },
            area,
        );
        return;
    }

    if app.chunks.is_empty() || app.index >= app.chunks.len() {
        frame.render_widget(NoContentWidget, area);
        return;
    }

    // effective_multi_qr subtracts the status row itself, so pass the full
    // area height -- fitting against the full height was overcommitting by
    // exactly one row, which is what made 114x26 clip where 114x27 was fine.
    let multi_qr = app.effective_multi_qr(area.width, area.height);
    let codes_to_render = (multi_qr as usize).min(app.chunks.len());
    // Same width bound the fitter used, so the renderer lays the codes out in
    // the grid that was actually chosen rather than a different one.
    let (cols, _rows, grid_width, grid_height) =
        app.grid_dimensions_for(codes_to_render as u32, area.width);

    let mut qr_data = Vec::with_capacity(codes_to_render);
    for offset in 0..codes_to_render {
        // Wrap, matching move_next: near the end of the pool the grid keeps
        // showing `multi` codes by continuing from the start, rather than
        // shrinking to a single code for the last frame.
        let idx = (app.index + offset) % app.chunks.len();
        let payload = &app.chunks[idx];
        let lines = match build_qr_lines(payload, app.options.ecc_level, app.version) {
            Ok(lines) => lines,
            Err(e) => {
                frame.render_widget(
                    EncodeErrorWidget {
                        message: &format!("Chunk {}: {e}", idx + 1),
                    },
                    area,
                );
                return;
            }
        };
        qr_data.push(QrData {
            lines,
            is_checksum: payload.starts_with("CHECKSUM|"),
        });
    }
    let primary_is_checksum = qr_data.first().map(|d| d.is_checksum).unwrap_or(false);

    // Reserve the bottom line for status/input, matching the old sidebar's
    // "fits beside, else below, else hidden" fallback for the rest.
    let [main_area, status_area] = Layout::new(
        Direction::Vertical,
        [Constraint::Min(0), Constraint::Length(1)],
    )
    .areas(area);

    let show_sidebar = !app.options.no_info;
    let sidebar_fits_beside = grid_width + GRID_GAP_X + SIDEBAR_WIDTH <= main_area.width;
    let sidebar_fits_below = grid_height + GRID_GAP_Y + 3 <= main_area.height;

    let (qr_area, sidebar_area) = if show_sidebar && sidebar_fits_beside {
        let [qr, sidebar] = Layout::new(
            Direction::Horizontal,
            [Constraint::Min(0), Constraint::Length(SIDEBAR_WIDTH)],
        )
        .areas(main_area);
        (qr, Some(sidebar))
    } else if show_sidebar && sidebar_fits_below {
        let [qr, sidebar] = Layout::new(
            Direction::Vertical,
            [Constraint::Length(grid_height), Constraint::Min(0)],
        )
        .areas(main_area);
        (qr, Some(sidebar))
    } else {
        (main_area, None)
    };

    frame.render_widget(
        QrGridWidget {
            qr_data: &qr_data,
            cols,
            use_inverted: app.options.use_inverted,
        },
        qr_area,
    );

    let countdown_shown_in_sidebar = sidebar_area.is_some();
    if let Some(sidebar_area) = sidebar_area {
        frame.render_widget(
            SidebarWidget {
                app,
                primary_is_checksum,
                codes_rendered: codes_to_render,
            },
            sidebar_area,
        );
    }

    frame.render_widget(
        StatusLineWidget {
            app,
            show_countdown: !countdown_shown_in_sidebar,
        },
        status_area,
    );
}

/// Formats a duration as `H:MM:SS`, or `M:SS` under an hour -- matches the
/// existing ETA field's plain-seconds simplicity without needing a duration
/// formatting crate for one sidebar line.
fn format_duration(d: std::time::Duration) -> String {
    let total_secs = d.as_secs();
    let hours = total_secs / 3600;
    let minutes = (total_secs % 3600) / 60;
    let seconds = total_secs % 60;
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}

#[cfg(test)]
mod grid_tests {
    use super::*;
    use crate::qrtypes::EccLevel;

    fn app_at_version(version: i32) -> App {
        let mut app = App::new(
            "test".to_string(),
            RenderOptions {
                speed: 0.5,
                is_slideshow: false,
                use_inverted: false,
                ecc_level: EccLevel::L,
                multi_qr: Some(4),
                no_info: true,
            },
        );
        app.set_chunks(vec!["x".to_string(); 16], version);
        app
    }

    /// A QR is square but terminals are wide, and the version comes from
    /// terminal *height*, so height is scarce and width is usually spare. A
    /// square grid asked for rows it could not have -- `--multi=2` wanted 2x2
    /// when a 1x2 fits -- and silently degraded to a single code.
    #[test]
    fn prefers_a_single_row_when_the_terminal_is_wide() {
        let app = app_at_version(34);
        let (cols, rows, ..) = app.grid_dimensions_for(2, 400);
        assert_eq!((cols, rows), (2, 1), "two codes should sit side by side");
    }

    #[test]
    fn stacks_only_when_the_codes_will_not_fit_side_by_side() {
        let app = app_at_version(34);
        // One v34 code is ~156 columns; 200 has no room for a second.
        let (cols, rows, ..) = app.grid_dimensions_for(2, 200);
        assert_eq!((cols, rows), (1, 2));
    }

    /// `→` at the last chunk used to clamp, leaving the user stuck with no
    /// way back to chunk 1 -- the slideshow wrapped but manual stepping did
    /// not.
    #[test]
    fn stepping_past_the_last_chunk_wraps_to_the_first() {
        let mut app = app_at_version(2);
        app.options.multi_qr = Some(1);
        let last = app.chunks.len() - 1;
        app.index = last;
        app.move_next(80, 40);
        assert_eq!(app.index, 0, "next at the last chunk should wrap to first");
        app.move_prev(80, 40);
        assert_eq!(
            app.index, last,
            "prev at the first chunk should wrap to last"
        );
    }

    /// Shift-scrub is deliberately still clamped: overshooting to the far end
    /// is the point, and wrapping there would be disorienting.
    #[test]
    fn shift_scrub_still_clamps_at_the_ends() {
        let mut app = app_at_version(2);
        app.move_by(100);
        assert_eq!(app.index, app.chunks.len() - 1);
        app.move_by(-100);
        assert_eq!(app.index, 0);
    }

    /// The bottom row is always the status line. Fitting the grid against the
    /// full terminal height overcommitted by one row, so a terminal one row
    /// short of comfortable picked a grid that then clipped.
    #[test]
    fn the_status_row_is_excluded_from_the_grid_height_budget() {
        let app = app_at_version(10);
        // One v10 code is 30 rows tall; 2 stacked need 61 with the gap.
        let exactly_enough = app.qr_row_height() * 2 + GRID_GAP_Y;
        // Narrow enough that 2 codes must stack rather than sit side by side.
        let narrow = app.qr_column_width() + 1;
        assert_eq!(
            app.effective_multi_qr(narrow, exactly_enough),
            1,
            "no room once the status row is reserved"
        );
        assert_eq!(
            app.effective_multi_qr(narrow, exactly_enough + 1),
            2,
            "one more row makes the stacked grid fit"
        );
    }

    #[test]
    fn a_wide_terminal_actually_gets_multiple_codes() {
        let app = app_at_version(34);
        // The old square-grid math returned 1 here, making --multi a no-op.
        assert_eq!(app.effective_multi_qr(400, 90), 2);
        assert_eq!(app.effective_multi_qr(200, 90), 1);
    }
}

#[cfg(test)]
mod dropdown_tests {
    use super::*;

    fn app_at(version: i32, requested: u32) -> App {
        let mut app = App::new(
            "f".to_string(),
            RenderOptions {
                speed: 0.2,
                is_slideshow: false,
                use_inverted: false,
                ecc_level: EccLevel::L,
                multi_qr: Some(requested),
                no_info: true,
            },
        );
        app.set_chunks(vec!["x".to_string(); 64], version);
        app
    }

    /// `--multi=auto` used to ask for a fixed 4, which a wide terminal
    /// under-fills: at version 6 a 218x56 grid area takes 4 across *and* 2
    /// down. Asking for the ceiling instead lets the fit check use both axes.
    #[test]
    fn auto_fills_a_wide_terminal_in_two_dimensions() {
        // 218 cols is the screenshot's ~250 minus the 32-col sidebar.
        let old_request = app_at(6, 4).effective_multi_qr(218, 56);
        let new_request = app_at(6, 64).effective_multi_qr(218, 56);
        assert_eq!(old_request, 4, "the old fixed request only filled one row");
        assert_eq!(new_request, 8, "asking for the ceiling fills 4x2");
    }

    /// The ceiling request must still collapse to 1 where nothing else fits,
    /// or a small terminal would render a broken grid.
    #[test]
    fn auto_still_collapses_to_one_when_narrow() {
        let app = app_at(20, 64);
        assert_eq!(app.effective_multi_qr(90, 50), 1);
    }
}

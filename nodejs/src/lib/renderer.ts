import qrcode from 'qrcode-generator';
import { FEATURE_INTERACTIVE_CONTROLS, FEATURE_INVERT, FEATURE_MULTI_QR } from './features.js';

const QR_WHITE_ALL = '█';
const QR_WHITE_BLACK = '▀';
const QR_BLACK_WHITE = '▄';
const QR_BLACK_ALL = ' ';

// Synchronized output (DEC private mode 2026): tells the terminal to buffer
// everything between BSU and ESU and composite it in a single repaint. A frame
// can be several KB, so when the PTY buffer fills (after a handful of frames)
// the OS splits our single write() across flushes — without synchronization the
// terminal paints the cleared (blank) lines before the QR bytes arrive, which a
// camera/eye sees as a black flash. Terminals that don't support 2026 ignore
// these private-mode sequences harmlessly.
const SYNC_BEGIN = '\x1b[?2026h';
const SYNC_END = '\x1b[?2026l';

function repeatCell(cell: string, count: number): string {
  return count > 0 ? cell.repeat(count) : '';
}

function buildQrLines(
  payload: string,
  eccLevel: 'L' | 'M' | 'Q' | 'H',
  useInverted: boolean,
): string[] {
  const qr = qrcode(0, eccLevel);
  qr.addData(payload, 'Byte');
  qr.make();

  const moduleCount = qr.getModuleCount();
  const rows: boolean[][] = Array.from({ length: moduleCount }, (_, row) =>
    Array.from({ length: moduleCount }, (_, col) => qr.isDark(row, col)),
  );

  if (moduleCount % 2 === 1) {
    rows.push(Array.from({ length: moduleCount }, () => false));
  }

  const lines: string[] = [];
  const borderTop = repeatCell(QR_BLACK_WHITE, moduleCount + 3);
  const borderBottom = repeatCell(QR_WHITE_BLACK, moduleCount + 3);
  lines.push(borderTop);

  for (let row = 0; row < moduleCount; row += 2) {
    let line = QR_WHITE_ALL;

    for (let col = 0; col < moduleCount; col++) {
      const top = rows[row]?.[col] ?? false;
      const bottom = rows[row + 1]?.[col] ?? false;

      if (!top && !bottom) {
        line += QR_WHITE_ALL;
      } else if (!top && bottom) {
        line += QR_WHITE_BLACK;
      } else if (top && !bottom) {
        line += QR_BLACK_WHITE;
      } else {
        line += QR_BLACK_ALL;
      }
    }

    line += QR_WHITE_ALL;
    lines.push(line);
  }

  if (moduleCount % 2 === 0) {
    lines.push(borderBottom);
  }

  if (!(FEATURE_INVERT && useInverted)) {
    return lines;
  }

  return lines.map((line) => `\x1b[7m${line}\x1b[0m`);
}

export interface RenderOptions {
  speed: number;
  isSlideshow: boolean;
  useInverted: boolean;
  eccLevel: 'L' | 'M' | 'Q' | 'H';
  showPartProgress?: boolean;
  totalParts?: number;
  multiQr?: number; // Number of QR codes to display in a grid (1-4)
  noInfo?: boolean; // Always hide the info sidebar
}

interface QrData {
  lines: string[];
  height: number;
  payload: string;
  isChecksum: boolean;
}

interface SidebarOrigin {
  row: number;
  col: number;
}

const GRID_GAP_X = 2;
const GRID_GAP_Y = 1;
const SIDEBAR_WIDTH = 30;

export class Renderer {
  public index: number = 0;
  public chunks: string[] = [];
  public version: number = 2; // Default
  public fileName: string;
  public options: RenderOptions;
  private lastHeight: number = 0; // Track previous frame height to clear properly

  constructor(fileName: string, options: RenderOptions) {
    this.fileName = fileName;
    this.options = options;
  }

  public setChunks(chunks: string[], version: number) {
    this.chunks = chunks;
    this.version = version;
    // bounds check
    if (this.index >= this.chunks.length) {
      this.index = 0;
    }
  }

  public moveNext() {
    const step = this.effectiveMultiQr();
    this.index = Math.min(this.chunks.length - 1, this.index + step);
  }

  public movePrev() {
    const step = this.effectiveMultiQr();
    this.index = Math.max(0, this.index - step);
  }

  /** Width (in terminal columns) of a single QR code at the current version. */
  private qrColumnWidth(): number {
    const moduleCount = this.version * 4 + 17;
    return moduleCount + 3;
  }

  /** Height (in terminal rows) of a single QR code at the current version. */
  private qrRowHeight(): number {
    return this.version * 2 + 10;
  }

  /** Grid layout (columns × rows, and overall size) for displaying `n` QR codes. */
  private gridDimensions(n: number): { cols: number; rows: number; width: number; height: number } {
    const cols = Math.max(1, Math.ceil(Math.sqrt(n)));
    const rows = Math.max(1, Math.ceil(n / cols));
    const width = cols * this.qrColumnWidth() + (cols - 1) * GRID_GAP_X;
    const height = rows * this.qrRowHeight() + (rows - 1) * GRID_GAP_Y;
    return { cols, rows, width, height };
  }

  /** Number of QR codes actually rendered per frame, given multiQr and terminal size. */
  private effectiveMultiQr(): number {
    const configured = FEATURE_MULTI_QR ? this.options.multiQr || 1 : 1;
    const termWidth = process.stdout.columns || 80;
    const termHeight = process.stdout.rows || 24;

    for (let n = configured; n > 1; n--) {
      const { width, height } = this.gridDimensions(n);
      if (width <= termWidth && height <= termHeight) {
        return n;
      }
    }
    return 1;
  }

  /**
   * Writes a fully-built frame in one go, wrapped in synchronized-output
   * markers so the terminal repaints it atomically even if the OS splits the
   * underlying write across flushes (the cause of the periodic black flash).
   */
  private flush(out: string[]) {
    process.stdout.write(SYNC_BEGIN + out.join('') + SYNC_END);
  }

  public draw() {
    // Build the whole frame in memory and flush it with a single write.
    // Writing line-by-line lets the terminal repaint mid-frame, which a
    // camera can capture as a torn/half-updated QR code and fail to decode.
    const out: string[] = [];

    // Just go home without clearing to avoid flashing
    // Lines will be cleared as they're overwritten
    out.push('\x1b[H');

    if (!this.chunks.length || !this.chunks[this.index]) {
      out.push('\x1b[2KNo content to display.\n');
      this.flush(out);
      return;
    }

    // renderMultiQr clears the full frame area (max of current/previous/terminal
    // height) before drawing, so no separate pre-clear pass is needed here.

    // Determine how many QR codes to render (multiQr mode), capped to however
    // many fit in a grid at the current terminal size.
    const multiQr = this.effectiveMultiQr();
    const codesToRender = Math.min(multiQr, this.chunks.length - this.index);
    const qrIndices = Array.from({ length: codesToRender }, (_, i) => this.index + i);

    const qrDataList: QrData[] = [];
    let maxQrHeight = 0;

    for (const idx of qrIndices) {
      const payload = this.chunks[idx];

      try {
        const qrLines = buildQrLines(payload, this.options.eccLevel, this.options.useInverted);
        const qrHeight = qrLines.length;
        maxQrHeight = Math.max(maxQrHeight, qrHeight);

        qrDataList.push({
          lines: qrLines,
          height: qrHeight,
          payload,
          isChecksum: payload.startsWith('CHECKSUM|'),
        });
      } catch (e) {
        out.push('\x1b[2J\x1b[H');
        out.push('\x1b[1;31mError generating QR code:\x1b[0m\n');
        out.push(`${e}\n`);
        this.flush(out);
        return;
      }
    }

    out.push(this.renderMultiQr(qrDataList, maxQrHeight));
    this.flush(out);
  }

  private renderMultiQr(qrDataList: QrData[], maxQrHeight: number): string {
    const out: string[] = [];

    // Check for minimum screen size
    const minWidth = 40;
    const minHeight = 24;
    const termWidth = process.stdout.columns || 80;
    const termHeight = process.stdout.rows || 24;

    if (termWidth < minWidth || termHeight < minHeight) {
      out.push('\x1b[H\x1b[2J');
      out.push('\x1b[1;31mError: Terminal too small\x1b[0m\n');
      out.push(`Current: ${termWidth}×${termHeight}, Minimum: ${minWidth}×${minHeight}\n`);
      return out.join('');
    }

    // Safely get QR width with fallback
    const firstLine = qrDataList[0]?.lines?.[0];
    if (!firstLine) {
      out.push('\x1b[H\x1b[2J');
      out.push('\x1b[1;31mError: Failed to generate QR code\x1b[0m\n');
      return out.join('');
    }

    const qrWidth = firstLine.length;
    const { cols, width: gridWidth, height: gridHeight } = this.gridDimensions(qrDataList.length);
    const sidebarLines = FEATURE_INTERACTIVE_CONTROLS ? 17 : 8;

    // Place the info panel beside or below the QR grid - wherever it fits
    // without overlapping a QR code. If it fits nowhere, hide it entirely.
    let sidebarOrigin: SidebarOrigin | null = null;
    if (!this.options.noInfo) {
      if (gridWidth + GRID_GAP_X + SIDEBAR_WIDTH <= termWidth) {
        sidebarOrigin = { row: 1, col: gridWidth + GRID_GAP_X + 1 };
      } else if (gridHeight + GRID_GAP_Y + sidebarLines <= termHeight) {
        sidebarOrigin = { row: gridHeight + GRID_GAP_Y + 1, col: 1 };
      }
    }

    const contentHeight = Math.max(
      gridHeight,
      sidebarOrigin ? sidebarOrigin.row + sidebarLines - 1 : 0,
    );
    const totalHeight = Math.max(contentHeight, this.lastHeight, termHeight);
    this.lastHeight = contentHeight; // Remember for next frame

    for (let i = 0; i < totalHeight; i++) {
      out.push(`\x1b[${i + 1};1H\x1b[2K`);
    }

    // Render the QR grid.
    for (let qIdx = 0; qIdx < qrDataList.length; qIdx++) {
      const qrData = qrDataList[qIdx];
      const col = qIdx % cols;
      const row = Math.floor(qIdx / cols);
      const colPos = 1 + col * (qrWidth + GRID_GAP_X);
      const rowPos = 1 + row * (maxQrHeight + GRID_GAP_Y);

      for (let lineIdx = 0; lineIdx < qrData.lines.length; lineIdx++) {
        out.push(`\x1b[${rowPos + lineIdx};${colPos}H${qrData.lines[lineIdx]}`);
      }
    }

    // "Active" indicator for slideshow mode, top-right corner of the terminal.
    // Only drawn when it has room to the right of the grid so it can never
    // land on top of a QR code.
    if (this.options.isSlideshow && termWidth > gridWidth) {
      out.push(`\x1b[1;${termWidth}H\x1b[31m●\x1b[0m`);
    }

    if (sidebarOrigin) {
      out.push(this.renderSidebar(qrDataList, sidebarOrigin, sidebarLines));
    }

    // Move cursor to bottom
    out.push(`\x1b[${process.stdout.rows};1H`);

    return out.join('');
  }

  private renderSidebar(qrDataList: QrData[], origin: SidebarOrigin, sidebarLines: number): string {
    const out: string[] = [];
    const primary = qrDataList[0];
    const progress = Math.round(((this.index + 1) / this.chunks.length) * 100);
    const lines: string[] = [];

    const multiStr = FEATURE_MULTI_QR && qrDataList.length > 1 ? ` (×${qrDataList.length})` : '';
    const endChunk = Math.min(this.index + qrDataList.length, this.chunks.length);
    const chunkRange =
      qrDataList.length > 1 ? `${this.index + 1}–${endChunk}` : `${this.index + 1}`;
    lines[2] = `\x1b[1;32m📦 CHUNK:\x1b[0m ${chunkRange} / ${this.chunks.length}${multiStr}`;
    lines[3] = `\x1b[1;32m📊 PROG: \x1b[0m${progress}%`;

    lines[5] = `\x1b[1;33m📏 VER:  \x1b[0m${this.version}`;
    lines[6] = `\x1b[1;33m⏳ ETA:  \x1b[0m${Math.round((this.chunks.length - this.index) * this.options.speed)}s`;
    lines[7] = primary.isChecksum
      ? `\x1b[1;35m✓ CHECKSUM\x1b[0m`
      : `\x1b[1;35m🛡️  ECC:  \x1b[0m${this.options.eccLevel}`;

    if (FEATURE_INTERACTIVE_CONTROLS) {
      lines[9] = `\x1b[1;34m🕹️  CONTROLS:\x1b[0m`;
      lines[10] = `   Next:  \x1b[7m L \x1b[0m or \x1b[7m → \x1b[0m`;
      lines[11] = `   Back:  \x1b[7m H \x1b[0m or \x1b[7m ← \x1b[0m`;
      lines[12] = `   Auto:  \x1b[7m S \x1b[0m (Toggle)`;
      lines[13] = `   Quit:  \x1b[7m Q \x1b[0m`;
    }

    for (let i = 0; i < sidebarLines; i++) {
      const text = lines[i];
      if (text) {
        out.push(`\x1b[${origin.row + i};${origin.col}H${text}\x1b[K`);
      }
    }

    return out.join('');
  }
}

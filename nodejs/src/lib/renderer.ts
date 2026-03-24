import qrcode from 'qrcode-generator';
import { FEATURE_INTERACTIVE_CONTROLS, FEATURE_INVERT, FEATURE_MULTI_QR } from './features.js';

const QR_WHITE_ALL = '█';
const QR_WHITE_BLACK = '▀';
const QR_BLACK_WHITE = '▄';
const QR_BLACK_ALL = ' ';

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
  multiQr?: number; // Number of QR codes to display side-by-side (1-4)
}

export class Renderer {
  public index: number = 0;
  public chunks: string[] = [];
  public version: number = 2; // Default
  public fileName: string;
  public options: RenderOptions;
  private lastHeight: number = 0; // Track previous QR height to clear properly

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
    const step = FEATURE_MULTI_QR ? this.options.multiQr || 1 : 1;
    this.index = Math.min(this.chunks.length - 1, this.index + step);
  }

  public movePrev() {
    const step = FEATURE_MULTI_QR ? this.options.multiQr || 1 : 1;
    this.index = Math.max(0, this.index - step);
  }

  public draw() {
    // Just go home without clearing to avoid flashing
    // Lines will be cleared as they're overwritten
    process.stdout.write('\x1b[H');

    if (!this.chunks.length || !this.chunks[this.index]) {
      process.stdout.write('\x1b[2KNo content to display.\n');
      return;
    }

    // Clear previous QR area (first lastHeight lines) to prevent glitches
    // Only do this if we have previous height data
    if (this.lastHeight > 0) {
      for (let i = 0; i < this.lastHeight; i++) {
        process.stdout.write(`\x1b[${i + 1};1H\x1b[2K`);
      }
    }

    // Determine how many QR codes to render (multiQr mode)
    const multiQr = FEATURE_MULTI_QR ? this.options.multiQr || 1 : 1;
    const codesToRender = Math.min(multiQr, this.chunks.length - this.index);
    const qrIndices = Array.from({ length: codesToRender }, (_, i) => this.index + i);

    const qrDataList: Array<{
      lines: string[];
      height: number;
      payload: string;
      isChecksum: boolean;
    }> = [];
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
        process.stdout.write('\x1b[2J\x1b[H');
        process.stdout.write('\x1b[1;31mError generating QR code:\x1b[0m\n');
        process.stdout.write(`${e}\n`);
        return;
      }
    }

    this.renderMultiQr(qrDataList, maxQrHeight);
  }

  private renderMultiQr(
    qrDataList: Array<{ lines: string[]; height: number; payload: string; isChecksum: boolean }>,
    maxQrHeight: number,
  ) {
    // Check for minimum screen size
    const minWidth = 40;
    const minHeight = 24;
    const termWidth = process.stdout.columns || 80;
    const termHeight = process.stdout.rows || 24;

    if (termWidth < minWidth || termHeight < minHeight) {
      process.stdout.write('\x1b[H\x1b[2J');
      process.stdout.write('\x1b[1;31mError: Terminal too small\x1b[0m\n');
      process.stdout.write(
        `Current: ${termWidth}×${termHeight}, Minimum: ${minWidth}×${minHeight}\n`,
      );
      return;
    }

    // Safely get QR width with fallback
    const firstLine = qrDataList[0]?.lines?.[0];
    if (!firstLine) {
      process.stdout.write('\x1b[H\x1b[2J');
      process.stdout.write('\x1b[1;31mError: Failed to generate QR code\x1b[0m\n');
      return;
    }

    const sidebarHeight = FEATURE_INTERACTIVE_CONTROLS ? 17 : 8;
    // Clear to at least the max of: current QR height or previous height or sidebar height
    const totalHeight = Math.max(maxQrHeight, this.lastHeight, sidebarHeight, termHeight);
    this.lastHeight = maxQrHeight; // Remember for next frame

    // Calculate column positions for each QR code (assume ~29 chars per small QR)
    const qrWidth = firstLine.length;
    const gap = 2; // Spacing between QR codes
    const colPositions = qrDataList.map((_, i) => 1 + i * (qrWidth + gap));

    // Get primary chunk info (first one)
    const primary = qrDataList[0];
    const progress = Math.round(((this.index + 1) / this.chunks.length) * 100);

    for (let i = 0; i < totalHeight; i++) {
      // Position cursor at start of line and clear the entire line
      process.stdout.write(`\x1b[${i + 1};1H\x1b[2K`);

      // Render all QR codes side-by-side
      for (let qIdx = 0; qIdx < qrDataList.length; qIdx++) {
        const qrData = qrDataList[qIdx];
        const colPos = colPositions[qIdx];

        if (i < qrData.height) {
          process.stdout.write(`\x1b[${i + 1};${colPos}H${qrData.lines[i]}`);
        }
      }

      // Prepare Sidebar Content (positioned after all QR codes)
      const lastQrWidth = qrDataList[qrDataList.length - 1]?.lines?.[0]?.length || 0;
      const sidebarCol = Math.min(
        colPositions[qrDataList.length - 1] + lastQrWidth + 4,
        termWidth - 30,
      );
      let sidebarText = '';

      if (i === 1) sidebarText = `\x1b[1;36m📄 FILE: \x1b[0m${this.fileName}`;
      if (i === 2) {
        const multiStr =
          FEATURE_MULTI_QR && qrDataList.length > 1 ? ` (×${qrDataList.length})` : '';
        const endChunk = Math.min(this.index + qrDataList.length, this.chunks.length);
        const chunkRange =
          qrDataList.length > 1 ? `${this.index + 1}–${endChunk}` : `${this.index + 1}`;
        sidebarText = `\x1b[1;32m📦 CHUNK:\x1b[0m ${chunkRange} / ${this.chunks.length}${multiStr}`;
      }
      if (i === 3) sidebarText = `\x1b[1;32m📊 PROG: \x1b[0m${progress}%`;

      if (i === 5) sidebarText = `\x1b[1;33m📏 VER:  \x1b[0m${this.version}`;
      if (i === 6)
        sidebarText = `\x1b[1;33m⏳ ETA:  \x1b[0m${Math.round((this.chunks.length - this.index) * this.options.speed)}s`;
      if (i === 7) {
        if (primary.isChecksum) {
          sidebarText = `\x1b[1;35m✓ CHECKSUM\x1b[0m`;
        } else {
          sidebarText = `\x1b[1;35m🛡️  ECC:  \x1b[0m${this.options.eccLevel}`;
        }
      }

      if (FEATURE_INTERACTIVE_CONTROLS) {
        if (i === 9) sidebarText = `\x1b[1;34m🕹️  CONTROLS:\x1b[0m`;
        if (i === 10) sidebarText = `   Next:  \x1b[7m L \x1b[0m or \x1b[7m → \x1b[0m`;
        if (i === 11) sidebarText = `   Back:  \x1b[7m H \x1b[0m or \x1b[7m ← \x1b[0m`;
        if (i === 12) sidebarText = `   Auto:  \x1b[7m S \x1b[0m (Toggle)`;
        if (i === 13) sidebarText = `   Quit:  \x1b[7m Q \x1b[0m`;
      }

      if (i === 15) {
        if (this.options.isSlideshow) {
          sidebarText = `\x1b[5;31m● STREAMING ACTIVE\x1b[0m`;
        } else {
          sidebarText = '';
        }
      }

      // Print Sidebar if exists, or clear line segment if inside sidebar zone
      if (sidebarText) {
        process.stdout.write(`\x1b[${i + 1};${sidebarCol}H${sidebarText}\x1b[K`);
      } else if (i < sidebarHeight) {
        // Clear sidebar area for lines without text
        process.stdout.write(`\x1b[${i + 1};${sidebarCol}H\x1b[K`);
      }
    }

    // Move cursor to bottom
    process.stdout.write(`\x1b[${process.stdout.rows};1H`);
  }
}

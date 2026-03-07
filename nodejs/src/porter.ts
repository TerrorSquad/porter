#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import tty from 'tty';
import crypto from 'crypto';
import { Chunker } from './lib/chunker';
import { Renderer } from './lib/renderer';
import { StateManager } from './lib/state';

// --- Helper: Parse Flags ---
const args = process.argv.slice(2);
const flags = Object.fromEntries(
  args.filter(a => a.startsWith('--')).map(a => {
    const parts = a.split('=');
    return [parts[0], parts[1] || 'true'];
  })
);

runSender();

function runSender() {
  const inputFiles = args.filter(a => !a.startsWith('--')); // All non-flag args are files
  const checksumFile = flags['--verify'] || '';
  const splitAware = flags['--split-aware'] === 'true';

  // --- Input Handling ---
  let content: Buffer;
  let fileName = 'stream.txt';
  let totalParts = 1;
  let providedChecksum = '';

  if (!process.stdin.isTTY && inputFiles.length === 0) {
    // Read from Stdin
    try {
      content = fs.readFileSync(0); // fd 0 is stdin
      fileName = 'stdin-stream';
    } catch (e) {
      console.error("Error reading from stdin:", e);
      process.exit(1);
    }
  } else if (inputFiles.length > 0) {
    // Handle multiple files (e.g., .part001.txt, .part002.txt, .partaa, .partab)
    const buffers: Buffer[] = [];
    const firstFile = inputFiles[0];
    // Support both numeric (.part001) and alphabetic (.partaa) naming
    const fileNameOnly = path.basename(firstFile);
    const baseName = fileNameOnly.replace(/\.part(?:\d+|[a-z]{2})$/, '');

    // If split-aware or file matches pattern, detect all .partXXX files and sort them
    if (splitAware || /\.part(?:\d+|[a-z]{2})$/.test(fileNameOnly)) {
      const dir = path.dirname(firstFile) || '.';
      const allFiles = fs.readdirSync(dir);
      const partFiles = allFiles
        .filter(f => f.includes(baseName) && /\.part(?:\d+|[a-z]{2})$/.test(f))
        .sort((a, b) => {
          // Handle both numeric (001, 002) and alphabetic (aa, ab, ac) part suffixes
          const numMatchA = a.match(/\.part(\d+)$/);
          const numMatchB = b.match(/\.part(\d+)$/);
          if (numMatchA && numMatchB) {
            // Both numeric: sort by number
            return parseInt(numMatchA[1]) - parseInt(numMatchB[1]);
          }
          // Otherwise alphabetic: sort lexicographically (aa < ab < ac)
          return a.localeCompare(b);
        });

      totalParts = partFiles.length;

      // Read all parts in order
      for (const file of partFiles) {
        const filePath = path.join(dir, file);
        try {
          buffers.push(fs.readFileSync(filePath));
        } catch (e) {
          console.error(`Error reading file ${file}:`, e);
          process.exit(1);
        }
      }

      fileName = baseName.endsWith('.tar.xz.enc') ? baseName : baseName + '.enc';
      content = Buffer.concat(buffers);

      // Try to read checksum file if it exists
      const checksumPath = baseName + '.sha256';
      if (fs.existsSync(checksumPath)) {
        try {
          providedChecksum = fs.readFileSync(checksumPath, 'utf-8').split('  ')[0];
        } catch (e) {
          // Ignore if we can't read it
        }
      }
    } else {
      // Single file mode
      const filePath = firstFile;
      if (!fs.existsSync(filePath)) {
        console.error(`Error: File not found: ${filePath}`);
        process.exit(1);
      }
      content = fs.readFileSync(filePath);
      fileName = path.basename(filePath);
    }
  } else {
    // Config & Usage
    console.log("\x1b[1mQR DATA PORTER\x1b[0m");
    console.log("Usage:");
    console.log("  porter <file> [options]");
    console.log("  porter <file.part*.txt|file.partaa|...> [options]");
    console.log("  echo 'data' | porter [options]");
    console.log("\nOptions:");
    console.log("  --slideshow       Start in slideshow mode");
    console.log("  --base64          Enable Base64 encoding (for binary files)");
    console.log("  --verify=<file>   Verify against SHA256 checksum file");
    console.log("  --split-aware     Auto-detect and concatenate .part*.txt or .partaa files");
    console.log("  --invert          Invert QR code colors");
    console.log("  --ecc=L|M|Q|H     Error correction level (Default: L)");
    console.log("  --multi=N|auto    Render N QR codes side-by-side (1-4, or 'auto')");
    console.log("                    Speeds up transfer: auto-detected or manual");
    console.log("  --speed=<seconds> QR code delay (Default: 0.5)");
    console.log("                    0.5 = 2 chunks/sec (default, works everywhere)");
    console.log("                    0.3 = 3.3 chunks/sec (good lighting)");
    console.log("                    0.2 = 5 chunks/sec (bright light + steady)");
    console.log("                    0.1 = 10 chunks/sec (optimal conditions)");
    console.log("  --buffer=10       Vertical buffer lines");
    process.exit(1);
  }

  // --- Validation ---
  if (content.length === 0) {
    console.error("Error: Input is empty.");
    process.exit(1);
  }

  // --- Configuration ---
  const isSlideshow = flags['--slideshow'] === 'true';
  const useBase64 = flags['--base64'] === 'true';
  const useInverted = flags['--invert'] === 'true';
  const speed = parseFloat(flags['--speed']) || 0.5; // Optimized default
  const buffer = parseInt(flags['--buffer']) || 10;
  const eccLevel = (['L', 'M', 'Q', 'H'].includes(flags['--ecc']) ? flags['--ecc'] : 'L') as 'L'|'M'|'Q'|'H';

  // Parse multi-QR option (1-4 codes per frame)
  let multiQr: number | undefined;
  if (flags['--multi']) {
    const multiVal = flags['--multi'].toLowerCase();
    if (multiVal === 'auto') {
      // Auto-detect based on terminal width (rough heuristic: 29 chars per small QR + 2 char gap)
      const termWidth = process.stdout.columns || 80;
      multiQr = Math.max(1, Math.min(4, Math.floor(termWidth / 31)));
    } else {
      const parsed = parseInt(multiVal);
      if (!isNaN(parsed) && parsed >= 1 && parsed <= 4) {
        multiQr = parsed;
      }
    }
  }

  // If checksum file provided via flag, read it
  if (checksumFile && fs.existsSync(checksumFile)) {
    try {
      providedChecksum = fs.readFileSync(checksumFile, 'utf-8').split('  ')[0];
    } catch (e) {
      console.warn("Warning: Could not read checksum file");
    }
  }

  // If no provided checksum but has multiple parts, compute the concatenated hash
  let addChecksum = false;
  if (providedChecksum) {
    addChecksum = true;
  } else if (totalParts > 1) {
    // For multi-part, always add checksum of concatenated content
    addChecksum = true;
  }

  // --- Processing ---
  const chunker = new Chunker(content);
  chunker.calculateLayout(process.stdout.rows || 24, {
    buffer,
    useBase64,
    addHeader: true, // Always add header for robustness
    eccLevel,
    currentPart: totalParts > 1 ? 1 : undefined,
    totalParts: totalParts > 1 ? totalParts : undefined,
    addChecksum: addChecksum
  });

  const renderer = new Renderer(fileName, {
    speed,
    isSlideshow,
    useInverted,
    eccLevel,
    showPartProgress: totalParts > 1,
    totalParts: totalParts,
    multiQr
  });

  renderer.setChunks(chunker.chunks, chunker.version);

  // Restore Progress
  if (!flags['--reset']) {
    const savedIndex = StateManager.loadProgress(fileName);
    if (savedIndex > 0 && savedIndex < chunker.chunks.length) {
      renderer.index = savedIndex;
    }
  }

  // --- Input Stream Setup ---
  // If we read from Stdin (pipe), process.stdin is exhausted/closed.
  // We must open /dev/tty to get keyboard input.
  let inputStream: NodeJS.ReadStream;

  if (!process.stdin.isTTY) {
    try {
      // Open TTY for interactive control
      const ttyFd = fs.openSync('/dev/tty', 'r');
      inputStream = new tty.ReadStream(ttyFd);
    } catch (e) {
      console.warn("Warning: Could not open /dev/tty. Interactive controls disabled.");
      // Dummy stream if TTY not available
      inputStream = new tty.ReadStream(0);
    }
  } else {
    inputStream = process.stdin;
  }

  // --- Countdown Display ---
  function showCountdown(onComplete: () => void) {
    let countdown = 3;

    const displayCountdown = () => {
      const centerRow = Math.floor((process.stdout.rows || 24) / 2);
      const centerCol = Math.floor((process.stdout.columns || 80) / 2) - 1;

      // Just overlay the countdown without clearing screen
      process.stdout.write(`\x1b[${centerRow};${centerCol}H`);
      process.stdout.write(`\x1b[1;33m${countdown}\x1b[0m`);

      countdown--;

      if (countdown < 0) {
        // Clear the countdown number line and redraw UI
        process.stdout.write(`\x1b[${centerRow};${centerCol}H\x1b[2K\x1b[H`);
        onComplete();
      } else {
        setTimeout(displayCountdown, 1000);
      }
    };

    displayCountdown();
  }

  // --- Interactive Loop ---
  function initInput() {
    if (inputStream.setRawMode) {
      inputStream.setRawMode(true);
    }
    inputStream.resume();
    inputStream.setEncoding('utf8');

    inputStream.on('data', (input: Buffer | string) => {
      const key = input.toString();

      // Navigation
      if (key === '\u001b[C' || key === '\u001b[A' || key === 'l' || key === 'k' || key === ' ') {
        renderer.moveNext();
        draw();
        StateManager.saveProgress(fileName, renderer.index);
      } else if (key === '\u001b[D' || key === '\u001b[B' || key === 'h' || key === 'j') {
        renderer.movePrev();
        draw();
        StateManager.saveProgress(fileName, renderer.index);
      } else if (key === 'q' || key === '\u0003') {
        process.stdout.write('\x1b[2J\x1b[H');
        console.log("Stopped.");
        StateManager.saveProgress(fileName, renderer.index);
        process.exit();
      } else if (key === 's') {
        // If turning ON slideshow, show countdown first
        if (!renderer.options.isSlideshow) {
          showCountdown(() => {
            renderer.options.isSlideshow = true;
            draw();
            StateManager.saveProgress(fileName, renderer.index);
          });
        } else {
          // If turning OFF, just stop
          renderer.options.isSlideshow = false;
          draw();
          StateManager.saveProgress(fileName, renderer.index);
        }
      }
    });
  }

  // --- Run ---

  function draw() {
    renderer.draw();
  }

  initInput();
  draw();

  // Handle Window Resize
  process.stdout.on('resize', () => {
    chunker.calculateLayout(process.stdout.rows, {
      buffer,
      useBase64,
      addHeader: true,
      eccLevel,
      currentPart: totalParts > 1 ? 1 : undefined,
      totalParts: totalParts > 1 ? totalParts : undefined,
      addChecksum: addChecksum
    });
    renderer.setChunks(chunker.chunks, chunker.version);
    draw();
  });

  // Slideshow Loop
  let frameCount = 0;
  setInterval(() => {
    if (renderer.options.isSlideshow) {
      // Loop back to start if at end
      if (renderer.index >= renderer.chunks.length - 1) {
        renderer.index = -1; // Set to -1 so moveNext() brings it to 0
      }

      renderer.moveNext();
      draw();

      // Only save progress occasionally (every ~30 seconds assuming 1.5s speed)
      // to avoid file I/O bottleneck
      frameCount++;
      if (frameCount % 20 === 0) {
        StateManager.saveProgress(fileName, renderer.index);
      }
    }
  }, speed * 1000);
}

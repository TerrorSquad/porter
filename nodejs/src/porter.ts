#!/usr/bin/env node

// DEPRECATED. The sender and `porter serve` were superseded by rust-sender/
// (single static binary, no Node runtime -- see ADR-0004). `porter join` is
// the only subcommand here without a Rust equivalent and the only one still
// current; everything else is kept for reference and is not covered by CI.

import fs from 'fs';
import path from 'path';
import tty from 'tty';
import { Chunker } from './lib/chunker.js';
import { FountainChunker } from './lib/fountain.js';
import {
  FEATURE_BASE64,
  FEATURE_INTERACTIVE_CONTROLS,
  FEATURE_INVERT,
  FEATURE_MULTI_PART_INPUT,
  FEATURE_MULTI_QR,
  FEATURE_SERVE,
  FEATURE_JOIN,
  FEATURE_FOUNTAIN,
} from './lib/features.js';
import { Renderer } from './lib/renderer.js';
import { StateManager } from './lib/state.js';

// --- Helper: Parse Flags ---
const args = process.argv.slice(2);
const flags = Object.fromEntries(
  args
    .filter((a) => a.startsWith('--'))
    .map((a) => {
      const parts = a.split('=');
      return [parts[0], parts[1] || 'true'];
    }),
);

// --- Subcommand dispatch ---
const subcommand = args[0];
if (subcommand === 'serve') {
  if (!FEATURE_SERVE) {
    console.error('Error: this build was compiled without receiver support.');
    process.exit(1);
  }
  const { runReceiver } = await import('./lib/receiver.js');
  const subFlags = Object.fromEntries(
    args
      .slice(1)
      .filter((a) => a.startsWith('--'))
      .map((a) => {
        const [k, ...rest] = a.slice(2).split('=');
        return [k, rest.join('=') || 'true'];
      }),
  );
  runReceiver(subFlags);
} else if (subcommand === 'join') {
  if (!FEATURE_JOIN) {
    console.error('Error: this build was compiled without join support.');
    process.exit(1);
  }
  const { runJoin } = await import('./lib/joiner.js');
  runJoin(args.slice(1));
} else {
  // ponytail: warn, don't block -- the sender still works and someone may be
  // relying on it. Drop the whole branch once join is ported (ADR-0004).
  console.error(
    'Warning: the TypeScript sender is deprecated and unmaintained.\n' +
      '         Use the Rust sender (rust-sender/, `porter-sender`) instead.\n',
  );
  runSender();
}

function runSender() {
  const inputFiles = args.filter((a) => !a.startsWith('--')); // All non-flag args are files
  const checksumFile = FEATURE_MULTI_PART_INPUT ? flags['--verify'] || '' : '';
  const splitAware = FEATURE_MULTI_PART_INPUT && flags['--split-aware'] === 'true';

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
      console.error('Error reading from stdin:', e);
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
    if (FEATURE_MULTI_PART_INPUT && (splitAware || /\.part(?:\d+|[a-z]{2})$/.test(fileNameOnly))) {
      const dir = path.dirname(firstFile) || '.';
      const allFiles = fs.readdirSync(dir);
      const partFiles = allFiles
        .filter((f) => f.includes(baseName) && /\.part(?:\d+|[a-z]{2})$/.test(f))
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
        } catch (_e) {
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
    console.log('\x1b[1mQR DATA PORTER\x1b[0m');
    console.log('Usage:');
    console.log('  porter <file> [options]');
    console.log('  porter <file.part*.txt|file.partaa|...> [options]');
    console.log("  echo 'data' | porter [options]");
    console.log('\nOptions:');
    if (FEATURE_INTERACTIVE_CONTROLS) {
      console.log('  --slideshow       Start in slideshow mode');
    } else {
      console.log('  slideshow-only    This build always starts in slideshow mode');
    }
    if (FEATURE_BASE64) {
      console.log('  --base64          Enable Base64 encoding (for binary files)');
    }
    if (FEATURE_MULTI_PART_INPUT) {
      console.log('  --verify=<file>   Verify against SHA256 checksum file');
      console.log('  --split-aware     Auto-detect and concatenate .part*.txt or .partaa files');
    }
    if (FEATURE_INVERT) {
      console.log('  --invert          Invert QR code colors');
    }
    console.log('  --ecc=L|M|Q|H     Error correction level (Default: L)');
    if (FEATURE_MULTI_QR) {
      console.log("  --multi=N|auto    Render N QR codes in a grid (1-4, or 'auto')");
      console.log('                    Speeds up transfer: auto-detected or manual');
    }
    if (FEATURE_FOUNTAIN) {
      console.log('  --fountain        Use fountain (LT code) coding instead of sequential');
      console.log('                    chunks: the receiver can reconstruct the file from');
      console.log('                    ANY sufficient subset of frames, in any order.');
      console.log('                    Best for long/lossy scans. --base64 has no effect.');
    }
    console.log('  --no-info         Hide the info sidebar (chunk/progress/etc.)');
    console.log('  --speed=<seconds> QR code delay (Default: 0.5)');
    console.log('                    0.5 = 2 chunks/sec (default, works everywhere)');
    console.log('                    0.3 = 3.3 chunks/sec (good lighting)');
    console.log('                    0.2 = 5 chunks/sec (bright light + steady)');
    console.log('                    0.1 = 10 chunks/sec (optimal conditions)');
    console.log('  --buffer=10       Vertical buffer lines');
    if (FEATURE_SERVE) {
      console.log('');
      console.log('\x1b[1mSubcommands:\x1b[0m');
      console.log('  porter serve [--port=8080] [--host=0.0.0.0] [--output-dir=received]');
      console.log('              Start an HTTP receiver. Accepts QR scan JSON uploads,');
      console.log('              raw file uploads, and multipart/form-data.');
      console.log('              Reconstructs multi-part transfers automatically.');
    }
    if (FEATURE_JOIN) {
      console.log('  porter join <transfer-dir|id> [--output=<file>] [--force] [--no-verify]');
      console.log('              Join previously received .partXX files into a single file.');
    }
    process.exit(1);
  }

  // --- Validation ---
  if (content.length === 0) {
    console.error('Error: Input is empty.');
    process.exit(1);
  }

  // --- Configuration ---
  const isSlideshow = FEATURE_INTERACTIVE_CONTROLS ? flags['--slideshow'] === 'true' : true;
  const requestedBase64 = flags['--base64'] === 'true';
  if (requestedBase64 && !FEATURE_BASE64) {
    console.error('Error: this build was compiled without Base64 support.');
    process.exit(1);
  }
  if ((flags['--verify'] || flags['--split-aware']) && !FEATURE_MULTI_PART_INPUT) {
    console.error('Error: this build was compiled without multipart input support.');
    process.exit(1);
  }
  if (flags['--invert'] && !FEATURE_INVERT) {
    console.error('Error: this build was compiled without invert support.');
    process.exit(1);
  }
  if (flags['--multi'] && !FEATURE_MULTI_QR) {
    console.error('Error: this build was compiled without multi-QR support.');
    process.exit(1);
  }
  if (flags['--fountain'] && !FEATURE_FOUNTAIN) {
    console.error('Error: this build was compiled without fountain coding support.');
    process.exit(1);
  }
  const useFountain = FEATURE_FOUNTAIN && flags['--fountain'] === 'true';
  const useBase64 = FEATURE_BASE64 && requestedBase64;
  const useInverted = FEATURE_INVERT && flags['--invert'] === 'true';
  const noInfo = flags['--no-info'] === 'true';
  const speed = parseFloat(flags['--speed']) || 0.5; // Optimized default
  const buffer = parseInt(flags['--buffer']) || 10;
  const eccLevel = (['L', 'M', 'Q', 'H'].includes(flags['--ecc']) ? flags['--ecc'] : 'L') as
    | 'L'
    | 'M'
    | 'Q'
    | 'H';

  // Parse multi-QR option (1-4 codes per frame)
  let multiQr: number | undefined;
  if (FEATURE_MULTI_QR && flags['--multi']) {
    const multiVal = flags['--multi'].toLowerCase();
    if (multiVal === 'auto') {
      // Request the max grid size; Renderer.effectiveMultiQr() fits the
      // actual per-frame count to the terminal (and re-fits on resize).
      multiQr = 4;
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
    } catch (_e) {
      console.warn('Warning: Could not read checksum file');
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
  const chunker: Chunker | FountainChunker = useFountain
    ? new FountainChunker(content)
    : new Chunker(content);
  chunker.calculateLayout(process.stdout.rows || 24, {
    buffer,
    useBase64,
    addHeader: true, // Always add header for robustness
    eccLevel,
    currentPart: totalParts > 1 ? 1 : undefined,
    totalParts: totalParts > 1 ? totalParts : undefined,
    addChecksum: addChecksum,
  });

  const renderer = new Renderer(fileName, {
    speed,
    isSlideshow,
    useInverted,
    eccLevel,
    showPartProgress: totalParts > 1,
    totalParts: totalParts,
    multiQr,
    noInfo,
  });

  renderer.setChunks(chunker.chunks, chunker.version);

  // Restore Progress
  if (!flags['--reset']) {
    const savedIndex = StateManager.loadProgress(fileName);
    if (savedIndex > 0 && savedIndex < chunker.chunks.length) {
      renderer.index = savedIndex;
    }
  }

  let inputStream: NodeJS.ReadStream | undefined;

  function showCountdown(onComplete: () => void) {
    if (!FEATURE_INTERACTIVE_CONTROLS) {
      onComplete();
      return;
    }

    let countdown = 3;

    const displayCountdown = () => {
      const centerRow = Math.floor((process.stdout.rows || 24) / 2);
      const centerCol = Math.floor((process.stdout.columns || 80) / 2) - 1;

      process.stdout.write(`\x1b[${centerRow};${centerCol}H`);
      process.stdout.write(`\x1b[1;33m${countdown}\x1b[0m`);

      countdown--;

      if (countdown < 0) {
        process.stdout.write(`\x1b[${centerRow};${centerCol}H\x1b[2K\x1b[H`);
        onComplete();
      } else {
        setTimeout(displayCountdown, 1000);
      }
    };

    displayCountdown();
  }

  function initInput() {
    if (!FEATURE_INTERACTIVE_CONTROLS) {
      return;
    }

    if (!process.stdin.isTTY) {
      try {
        const ttyFd = fs.openSync('/dev/tty', 'r');
        inputStream = new tty.ReadStream(ttyFd);
      } catch (_e) {
        console.warn('Warning: Could not open /dev/tty. Interactive controls disabled.');
        inputStream = new tty.ReadStream(0);
      }
    } else {
      inputStream = process.stdin;
    }

    if (inputStream.setRawMode) {
      inputStream.setRawMode(true);
    }
    inputStream.resume();
    inputStream.setEncoding('utf8');

    inputStream.on('data', (input: Buffer | string) => {
      const key = input.toString();

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
        console.log('Stopped.');
        StateManager.saveProgress(fileName, renderer.index);
        process.exit();
      } else if (key === 's') {
        if (!renderer.options.isSlideshow) {
          showCountdown(() => {
            renderer.options.isSlideshow = true;
            draw();
            StateManager.saveProgress(fileName, renderer.index);
          });
        } else {
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
      addChecksum: addChecksum,
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

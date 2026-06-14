# Porter — Node.js Implementation

Terminal-based QR code file transfer tool built with TypeScript and Node.js.

## 📦 Quick Start

### Using Pre-built Binary

```bash
# Run directly
./dist/porter.mjs myfile.txt --slideshow

# Or install globally
npm install -g .
porter myfile.txt --slideshow
```

### Global Installation (macOS/Linux)

```bash
# Copy standalone executable to pnpm global bin directory
cp dist/porter.mjs ~/.local/share/pnpm/porter.mjs

# Create wrapper script at ~/.local/share/pnpm/porter
cat > ~/.local/share/pnpm/porter << 'EOF'
#!/bin/sh
basedir=$(dirname "$(echo "$0" | sed -e 's,\\,/,g')")
case `uname` in
  *CYGWIN*|*MINGW*|*MSYS*)
    if command -v cygpath > /dev/null 2>&1; then
      basedir=`cygpath -w "$basedir"`
    fi
    ;;
esac
exec node "${basedir}/porter.mjs" "$@"
EOF
chmod +x ~/.local/share/pnpm/porter

# Add to PATH (add to ~/.zshrc or ~/.bashrc)
export PATH="$HOME/.local/share/pnpm:$PATH"

# Test
porter --help
```

## 🛠️ Development

### Prerequisites

- **Node.js 18+** (recommended: 24.13.0)
- **pnpm** (or npm/yarn)

### Building from Source

```bash
# Install dependencies
pnpm install

# Build the smaller project-local CLI (dist/porter.mjs)
pnpm run build

# Build the recommended slim preset
pnpm run build:slim

# Build a smaller variant with Base64 support compiled out
pnpm run build:no-base64

# Build a smaller variant without multipart input support
pnpm run build:single-file-only

# Build variants without invert or multi-QR support
pnpm run build:no-invert
pnpm run build:no-multi-qr

# Build a slideshow-only variant without keyboard controls
pnpm run build:slideshow-only

# Build the smallest externalized variant
pnpm run build:minimal

# Build the standalone single-file CLI
pnpm run build:standalone
# → Outputs dist/porter.standalone.mjs

# Build the recommended standalone slim preset
pnpm run build:standalone:slim

# Standalone variant without Base64 support
pnpm run build:standalone:no-base64

# Standalone variant without multipart input support
pnpm run build:standalone:single-file-only

# Other standalone feature-trimmed variants
pnpm run build:standalone:no-invert
pnpm run build:standalone:no-multi-qr
pnpm run build:standalone:slideshow-only
pnpm run build:standalone:minimal

# Print current build sizes
pnpm run size:report

# Test
./dist/porter.mjs --help
```

### Recommended Presets

Use these presets unless you specifically need to tune individual feature flags:

| Command                             | Output                                      | Use when                                                                                  |
| ----------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `pnpm run build`                    | `dist/porter.mjs`                           | You want the default local build with the full interactive CLI.                           |
| `pnpm run build:slim`               | `dist/porter.slideshow-only.mjs`            | You want the best size reduction without removing multipart, invert, or multi-QR support. |
| `pnpm run build:minimal`            | `dist/porter.minimal.mjs`                   | You want the absolute smallest externalized build and can live without optional features. |
| `pnpm run build:standalone`         | `dist/porter.standalone.mjs`                | You need one self-contained file for another machine.                                     |
| `pnpm run build:standalone:slim`    | `dist/porter.standalone.slideshow-only.mjs` | You need a smaller self-contained file and slideshow mode is enough.                      |
| `pnpm run build:standalone:minimal` | `dist/porter.standalone.minimal.mjs`        | You need the smallest self-contained file.                                                |

### Project Structure

```
nodejs/
├── src/
│   ├── index.ts          # CLI entry point
│   ├── chunker.ts        # File chunking logic
│   ├── renderer.ts       # QR rendering
│   ├── state.ts          # Progress tracking
│   └── types.ts          # TypeScript interfaces
├── dist/
│   └── porter.mjs        # Compiled executable
├── scripts/
│   └── ...               # Build/test scripts
├── package.json
├── tsconfig.json
└── test-porter.sh        # Integration tests
```

## 🎯 Usage

### Basic Commands

```bash
# Display help
./dist/porter.mjs --help

# Send a file (slideshow mode)
./dist/porter.mjs myfile.pdf --slideshow

# Adjust speed for lighting conditions
./dist/porter.mjs file.txt --slideshow --speed=0.3

# Manual mode (use keyboard controls)
./dist/porter.mjs file.txt
# L/H: Navigate chunks
# S: Start slideshow
# Q: Quit
```

### Advanced Options

```bash
# Custom speed (seconds per chunk)
./dist/porter.mjs file.txt --slideshow --speed=0.5

# Resume from checkpoint
./dist/porter.mjs file.txt --slideshow
# (Automatically resumes from .porter-progress-xxx.json)

# Binary files
./dist/porter.mjs image.png --slideshow

# Fountain (LT code) mode — best for long/lossy scans
./dist/porter.mjs bigfile.bin --slideshow --fountain
```

## 🌊 Fountain coding mode (`--fountain`)

By default porter splits a file into a fixed sequence of indexed chunks, and the
receiver must eventually capture _every specific_ chunk. In long or lossy scans
this causes a "last chunk" problem: the slideshow loops repeatedly while you wait
for the few frames you happened to miss.

`--fountain` switches to **fountain (Luby Transform) coding**. Instead of indexed
chunks, porter emits a pool of XOR-combination _symbols_; the receiver can
reconstruct the whole file from **any** sufficient subset of them, in any order.
There is no specific frame you must catch — every frame you scan makes progress.

```bash
porter bigfile.bin --slideshow --fountain
```

**When to prefer it**

| Situation                                | Recommended mode     |
| ---------------------------------------- | -------------------- |
| Small/medium file, good lighting, steady | sequential (default) |
| Large file, or shaky/lossy/long scan     | `--fountain`         |

Trade-offs: fountain mode adds redundancy (it renders ~3× as many frames as there
are source blocks), and the sender's progress sidebar shows "symbol N of M"
rather than a precise per-chunk grid. The receiver still verifies the final file
against the same `CHECKSUM` (SHA-256) frame.

Notes:

- `--base64` has no effect under `--fountain` — symbol payloads are always
  base64-encoded binary by construction.
- Builds compiled without fountain support (see
  `PORTER_FEATURE_FOUNTAIN=false`) reject `--fountain` at runtime.

### Wire format

Fountain frames use a distinct chunk type, recognised by the receiver before the
sequential `index|total|mode|id|payload` format:

```
F|seq|K|fileSize|id|payload
```

- `F` — literal marker.
- `seq` — symbol sequence number (`0, 1, 2, …`), used directly as the PRNG seed.
- `K` — total number of source blocks for this transfer.
- `fileSize` — original file size in bytes (the last source block is zero-padded;
  the receiver trims to this on assembly).
- `id` — the same 2-char transfer id used by sequential mode.
- `payload` — base64 of the XOR'd block.

The `(degree, source-block indices)` each symbol combines are **not transmitted** —
both sides derive them deterministically from `seq` via a shared integer-only
xorshift32 PRNG and degree table (`nodejs/src/lib/fountain.ts` ↔
`flutter/lib/services/fountain_codec.dart`, pinned by matching golden-vector
tests). The existing `CHECKSUM|T|<id>|<sha256>` frame is reused verbatim as the
final frame in the pool.

## 🔧 Technology Stack

| Component            | Purpose               |
| -------------------- | --------------------- |
| **TypeScript**       | Type-safe source code |
| **Rollup**           | Minified CLI bundling |
| **qrcode-generator** | QR matrix generation  |
| **Node.js Crypto**   | MD5 checksums         |
| **Zlib**             | Gzip compression      |

## 📊 Performance

| Metric        | Value                   |
| ------------- | ----------------------- |
| Bundle size   | Single-file bundled CLI |
| Dependencies  | ~2 MB (node_modules)    |
| Startup time  | <50ms                   |
| Memory usage  | ~30 MB                  |
| Default speed | 2 chunks/sec            |

## 🧪 Testing

```bash
# Run integration tests
./test-porter.sh

# Manual test
./dist/porter.mjs test-file.txt --slideshow
```

## 📦 Distribution

### Creating Portable Package

```bash
# Small local build (expects node_modules to be present)
pnpm run build

# Standalone build for copying elsewhere
pnpm run build:standalone
tar -czf porter-nodejs.tar.gz dist/porter.standalone.mjs

# User installation
tar -xzf porter-nodejs.tar.gz
node porter.standalone.mjs --help
```

### Publishing to npm

```bash
# Update version in package.json
npm version patch

# Publish
npm publish
```

## 🐛 Troubleshooting

### "Cannot find module"

```bash
# Reinstall dependencies
rm -rf node_modules pnpm-lock.yaml
pnpm install
```

### QR codes not displaying

- Ensure terminal supports UTF-8
- Try zooming out (terminal text size)
- Check `LANG` environment variable: `export LANG=en_US.UTF-8`

### Build fails

```bash
# Clear cache and rebuild
rm -rf dist/
pnpm run build
```

Build outputs:

- `pnpm run build`: minified `dist/porter.mjs`, smaller but expects project dependencies to be installed.
- `pnpm run build:slim`: alias for `build:slideshow-only`, recommended slim preset.
- `pnpm run build:no-base64`: same as above, but compiled without `--base64` support.
- `pnpm run build:single-file-only`: same as above, but compiled without `.part*` auto-assembly or `--verify` support.
- `pnpm run build:no-invert`: same as above, but compiled without `--invert` support.
- `pnpm run build:no-multi-qr`: same as above, but compiled without `--multi` support.
- `pnpm run build:slideshow-only`: same as above, but compiled without keyboard controls and always starts in slideshow mode.
- `pnpm run build:minimal`: strips all optional features above in one externalized build.
- `pnpm run build:standalone`: minified `dist/porter.standalone.mjs`, self-contained for copying to another machine.
- `pnpm run build:standalone:slim`: alias for `build:standalone:slideshow-only`, recommended slim standalone preset.
- `pnpm run build:standalone:no-base64`: standalone variant without `--base64` support.
- `pnpm run build:standalone:single-file-only`: standalone variant without multipart input support.
- `pnpm run build:standalone:no-invert`: standalone variant without invert support.
- `pnpm run build:standalone:no-multi-qr`: standalone variant without multi-QR support.
- `pnpm run build:standalone:slideshow-only`: standalone variant without keyboard controls.
- `pnpm run build:standalone:minimal`: smallest self-contained variant.
- `pnpm run size:report`: prints raw and gzip-compressed sizes for current dist outputs.

Modular feature builds:

- Build-time feature flags now cover Base64, multipart input, invert, multi-QR, and interactive controls.
- In `no-base64` builds, the `--base64` flag is removed from help and rejected at runtime.
- The build-time flag is `PORTER_FEATURE_BASE64=false`, wired through Rollup so dead Base64 branches can be tree-shaken away.
- Multipart input support is also modular.
- In `single-file-only` builds, `--split-aware` and `--verify` are removed and rejected, and `.part*` auto-discovery logic is compiled out.
- The build-time flag is `PORTER_FEATURE_MULTI_PART_INPUT=false`.
- Invert support is modular via `PORTER_FEATURE_INVERT=false`.
- Multi-QR support is modular via `PORTER_FEATURE_MULTI_QR=false`.
- Fountain coding (`--fountain`) is modular via `PORTER_FEATURE_FOUNTAIN=false`; those builds drop the flag from help and reject it at runtime.
- Interactive controls are modular via `PORTER_FEATURE_INTERACTIVE_CONTROLS=false`; those builds start directly in slideshow mode and omit keyboard-control UI.
- `pnpm run build:minimal` and `pnpm run build:standalone:minimal` strip all optional features in one build.

## 🤝 Contributing

See [../README.md](../README.md) for repo-level workflow and artifact guidance.

## 📄 License

ISC

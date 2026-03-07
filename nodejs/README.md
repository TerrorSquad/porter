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

# Build
pnpm run build
# → Outputs dist/porter.mjs

# Test
./dist/porter.mjs --help
```

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
```

## 🔧 Technology Stack

| Component | Purpose |
|-----------|---------|
| **TypeScript** | Type-safe source code |
| **Rollup** | Single-file bundling for distributable CLI builds |
| **qrcode-terminal** | Terminal QR code rendering |
| **Node.js Crypto** | MD5 checksums |
| **Zlib** | Gzip compression |

## 📊 Performance

| Metric | Value |
|--------|-------|
| Bundle size | Single-file bundled CLI |
| Dependencies | ~2 MB (node_modules) |
| Startup time | <50ms |
| Memory usage | ~30 MB |
| Default speed | 2 chunks/sec |

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
# Build & package
pnpm run build
tar -czf porter-nodejs.tar.gz dist/ node_modules/ package.json

# User installation
tar -xzf porter-nodejs.tar.gz
cd porter-nodejs
npm install --production
./dist/porter.mjs --help
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

If you need an externalized bundle for environments that already provide `qrcode-terminal`, run `pnpm run build:external`.

## 🤝 Contributing

See [../BUILD_GUIDE.md](../BUILD_GUIDE.md) for development workflow.

## 📄 License

ISC

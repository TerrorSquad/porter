# 📦 Porter — Distribution & Setup

Quick guide to building and distributing the Porter tool.

## 🎯 TL;DR

```bash
# 1. Build (creates dist/porter.mjs)
npm run build

# 2. Install deps in dist/
cd dist && npm install --production

# 3. Copy to another computer
scp -r dist/ user@host:/opt/porter/

# 4. Use on target computer
cd /opt/porter
./porter.mjs myfile.txt --slideshow
```

---

## 📂 Project Structure

```
.
├── src/                        # TypeScript source code
│   ├── porter.ts              # Main CLI entry
│   ├── lib/
│   │   ├── chunker.ts         # File splitting & encoding
│   │   ├── renderer.ts        # Terminal QR display
│   │   ├── constants.ts       # QR capacity tables
│   │   └── state.ts           # Progress persistence
├── dist/                       # ⭐ DISTRIBUTION FOLDER
│   ├── porter.mjs            # Compiled executable (8.1 KB)
│   ├── node_modules/         # Runtime deps (after npm install)
│   ├── package.json          # Runtime deps list only
│   └── README.md             # User guide
├── DISTRIBUTION.md            # This build guide
├── ANDROID_APP_SPEC.md       # Flutter app spec
└── package.json              # Project deps (dev + runtime)
```

---

## 🔧 Building the Distribution

### Prerequisites
```bash
cd /home/gninkovic/Projects/Personal/php/utils
npm install  # or pnpm install
```

### Build Command
```bash
npm run build
```

This runs esbuild to:
1. Bundle `src/porter.ts` → `dist/porter.mjs`
2. Minify the code
3. Bundle all dependencies (qrcode-terminal) for portability
4. Output: **~20 KB self-contained executable**

### Verify Build
```bash
node dist/porter.mjs --help
```

---

## 📦 Creating Distributable Package

### Option 1: Minimal (Just Executable)
```bash
# Copy only the executable (~8 KB)
cp dist/porter.mjs /tmp/
scp /tmp/porter.mjs user@host:/opt/

# On target: install globally with Node
node /opt/porter.mjs <file>
```

**Pros:** Tiny, easy to transfer  
**Cons:** User must install `qrcode-terminal` separately

### Option 2: Self-Contained (Recommended)
```bash
# Full package with deps
cd dist && npm install --production

# Create archive (~2 MB)
tar czf porter.tar.gz .

# Transfer
scp porter.tar.gz user@host:/opt/

# On target
cd /opt && tar xzf porter.tar.gz
./porter.mjs <file> --slideshow
```

**Pros:** Works immediately, no extra install needed  
**Cons:** Larger (2 MB with node_modules)

### Option 3: ZIP for Windows
```bash
# On macOS/Linux
cd dist
npm install --production
# Build Guide

This repository now has two implementations:

- `nodejs/` — TypeScript/Node.js sender
- `golang/` — Go sender

## Node.js build

```bash
cd nodejs
npm install
npm run build
./dist/porter.mjs --help
```

## Go build

```bash
cd golang
make build
./porter --help
```

## Using mise tasks

From repo root:

```bash
mise run node-install
mise run node-build
mise run go-build
```

## Output artifacts

- Node: `nodejs/dist/porter.mjs`
- Go: `golang/porter`

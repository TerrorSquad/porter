# Porter — Air-Gapped File Transfer via QR Codes

**Transfer files between computers without a network. Scan QR codes from a terminal with any device camera.**

```bash
cd nodejs
./dist/porter.mjs myfile.txt --slideshow
# → Phone scans QR codes, file is reassembled locally
```

## 📦 Quick Start

### Node.js Version (Recommended)
```bash
cd nodejs
pnpm install
pnpm run build:slim
./dist/porter.slideshow-only.mjs myfile.txt
```

**→ See [nodejs/README.md](nodejs/README.md) for detailed installation & usage**

### Go Version (Native Binary)
```bash
cd golang
make build
./porter myfile.txt
```

**→ See [golang/README.md](golang/README.md) for detailed installation & usage**

### Quick Install (Any Version)
```bash
# Download release
wget https://github.com/gninkovic/porter/releases/download/latest/porter.tar.gz
tar xzf porter.tar.gz
cd porter

# Choose your implementation (nodejs/ or golang/)
```

---

## 📚 Documentation

| Document | Purpose |
|----------|---------|
| **[nodejs/README.md](nodejs/README.md)** | Node.js implementation guide, build presets, and packaging |
| **[golang/README.md](golang/README.md)** | Go sender, receiver, join flow, and native distribution |
| **[ANDROID_APP_SPEC.md](ANDROID_APP_SPEC.md)** | Flutter receiver app spec |

---

## 🎯 How It Works

```
Offline Computer              Phone / Receiver
   (Sender)                    (Scanner)
       │
       ├─ Read file
       ├─ Split into chunks
       ├─ Encode as Base64 (binary)
       ├─ Create QR codes
       └─ Display slideshow
              │
              │ [QR Code Stream]
              │
              └──→ Camera scans
                   ├─ Detect QR
                   ├─ Parse header
                   ├─ Assemble chunks
                   └─ Save file
```

---

## 🚀 Features

✅ **Offline** — No internet, no cloud, no telemetry  
✅ **Fast** — 2-10 chunks/sec depending on lighting  
✅ **Portable** — ~20 KB executable, runs on Node.js 18+  
✅ **Reliable** — Header protocol handles dropped/reordered chunks  
✅ **Flexible** — Works with any camera, terminal, phone OS  

---

## 💾 What's Inside

```
.
├── nodejs/
│   ├── src/               # TypeScript source
│   ├── scripts/           # Build helpers like size reporting
│   ├── dist/              # Ignored generated Node builds
│   ├── package.json
│   └── test-porter.sh
├── golang/
│   ├── main.go
│   ├── receiver.go
│   ├── join.go
│   ├── transfer_manifest.go
│   ├── go.mod
│   └── Makefile
├── mise.toml
├── ANDROID_APP_SPEC.md
└── README.md
```

---

## 📱 Building a Receiver

The Porter sender generates scannable QR codes. You can build a receiver app in any language:

- **Flutter Reference:** See [ANDROID_APP_SPEC.md](ANDROID_APP_SPEC.md) for specifications
- **Web:** Use a WebRTC camera library to scan and reassemble
- **CLI:** Use any QR library to decode chunks and rebuild the file

All you need is the chunk format: `index|total|mode|id|payload`

---

## 🔧 Technology

| Component | Purpose |
|-----------|---------|
| **Rollup** | Bundle TypeScript → single-file JS |
| **qrcode-generator** | QR matrix generation for terminal rendering |
| **Node.js Crypto** | MD5 checksums |
| **Zlib** | Server-side gzip |

---

## 📊 Performance

| Metric | Value |
|--------|-------|
| Executable size | 8.1 KB |
| With dependencies | 2 MB |
| Default speed | 2 chunks/sec |
| Max speed | 10 chunks/sec |
| Typical file transfer | 100K file ≈ 3-5 min |

---

## 🔐 Security

- **Offline by design** — No network calls
- **No logging** — No history stored (except progress checkpoint)
- **No telemetry** — No analytics or tracking
- **Local processing** — All QR generation on-device
- **Optional** — Progress file can be deleted anytime

---

## 🛠️ Usage

### Node.js Version
```bash
cd nodejs
./dist/porter.slideshow-only.mjs myfile.pdf --speed=0.3
```

### Go Version
```bash
cd golang
./porter myfile.txt

# Receive files over HTTP from another device on your LAN
./porter serve --port=8080 --output-dir=received
```

**For detailed commands and options:**
- Node.js: See [nodejs/README.md](nodejs/README.md)
- Go: See [golang/README.md](golang/README.md)

---

## 🔨 Build And Distribution

### Workspace Prerequisites

- Node.js `24.13.0` and `pnpm 10.30.1` for `nodejs/`
- Go `1.26.1` for `golang/`
- `mise` is optional; the repo already defines matching tasks in `mise.toml`

### Node.js Builds

```bash
cd nodejs
pnpm install

# Full local build
pnpm run build

# Recommended slim preset
pnpm run build:slim

# Smallest externalized build
pnpm run build:minimal

# Self-contained single-file distributions
pnpm run build:standalone
pnpm run build:standalone:slim
pnpm run build:standalone:minimal

# Tests and size reporting
pnpm test
pnpm run size:report
```

Recommended Node artifacts:

- `nodejs/dist/porter.slideshow-only.mjs`: best slim preset when project dependencies are available
- `nodejs/dist/porter.standalone.slideshow-only.mjs`: recommended copyable single-file build
- `nodejs/dist/porter.minimal.mjs` and `nodejs/dist/porter.standalone.minimal.mjs`: smallest builds, with optional features removed

### Go Builds

```bash
cd golang
make build

# or
go build -o porter .
```

Primary Go artifact:

- `golang/porter`: native sender and HTTP receiver binary

### mise Tasks

From the repo root:

```bash
mise run node-install
mise run node-build
mise run go-build
```

---

## 🤝 Contributing

This is a hobby project, but PRs welcome for:
- Performance improvements
- Better error messages
- New platforms (iOS, desktop apps)
- Documentation improvements

---

## 📄 License

ISC

---

Made with ❤️ for secure, offline file transfer.

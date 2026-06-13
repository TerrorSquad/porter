# Porter — Air-Gapped File Transfer via QR Codes

**Transfer files between computers without a network. Scan QR codes from a terminal with any device camera.**

```bash
cd nodejs
./dist/porter.mjs myfile.txt --slideshow
# → Phone scans QR codes, file is reassembled locally
```

## 📦 Quick Start

```bash
cd nodejs
pnpm install
pnpm run build:slim
./dist/porter.slideshow-only.mjs myfile.txt
```

**→ See [nodejs/README.md](nodejs/README.md) for detailed installation & usage**

### HTTP Receiver (porter serve)

```bash
cd nodejs
./dist/porter.mjs serve --port=8080
# → Any device on your LAN can POST QR scan JSON to http://<ip>:8080/upload
```

---

## 📚 Documentation

| Document                                       | Purpose                                       |
| ---------------------------------------------- | --------------------------------------------- |
| **[nodejs/README.md](nodejs/README.md)**       | Node.js sender, receiver, join, build presets |
| **[ANDROID_APP_SPEC.md](ANDROID_APP_SPEC.md)** | Flutter receiver app spec                     |

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
│   │   ├── porter.ts      # CLI entry point (send / serve / join)
│   │   └── lib/           # chunker, renderer, state, receiver, joiner
│   ├── scripts/           # Build helpers like size reporting
│   ├── dist/              # Ignored generated Node builds
│   ├── package.json
│   └── test-porter.sh
├── porter_android/        # Flutter receiver app (Android/macOS)
├── mise.toml
├── ANDROID_APP_SPEC.md
└── README.md
```

---

## 📱 Building a Receiver

The Porter sender generates scannable QR codes. You can build a receiver app in any language:

- **Flutter Reference:** See [ANDROID_APP_SPEC.md](ANDROID_APP_SPEC.md) for specifications
- **CLI:** Use any QR library to decode chunks and rebuild the file

All you need is the chunk format: `index|total|mode|id|payload`

---

## 🔧 Technology

| Component            | Purpose                                     |
| -------------------- | ------------------------------------------- |
| **Rollup**           | Bundle TypeScript → single-file JS          |
| **qrcode-generator** | QR matrix generation for terminal rendering |
| **Node.js Crypto**   | MD5 checksums                               |
| **Zlib**             | Server-side gzip                            |

---

## 📊 Performance

| Metric                | Value               |
| --------------------- | ------------------- |
| Executable size       | 8.1 KB              |
| With dependencies     | 2 MB                |
| Default speed         | 2 chunks/sec        |
| Max speed             | 10 chunks/sec       |
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

# Receive files over HTTP from another device on your LAN
./dist/porter.mjs serve --port=8080 --output-dir=received

# Join a previously received multi-part transfer
./dist/porter.mjs join received/<id>
```

**For detailed commands and options, see [nodejs/README.md](nodejs/README.md)**

---

## 🔨 Build And Distribution

### Workspace Prerequisites

- Node.js `24.13.0` and `pnpm 10.30.1` for `nodejs/`
- `mise` is optional; the repo already defines matching tasks in `mise.toml`

### Node.js Builds

```bash
cd nodejs
pnpm install

# Build both artifacts at once
pnpm run build

# Or individually
pnpm run build:external    # porter.mjs  (requires qrcode-generator)
pnpm run build:standalone  # porter.standalone.mjs  (self-contained, no dependencies)
```

Artifacts:

- `nodejs/dist/porter.mjs` — requires `qrcode-generator` to be installed alongside it
- `nodejs/dist/porter.standalone.mjs` — single copyable file, no external dependencies

### mise Tasks

From the repo root:

```bash
mise run node-install
mise run node-build
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

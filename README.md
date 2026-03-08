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
| **[PORTER.md](PORTER.md)** | User guide, features, usage |
| **[BUILD_GUIDE.md](BUILD_GUIDE.md)** | Building & distributing |
| **[DISTRIBUTION.md](DISTRIBUTION.md)** | Build process details |
| **[ANDROID_APP_SPEC.md](ANDROID_APP_SPEC.md)** | Flutter receiver app spec |
| **[nodejs/README.md](nodejs/README.md)** | Node.js implementation guide |
| **[golang/README.md](golang/README.md)** | Go implementation guide |

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
│   ├── dist/              # Compiled Node executable (porter.mjs)
│   ├── package.json
│   └── test-porter.sh
├── golang/
│   ├── main.go
│   ├── chunker.go
│   ├── renderer.go
│   ├── state.go
│   ├── go.mod
│   └── Makefile
├── PORTER.md
├── BUILD_GUIDE.md
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

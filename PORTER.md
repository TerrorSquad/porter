# 📦 Porter — QR Code File Transfer

Transfer files between computers via terminal QR codes. Air-gapped, no network required.

## ⚡ Quick Start

### For Users (Just Run It)
```bash
# Download the distribution
git clone https://github.com/gninkovic/porter.git
cd porter/dist

# Install & run
npm install --production
./porter.mjs myfile.txt --slideshow
```

**Or download pre-built:**
```bash
# Just copy porter.mjs + run directly with node
node /path/to/porter.mjs myfile.pdf --slideshow
```

### For Developers (Build from Source)
```bash
# 📦 Porter — QR Code File Transfer

Transfer files between computers via terminal QR codes. Air-gapped, no network required.

## ⚡ Quick Start

### Node.js Version
```bash
cd nodejs
npm install
npm run build
./dist/porter.mjs myfile.txt --slideshow
```

### Go Version
```bash
cd golang
make build
./porter myfile.txt --slideshow
```

## 🚀 Usage

### Sender Command
```bash
# Node.js
cd nodejs && ./dist/porter.mjs <file> [options]

# Go
cd golang && ./porter <file> [options]
```

### Common Options
```
--slideshow       Loop QR codes continuously
--speed=0.5       Chunk delay in seconds (0.5 = 2 chunks/sec)
--base64          Force Base64 encoding
--invert          Invert QR colors
--ecc=L|M|Q|H     Error correction level
--buffer=2        Terminal buffer lines
--reset           Ignore saved progress
```

### Controls
```
L / Right Arrow   Next chunk
H / Left Arrow    Previous chunk
Space             Next chunk
S                 Toggle slideshow
Q / Ctrl+C        Quit (saves progress)
```

## 📚 Documentation

- `README.md` — repo overview
- `BUILD_GUIDE.md` — build/install guide
- `DISTRIBUTION.md` — distribution notes
- `ANDROID_APP_SPEC.md` — receiver app spec

## 📄 License

ISC
--base64          Force Base64 encoding (auto-detected normally)

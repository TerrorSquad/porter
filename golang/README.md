# Porter — Go Implementation

Native Go implementation of the Porter QR code file transfer tool.

## 📦 Quick Start

### Using Pre-built Binary
```bash
# Run directly
./porter myfile.txt

# Or install to PATH
sudo cp porter /usr/local/bin/
porter myfile.txt
```

## 🛠️ Development

### Prerequisites
- **Go 1.26+** (Go 1.26.1 recommended)
- **Make** (optional, for convenience)

### Building from Source
```bash
# Using Make
make build
# → Creates porter binary

# Or using go directly
go build -o porter .

# Test
./porter --help
```

### Environment Setup
Add to `~/.zshrc` or `~/.bashrc`:
```bash
export GOROOT=$HOME/go
export PATH=$GOROOT/bin:$PATH
export PATH=$HOME/go/bin:$PATH
```

### Project Structure
```
golang/
├── main.go           # CLI entry & event loop
├── chunker.go        # File chunking & QR sizing
├── renderer.go       # Terminal QR rendering
├── state.go          # Progress tracking
├── go.mod            # Dependencies
├── go.sum            # Dependency checksums
├── Makefile          # Build configuration
└── porter            # Compiled binary
```

## 🎯 Usage

### Basic Commands
```bash
# Display help
./porter --help

# Send a file (auto-starts slideshow)
./porter myfile.pdf

# Start a local HTTP receiver
./porter serve --port=8080 --output-dir=received

# Manual mode (requires keyboard control)
./porter file.txt
# L/H: Navigate chunks
# S: Start slideshow
# Q: Quit
```

### Receive Files Over HTTP
```bash
# Start the receiver on all interfaces
./porter serve --port=8080 --output-dir=received

# Send raw file bytes from another device on the same network
curl --data-binary @notes.txt "http://192.168.1.10:8080/upload?filename=notes.txt"

# Or send multipart form data
curl -F file=@photo.jpg http://192.168.1.10:8080/upload
```

The receiver accepts `POST /upload` requests, saves files into the output directory, and prints reachable LAN URLs on startup.
If the uploaded bytes match an existing file in the output directory, Porter skips the duplicate and returns the existing path instead of saving a second copy.
For JSON uploads like the scanned QR payloads you just sent, deduplication is based on the meaningful payload and ignores the `timestamp` field.
QR scan JSON uploads are unpacked into joinable files like `iz.partaa`, `iz.partab`, and `iz.sha256` instead of storing the JSON wrapper body.

To reassemble a transfer later:
```bash
cat iz.part* > restored-file
```

### Keyboard Controls
- **L** / **→**: Next chunk
- **H** / **←**: Previous chunk
- **S**: Start/pause slideshow
- **Q** / **Ctrl+C**: Quit

## 🔧 Technology Stack

| Component | Purpose |
|-----------|---------|
| **Go 1.26** | Native compilation |
| **github.com/Baozisoftware/qrcode-terminal-go** | QR rendering |
| **golang.org/x/term** | Terminal control |
| **syscall** | Terminal size detection (TIOCGWINSZ) |

## 📊 Performance

| Metric | Value |
|--------|-------|
| Binary size | ~8 MB (statically linked) |
| Dependencies | 0 (single binary) |
| Startup time | <10ms |
| Memory usage | ~5 MB |
| Default speed | 2 chunks/sec |

## 🚀 Features

- **Native binary**: No runtime dependencies
- **Fast startup**: <10ms cold start
- **Low memory**: ~5 MB RAM usage
- **Local HTTP receiver**: Accept uploads from other devices on the same network
- **Content deduplication**: Skips uploads whose bytes already exist in the output directory
- **Terminal resize**: Dynamic reflow on SIGWINCH
- **UTF-8 aware**: Proper visual width calculation
- **Progress tracking**: Resume from checkpoint

## 🧪 Testing

```bash
# Build & test
make build
./porter test-file.txt

# Cross-compile for different platforms
GOOS=linux GOARCH=amd64 go build -o porter-linux-amd64 .
GOOS=darwin GOARCH=arm64 go build -o porter-darwin-arm64 .
GOOS=windows GOARCH=amd64 go build -o porter-windows-amd64.exe .
```

## 📦 Distribution

### Creating Portable Binary
```bash
# Build statically linked binary
make build

# Test on clean system
ldd porter  # Should show "not a dynamic executable"

# Package
tar -czf porter-golang-$(go env GOOS)-$(go env GOARCH).tar.gz porter
```

### Installing System-wide
```bash
# macOS/Linux
sudo cp porter /usr/local/bin/
porter --help

# Or user-local
mkdir -p ~/.local/bin
cp porter ~/.local/bin/
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## 🐛 Troubleshooting

### Build fails with "cannot find GOROOT"
```bash
# Set GOROOT explicitly
export GOROOT=$HOME/go
export PATH=$GOROOT/bin:$PATH
go build -o porter .
```

### QR codes not displaying
- Ensure terminal supports UTF-8
- Try zooming out (terminal text size)
- Check terminal capabilities: `echo $TERM`

### Terminal resize not working
- Requires Unix-like system (Linux, macOS, BSD)
- Windows: Limited support for SIGWINCH

### Sidebar drifting left/right
- Fixed in current version using visual width calculation
- Ensure UTF-8 terminal encoding

## 🔍 Technical Details

### Terminal Size Detection
Uses `syscall.SYS_IOCTL` with `TIOCGWINSZ` to get accurate terminal dimensions:
```go
type winsize struct {
    Row    uint16
    Col    uint16
    Xpixel uint16
    Ypixel uint16
}
```

### Visual Width Calculation
Properly counts UTF-8 runes instead of bytes for accurate column positioning:
```go
visualWidth := utf8.RuneCountInString(line) // Not len(line)
```

### QR Version Formula
Calculates optimal QR version based on terminal height:
```go
N = (rows - buffer - 21) / 4
// Capped at version 15
```

### Resize Handling
Listens for `SIGWINCH` signal and recalculates chunks dynamically:
```go
signal.Notify(resize, syscall.SIGWINCH)
```

## 🤝 Contributing

See [../BUILD_GUIDE.md](../BUILD_GUIDE.md) for development workflow.

## 📄 License

ISC

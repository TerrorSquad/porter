package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"
	"unsafe"

	qrterminal "github.com/mdp/qrterminal/v3"
)

// visualWidth returns the visual column width of a string
// (rune count, not byte count - important for multi-byte chars like █)
func visualWidth(s string) int {
	return utf8.RuneCountInString(s)
}

// getTerminalSize gets the actual terminal dimensions using syscall
func getTerminalSize() (width, height int) {
	width = 80
	height = 24

	// Try to get from environment first as fallback
	if w, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && w > 0 {
		width = w
	}
	if h, err := strconv.Atoi(os.Getenv("LINES")); err == nil && h > 0 {
		height = h
	}

	// Try to get actual size from terminal
	type winsize struct {
		Row    uint16
		Col    uint16
		Xpixel uint16
		Ypixel uint16
	}

	ws := &winsize{}
	retCode, _, _ := syscall.Syscall(
		syscall.SYS_IOCTL,
		uintptr(os.Stdout.Fd()),
		uintptr(syscall.TIOCGWINSZ),
		uintptr(unsafe.Pointer(ws)),
	)

	if retCode == 0 && ws.Col > 0 && ws.Row > 0 {
		width = int(ws.Col)
		height = int(ws.Row)
	}

	return width, height
}

type RenderOptions struct {
	Speed              float64
	IsSlideshow        bool
	UseInverted        bool
	ECCLevel           string
	ShowPartProgress   bool
	TotalParts         int
	MultiQR            int // 0 means single, otherwise 1-4 codes per frame
}

type Renderer struct {
	Index        int
	Chunks       []string
	Version      int
	FileName     string
	Options      RenderOptions
	lastHeight   int
	maxSidebarCol int // Pin sidebar to prevent flutter
}

func NewRenderer(fileName string, options RenderOptions) *Renderer {
	return &Renderer{
		Index:        0,
		Chunks:       []string{},
		Version:      2,
		FileName:     fileName,
		Options:      options,
		lastHeight:   0,
		maxSidebarCol: 0,
	}
}

func (r *Renderer) SetChunks(chunks []string, version int) {
	r.Chunks = chunks
	r.Version = version
	if r.Index >= len(r.Chunks) {
		r.Index = 0
	}
}

func (r *Renderer) MoveNext() {
	step := r.Options.MultiQR
	if step == 0 {
		step = 1
	}
	if r.Index+step < len(r.Chunks) {
		r.Index += step
	} else {
		r.Index = len(r.Chunks) - 1
	}
}

func (r *Renderer) MovePrev() {
	step := r.Options.MultiQR
	if step == 0 {
		step = 1
	}
	if r.Index-step >= 0 {
		r.Index -= step
	} else {
		r.Index = 0
	}
}

type QRData struct {
	Lines      []string
	Height     int
	Payload    string
	IsChecksum bool
	PartNum    int
	PartTotal  int
}

func (r *Renderer) Draw() {
	// Just go home without clearing
	fmt.Print("\x1b[H")

	if len(r.Chunks) == 0 || r.Index >= len(r.Chunks) {
		fmt.Print("\x1b[2KNo content to display.\n")
		return
	}

	// Clear previous QR area to prevent glitches
	if r.lastHeight > 0 {
		for i := 0; i < r.lastHeight; i++ {
			fmt.Printf("\x1b[%d;1H\x1b[2K", i+1)
		}
	}

	multiQR := r.Options.MultiQR
	if multiQR == 0 {
		multiQR = 1
	}

	codesToRender := multiQR
	if r.Index+multiQR > len(r.Chunks) {
		codesToRender = len(r.Chunks) - r.Index
	}

	qrDataList := make([]QRData, 0)
	var maxQRHeight int

	for qIdx := 0; qIdx < codesToRender; qIdx++ {
		if r.Index+qIdx >= len(r.Chunks) {
			break
		}

		payload := r.Chunks[r.Index+qIdx]

		// Parse header
		isChecksum := false
		partNum := 1
		partTotal := 1

		if strings.HasPrefix(payload, "CHECKSUM|") {
			isChecksum = true
			parts := strings.Split(payload, "|")
			if len(parts) >= 3 {
				if p, err := strconv.Atoi(parts[1]); err == nil {
					partNum = p
				}
				if p, err := strconv.Atoi(parts[2]); err == nil {
					partTotal = p
				}
			}
		} else {
			// Try new format parsing
			re := regexp.MustCompile(`^(\d+)\|(\d+)\|(\d+)\|(\d+)\|([BT])\|`)
			matches := re.FindStringSubmatch(payload)
			if len(matches) > 0 {
				if p, err := strconv.Atoi(matches[3]); err == nil {
					partNum = p
				}
				if p, err := strconv.Atoi(matches[4]); err == nil {
					partTotal = p
				}
			}
		}

		// Generate QR code
		lines := generateQRTerminal(payload, r.Options.UseInverted)

		height := len(lines)
		if height > maxQRHeight {
			maxQRHeight = height
		}

		data := QRData{
			Lines:      lines,
			Height:     height,
			Payload:    payload,
			IsChecksum: isChecksum,
			PartNum:    partNum,
			PartTotal:  partTotal,
		}
		qrDataList = append(qrDataList, data)
	}

	if len(qrDataList) == 0 {
		fmt.Print("\x1b[H\x1b[2J")
		fmt.Printf("\x1b[1;31mError: Failed to generate QR code\x1b[0m\n")
		return
	}

	r.renderMultiQR(qrDataList, maxQRHeight)
}

func generateQRTerminal(text string, inverted bool) []string {
	// Use qrterminal to generate a QR code
	var buf strings.Builder
	config := qrterminal.Config{
		Level:     qrterminal.L,
		Writer:    &buf,
		BlackChar: "██",
		WhiteChar: "  ",
	}

	qrterminal.GenerateWithConfig(text, config)
	qrOutput := buf.String()
	lines := strings.Split(strings.TrimSpace(qrOutput), "\n")

	if inverted {
		for i, line := range lines {
			// Simple inversion by replacing characters
			var inverted strings.Builder
			for _, ch := range line {
				if ch == '█' {
					inverted.WriteRune(' ')
				} else {
					inverted.WriteRune('█')
				}
			}
			lines[i] = inverted.String()
		}
	}

	return lines
}

func (r *Renderer) renderMultiQR(qrDataList []QRData, maxQRHeight int) {
	minWidth := 40
	minHeight := 24

	// Get actual terminal dimensions
	tWidth, tHeight := getTerminalSize()

	if tWidth < minWidth || tHeight < minHeight {
		fmt.Print("\x1b[H\x1b[2J")
		fmt.Printf("\x1b[1;31mError: Terminal too small\x1b[0m\n")
		fmt.Printf("Current: %d×%d, Minimum: %d×%d\n", tWidth, tHeight, minWidth, minHeight)
		return
	}

	if len(qrDataList) == 0 {
		fmt.Print("\x1b[H\x1b[2J")
		fmt.Printf("\x1b[1;31mError: Failed to generate QR code\x1b[0m\n")
		return
	}

	firstLine := ""
	if len(qrDataList[0].Lines) > 0 {
		firstLine = qrDataList[0].Lines[0]
	}
	if firstLine == "" {
		fmt.Print("\x1b[H\x1b[2J")
		fmt.Printf("\x1b[1;31mError: Failed to generate QR code\x1b[0m\n")
		return
	}

	sidebarHeight := 17
	totalHeight := maxQRHeight
	if totalHeight < r.lastHeight {
		totalHeight = r.lastHeight
	}
	if totalHeight < sidebarHeight {
		totalHeight = sidebarHeight
	}
	if totalHeight < tHeight {
		totalHeight = tHeight
	}
	r.lastHeight = maxQRHeight

	// Use visual width (rune count) not byte length
	// █ is 3 bytes in UTF-8 but only 1 visual column
	// len() would give inconsistent results based on black/white pattern
	qrWidth := visualWidth(firstLine)
	gap := 2
	colPositions := make([]int, len(qrDataList))
	for i := range colPositions {
		colPositions[i] = 1 + i*(qrWidth+gap)
	}

	// Calculate total QR area width using visual columns
	totalQRWidth := 1
	if len(qrDataList) > 0 {
		lastCol := colPositions[len(qrDataList)-1]
		totalQRWidth = lastCol + qrWidth
	}

	// Sidebar starts after QR codes with at least 8 character margin (more spacing)
	// Completely fixed position relative to QR code
	sidebarCol := totalQRWidth + 8

	// Prevent horizontal fluttering during slideshows
	if sidebarCol > r.maxSidebarCol {
		r.maxSidebarCol = sidebarCol
	} else {
		sidebarCol = r.maxSidebarCol
	}

	primary := qrDataList[0]
	progress := int((float64(r.Index+1) / float64(len(r.Chunks))) * 100)

	for i := 0; i < totalHeight; i++ {
		// Move to start of line and use ANSI clear to end of line
		fmt.Printf("\x1b[%d;1H\x1b[2K", i+1)

		// Render QR codes
		for qIdx := 0; qIdx < len(qrDataList); qIdx++ {
			qrData := qrDataList[qIdx]
			colPos := colPositions[qIdx]

			if i < qrData.Height {
				fmt.Printf("\x1b[%d;%dH%s", i+1, colPos, qrData.Lines[i])
			}
		}

		sidebarText := ""

		if i == 1 {
			sidebarText = fmt.Sprintf("\x1b[1;36m📄 FILE: \x1b[0m%s", r.FileName)
		}
		if i == 2 {
			multiStr := ""
			if len(qrDataList) > 1 {
				multiStr = fmt.Sprintf(" (×%d)", len(qrDataList))
			}
			endChunk := r.Index + len(qrDataList)
			if endChunk > len(r.Chunks) {
				endChunk = len(r.Chunks)
			}

			chunkRange := fmt.Sprintf("%d", r.Index+1)
			if len(qrDataList) > 1 {
				chunkRange = fmt.Sprintf("%d–%d", r.Index+1, endChunk)
			}

			sidebarText = fmt.Sprintf("\x1b[1;32m📦 CHUNK:\x1b[0m %s / %d%s", chunkRange, len(r.Chunks), multiStr)
		}
		if i == 3 {
			sidebarText = fmt.Sprintf("\x1b[1;32m📊 PROG: \x1b[0m%d%%", progress)
		}

		if i == 5 {
			sidebarText = fmt.Sprintf("\x1b[1;33m📏 VER:  \x1b[0m%d", r.Version)
		}
		if i == 6 {
			eta := int(float64(len(r.Chunks)-r.Index) * r.Options.Speed)
			sidebarText = fmt.Sprintf("\x1b[1;33m⏳ ETA:  \x1b[0m%ds", eta)
		}
		if i == 7 {
			if primary.IsChecksum {
				sidebarText = "\x1b[1;35m✓ CHECKSUM\x1b[0m"
			} else {
				sidebarText = fmt.Sprintf("\x1b[1;35m🛡️  ECC:  \x1b[0m%s", r.Options.ECCLevel)
			}
		}

		if i == 9 {
			sidebarText = "\x1b[1;34m🕹️  CONTROLS:\x1b[0m"
		}
		if i == 10 {
			sidebarText = "   Next:  \x1b[7m L \x1b[0m or \x1b[7m → \x1b[0m"
		}
		if i == 11 {
			sidebarText = "   Back:  \x1b[7m H \x1b[0m or \x1b[7m ← \x1b[0m"
		}
		if i == 12 {
			sidebarText = "   Auto:  \x1b[7m S \x1b[0m (Toggle)"
		}
		if i == 13 {
			sidebarText = "   Quit:  \x1b[7m Q \x1b[0m"
		}

		if i == 15 {
			if r.Options.IsSlideshow {
				sidebarText = "\x1b[5;31m● STREAMING ACTIVE\x1b[0m"
			} else {
				sidebarText = ""
			}
		}

		// Render sidebar - position is already stable due to earlier clear
		if sidebarText != "" {
			fmt.Printf("\x1b[%d;%dH%s", i+1, sidebarCol, sidebarText)
		}
	}

	fmt.Printf("\x1b[%d;1H", tHeight)
}

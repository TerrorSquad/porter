package main

import (
	"bufio"
	"fmt"
	"io"
	"io/ioutil"
	"math"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "serve" {
		flags, files := parseArgs(args[1:])
		runReceiver(flags, files)
		return
	}

	flags, files := parseArgs(args)
	runSender(flags, files)
}

func parseArgs(args []string) (map[string]string, []string) {
	flags := make(map[string]string)
	files := make([]string, 0)

	for _, arg := range args {
		if strings.HasPrefix(arg, "--") {
			parts := strings.SplitN(arg[2:], "=", 2)
			if len(parts) == 2 {
				flags[parts[0]] = parts[1]
			} else {
				flags[parts[0]] = "true"
			}
		} else {
			files = append(files, arg)
		}
	}

	return flags, files
}

func runSender(flags map[string]string, files []string) {
	var content []byte
	fileName := "stream.txt"
	totalParts := 1
	providedChecksum := ""

	// Input handling
	stat, _ := os.Stdin.Stat()
	isStdin := (stat.Mode() & os.ModeCharDevice) == 0

	if isStdin && len(files) == 0 {
		// Read from stdin
		var err error
		content, err = ioutil.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading from stdin: %v\n", err)
			os.Exit(1)
		}
		fileName = "stdin-stream"
	} else if len(files) > 0 {
		firstFile := files[0]
		fileInfo, err := os.Stat(firstFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: File not found: %s\n", firstFile)
			os.Exit(1)
		}

		baseName := filepath.Base(firstFile)
		re := regexp.MustCompile(`\.part(?:\d+|[a-z]{2})$`)
		baseNameClean := re.ReplaceAllString(baseName, "")

		// Check if split files exist
		splitAware := flags["split-aware"] == "true"
		if splitAware || re.MatchString(baseName) {
			dir := filepath.Dir(firstFile)
			if dir == "" {
				dir = "."
			}

			files, _ := ioutil.ReadDir(dir)
			var partFiles []string
			for _, f := range files {
				if !f.IsDir() && strings.Contains(f.Name(), baseNameClean) && re.MatchString(f.Name()) {
					partFiles = append(partFiles, f.Name())
				}
			}

			// Sort files
			sort.Slice(partFiles, func(i, j int) bool {
				numRe := regexp.MustCompile(`\.part(\d+)$`)
				mi := numRe.FindStringSubmatch(partFiles[i])
				mj := numRe.FindStringSubmatch(partFiles[j])

				if len(mi) > 0 && len(mj) > 0 {
					ni, _ := strconv.Atoi(mi[1])
					nj, _ := strconv.Atoi(mj[1])
					return ni < nj
				}
				return partFiles[i] < partFiles[j]
			})

			totalParts = len(partFiles)

			// Read all parts
			var buffers [][]byte
			for _, pf := range partFiles {
				pPath := filepath.Join(dir, pf)
				data, err := ioutil.ReadFile(pPath)
				if err != nil {
					fmt.Fprintf(os.Stderr, "Error reading file %s: %v\n", pf, err)
					os.Exit(1)
				}
				buffers = append(buffers, data)
			}

			// Concatenate
			for _, b := range buffers {
				content = append(content, b...)
			}

			if strings.HasSuffix(baseNameClean, ".tar.xz.enc") {
				fileName = baseNameClean
			} else {
				fileName = baseNameClean + ".enc"
			}

			// Try to load checksum
			checksumPath := baseNameClean + ".sha256"
			if data, err := ioutil.ReadFile(checksumPath); err == nil {
				parts := strings.Split(string(data), "  ")
				providedChecksum = parts[0]
			}
		} else {
			// Single file
			var err error
			content, err = ioutil.ReadFile(firstFile)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Error reading file: %v\n", err)
				os.Exit(1)
			}
			fileName = fileInfo.Name()
		}
	} else {
		// Show usage
		showUsage()
		os.Exit(1)
	}

	if len(content) == 0 {
		fmt.Fprintf(os.Stderr, "Error: Input is empty.\n")
		os.Exit(1)
	}

	// Parse configuration
	isSlideshow := flags["slideshow"] == "true"
	useBase64 := flags["base64"] == "true"
	useInverted := flags["invert"] == "true"

	speed := 0.5
	if s, ok := flags["speed"]; ok {
		if f, err := strconv.ParseFloat(s, 64); err == nil {
			speed = f
		}
	}

	buffer := 2
	if b, ok := flags["buffer"]; ok {
		if i, err := strconv.Atoi(b); err == nil {
			buffer = i
		}
	}

	eccLevel := "L"
	if e, ok := flags["ecc"]; ok && strings.ContainsAny(strings.ToUpper(e), "LMQH") {
		eccLevel = strings.ToUpper(e)
	}

	// Parse multi-QR option
	multiQR := 0
	if m, ok := flags["multi"]; ok {
		if strings.ToLower(m) == "auto" {
			// Auto-detect based on terminal width
			termWidth, _ := getTerminalSize()
			multiQR = int(math.Max(1, math.Min(4, float64(termWidth/31))))
		} else {
			if i, err := strconv.Atoi(m); err == nil && i >= 1 && i <= 4 {
				multiQR = i
			}
		}
	}

	// Verify checksum flag
	if checksumFile, ok := flags["verify"]; ok {
		if data, err := ioutil.ReadFile(checksumFile); err == nil {
			parts := strings.Split(string(data), "  ")
			providedChecksum = parts[0]
		}
	}

	// Determine if we should add checksum
	addChecksum := false
	if providedChecksum != "" {
		addChecksum = true
	} else if totalParts > 1 {
		addChecksum = true
	}

	// Create chunker
	_, termH := getTerminalSize()
	chunker := NewChunker(content)
	chunkOpts := ChunkOptions{
		Buffer:      buffer,
		UseBase64:   useBase64,
		AddHeader:   true,
		ECCLevel:    eccLevel,
		CurrentPart: intPtr(totalParts > 1, 1),
		TotalParts:  intPtr(totalParts > 1, totalParts),
		AddChecksum: addChecksum,
	}
	chunker.CalculateLayout(termH, chunkOpts)

	// Create renderer
	renderer := NewRenderer(fileName, RenderOptions{
		Speed:            speed,
		IsSlideshow:      isSlideshow,
		UseInverted:      useInverted,
		ECCLevel:         eccLevel,
		ShowPartProgress: totalParts > 1,
		TotalParts:       totalParts,
		MultiQR:          multiQR,
	})

	renderer.SetChunks(chunker.Chunks, chunker.Version)

	// Restore progress
	if _, ok := flags["reset"]; !ok {
		sm := &StateManager{}
		savedIndex := sm.LoadProgress(fileName)
		if savedIndex > 0 && savedIndex < len(chunker.Chunks) {
			renderer.Index = savedIndex
		}
	}

	// Setup terminal for raw input
	setupTerminal()
	defer restoreTerminal()

	// Clear screen
	fmt.Print("\x1b[2J\x1b[H")

	// Initial draw
	renderer.Draw()

	// Input handling
	inputChan := make(chan rune)
	go readInput(inputChan)

	// Handle terminal resize
	resizeChan := make(chan os.Signal, 1)
	signal.Notify(resizeChan, syscall.SIGWINCH)
	go func() {
		for range resizeChan {
			// Recalculate chunks based on new terminal height
			_, newH := getTerminalSize()
			oldTotal := len(chunker.Chunks)
			chunker.CalculateLayout(newH, chunkOpts)
			renderer.SetChunks(chunker.Chunks, chunker.Version)
			// Reset sidebar pin since dimensions changed
			renderer.maxSidebarCol = 0
			// Adjust index proportionally if chunk count changed
			if oldTotal > 0 && len(chunker.Chunks) != oldTotal {
				progress := float64(renderer.Index) / float64(oldTotal)
				newIndex := int(progress * float64(len(chunker.Chunks)))
				if newIndex >= len(chunker.Chunks) {
					newIndex = len(chunker.Chunks) - 1
				}
				if newIndex < 0 {
					newIndex = 0
				}
				renderer.Index = newIndex
			}
			// Clear and redraw
			fmt.Print("\x1b[2J\x1b[H")
			renderer.Draw()
		}
	}()

	// Slideshow ticker
	ticker := time.NewTicker(time.Duration(speed*1000) * time.Millisecond)
	defer ticker.Stop()

	frameCount := 0
	sm := &StateManager{}

	for {
		select {
		case key := <-inputChan:
			switch key {
			case 'l', 'k', ' ', 'L':
				// Next
				renderer.MoveNext()
				renderer.Draw()
				sm.SaveProgress(fileName, renderer.Index)

			case 'h', 'j', 'H':
				// Previous
				renderer.MovePrev()
				renderer.Draw()
				sm.SaveProgress(fileName, renderer.Index)

			case 'q', 'Q', 3: // 3 = Ctrl+C
				fmt.Print("\x1b[2J\x1b[H")
				fmt.Println("Stopped.")
				sm.SaveProgress(fileName, renderer.Index)
				return

			case 's', 'S':
				if !renderer.Options.IsSlideshow {
					// Start slideshow with countdown
					showCountdown(renderer, fileName, sm)
				} else {
					// Stop slideshow
					renderer.Options.IsSlideshow = false
					renderer.Draw()
					sm.SaveProgress(fileName, renderer.Index)
				}
			}

		case <-ticker.C:
			if renderer.Options.IsSlideshow {
				if renderer.Index >= len(renderer.Chunks)-1 {
					renderer.Index = -1
				}
				renderer.MoveNext()
				renderer.Draw()

				frameCount++
				if frameCount%20 == 0 {
					sm.SaveProgress(fileName, renderer.Index)
				}
			}
		}
	}
}

func showUsage() {
	fmt.Println("\x1b[1mQR DATA PORTER\x1b[0m")
	fmt.Println("Usage:")
	fmt.Println("  porter <file> [options]")
	fmt.Println("  porter <file.part*.txt|file.partaa|...> [options]")
	fmt.Println("  echo 'data' | porter [options]")
	fmt.Println("  porter serve [options]")
	fmt.Println("\nOptions:")
	fmt.Println("  --slideshow       Start in slideshow mode")
	fmt.Println("  --base64          Enable Base64 encoding (for binary files)")
	fmt.Println("  --verify=<file>   Verify against SHA256 checksum file")
	fmt.Println("  --split-aware     Auto-detect and concatenate .part*.txt or .partaa files")
	fmt.Println("  --invert          Invert QR code colors")
	fmt.Println("  --ecc=L|M|Q|H     Error correction level (Default: L)")
	fmt.Println("  --multi=N|auto    Render N QR codes side-by-side (1-4, or 'auto')")
	fmt.Println("                    Speeds up transfer: auto-detected or manual")
	fmt.Println("  --speed=<seconds> QR code delay (Default: 0.5)")
	fmt.Println("                    0.5 = 2 chunks/sec (default, works everywhere)")
	fmt.Println("                    0.3 = 3.3 chunks/sec (good lighting)")
	fmt.Println("                    0.2 = 5 chunks/sec (bright light + steady)")
	fmt.Println("                    0.1 = 10 chunks/sec (optimal conditions)")
	fmt.Println("  --buffer=10       Vertical buffer lines")
	fmt.Println("\nServe Mode:")
	fmt.Println("  --host=0.0.0.0         Listen address for HTTP uploads")
	fmt.Println("  --port=8080            Listen port for HTTP uploads")
	fmt.Println("  --output-dir=received  Directory to save uploaded files")
}

func showCountdown(renderer *Renderer, fileName string, sm *StateManager) {
	termWidth, termHeight := getTerminalSize()

	centerRow := termHeight / 2
	centerCol := termWidth/2 - 1

	countdownHelper(3, centerRow, centerCol, renderer, fileName, sm)
}

func countdownHelper(c, centerRow, centerCol int, renderer *Renderer, fileName string, sm *StateManager) {
	if c < 0 {
		// Clear countdown and start slideshow
		fmt.Printf("\x1b[%d;%dH\x1b[2K\x1b[H", centerRow, centerCol)
		renderer.Options.IsSlideshow = true
		renderer.Draw()
		sm.SaveProgress(fileName, renderer.Index)
		return
	}

	fmt.Printf("\x1b[%d;%dH\x1b[1;33m%d\x1b[0m", centerRow, centerCol, c)
	time.Sleep(1000 * time.Millisecond)
	countdownHelper(c-1, centerRow, centerCol, renderer, fileName, sm)
}

func readInput(ch chan rune) {
	reader := bufio.NewReader(os.Stdin)
	for {
		r, _, err := reader.ReadRune()
		if err != nil && err != io.EOF {
			break
		}
		if r > 0 {
			// Handle escape sequences for arrow keys
			if r == 27 { // ESC
				next, _, _ := reader.ReadRune()
				if next == '[' {
					arrow, _, _ := reader.ReadRune()
					switch arrow {
					case 'C': // Right arrow
						ch <- 'l' // Next
					case 'D': // Left arrow
						ch <- 'h' // Previous
					}
				}
			} else {
				ch <- r
			}
		}
	}
}

var oldState *term.State

func setupTerminal() {
	var err error
	oldState, err = term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		// If we can't get raw mode, that's okay - will still work
	}
}

func restoreTerminal() {
	if oldState != nil {
		term.Restore(int(os.Stdin.Fd()), oldState)
	}
}

func intPtr(cond bool, val int) *int {
	if cond {
		return &val
	}
	return nil
}

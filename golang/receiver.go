package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

type uploadResult struct {
	FileName     string `json:"fileName"`
	Path         string `json:"path"`
	Size         int64  `json:"size"`
	Duplicate    bool   `json:"duplicate"`
	ExistingPath string `json:"existingPath,omitempty"`
	SHA256       string `json:"sha256,omitempty"`
}

type qrScanUpload struct {
	Content string `json:"content"`
	Raw     string `json:"raw"`
	Format  string `json:"format"`
}

type qrChunkUpload struct {
	Index      int
	Total      int
	Mode       string
	ID         string
	Payload    []byte
	IsChecksum bool
	Checksum   string
}

func runReceiver(flags map[string]string, files []string) {
	if len(files) > 0 {
		fmt.Fprintln(os.Stderr, "Error: serve mode does not accept positional arguments.")
		os.Exit(1)
	}

	host := strings.TrimSpace(flags["host"])
	if host == "" {
		host = "0.0.0.0"
	}

	port := strings.TrimSpace(flags["port"])
	if port == "" {
		port = "8080"
	}

	outputDir := strings.TrimSpace(flags["output-dir"])
	if outputDir == "" {
		outputDir = "received"
	}

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Error creating output directory: %v\n", err)
		os.Exit(1)
	}

	absOutputDir, err := filepath.Abs(outputDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error resolving output directory: %v\n", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		setCORSHeaders(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "Use POST /upload to send data.", http.StatusMethodNotAllowed)
			return
		}

		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "Porter receiver is running.\n\nPOST raw bytes to /upload?filename=name.bin\n")
		fmt.Fprintf(w, "Or send multipart/form-data with a file field to /upload\n\n")
		fmt.Fprintf(w, "Duplicate uploads are skipped automatically based on file content.\n")
		fmt.Fprintf(w, "QR scan JSON uploads are unpacked into joinable files like <id>.partaa, <id>.partab, ...\n")
		fmt.Fprintf(w, "Saving uploads to: %s\n", absOutputDir)
	})
	mux.HandleFunc("/upload", makeUploadHandler(absOutputDir))

	server := &http.Server{
		Addr:    net.JoinHostPort(host, port),
		Handler: requestLogger(mux),
	}

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-shutdown
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}()

	fmt.Printf("Porter receiver listening on %s\n", server.Addr)
	fmt.Printf("Saving uploads to %s\n", absOutputDir)
	for _, url := range listenURLs(host, port) {
		fmt.Printf("  %s\n", url)
	}
	fmt.Println("Examples:")
	fmt.Printf("  curl --data-binary @file.txt http://127.0.0.1:%s/upload?filename=file.txt\n", port)
	fmt.Printf("  curl -F file=@photo.jpg http://127.0.0.1:%s/upload\n", port)

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Receiver stopped.")
}

func makeUploadHandler(outputDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setCORSHeaders(w)
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "POST required", http.StatusMethodNotAllowed)
			return
		}

		var (
			result uploadResult
			err    error
		)

		contentType := r.Header.Get("Content-Type")
		if strings.HasPrefix(contentType, "multipart/form-data") {
			result, err = saveMultipartUpload(r, outputDir)
		} else {
			result, err = saveRawUpload(r, outputDir)
		}

		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	}
}

func saveMultipartUpload(r *http.Request, outputDir string) (uploadResult, error) {
	reader, err := r.MultipartReader()
	if err != nil {
		return uploadResult{}, fmt.Errorf("invalid multipart upload: %w", err)
	}

	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return uploadResult{}, fmt.Errorf("reading multipart upload: %w", err)
		}
		if part.FileName() == "" {
			continue
		}

		fileName := fallbackFileName(sanitizeFilename(part.FileName()), r.Header.Get("Content-Type"))
		return storeUpload(outputDir, fileName, part)
	}

	return uploadResult{}, errors.New("no file field found in multipart upload")
}

func saveRawUpload(r *http.Request, outputDir string) (uploadResult, error) {
	requested := sanitizeFilename(requestedFileName(r))
	fileName := fallbackFileName(requested, r.Header.Get("Content-Type"))
	return storeUpload(outputDir, fileName, r.Body)
}

func storeUpload(outputDir string, fileName string, src io.Reader) (uploadResult, error) {
	tempFile, err := os.CreateTemp(outputDir, ".upload-*")
	if err != nil {
		return uploadResult{}, fmt.Errorf("creating temporary file: %w", err)
	}
	tempPath := tempFile.Name()
	defer func() {
		tempFile.Close()
		if tempPath != "" {
			os.Remove(tempPath)
		}
	}()

	written, err := io.Copy(tempFile, src)
	if err != nil {
		return uploadResult{}, fmt.Errorf("writing upload: %w", err)
	}
	if written == 0 {
		return uploadResult{}, errors.New("request body is empty")
	}

	if err := tempFile.Close(); err != nil {
		return uploadResult{}, fmt.Errorf("closing upload: %w", err)
	}

	qrResult, handled, err := storeQRPayloadUpload(outputDir, tempPath)
	if err != nil {
		return uploadResult{}, err
	}
	if handled {
		return qrResult, nil
	}

	checksum, err := dedupeSHA256(tempPath)
	if err != nil {
		return uploadResult{}, err
	}
	existingPath, err := findDuplicateByHash(outputDir, tempPath, checksum, written)
	if err != nil {
		return uploadResult{}, err
	}
	if existingPath != "" {
		fmt.Printf("Skipped duplicate upload %s (matches %s)\n", fileName, existingPath)
		return uploadResult{
			FileName:     filepath.Base(existingPath),
			Path:         existingPath,
			Size:         written,
			Duplicate:    true,
			ExistingPath: existingPath,
			SHA256:       checksum,
		}, nil
	}

	fullPath, err := uniqueDestination(outputDir, fileName)
	if err != nil {
		return uploadResult{}, err
	}
	if err := os.Rename(tempPath, fullPath); err != nil {
		return uploadResult{}, fmt.Errorf("moving upload into place: %w", err)
	}
	tempPath = ""

	fmt.Printf("Saved upload %s (%d bytes, sha256=%s)\n", fullPath, written, checksum)
	return uploadResult{
		FileName: filepath.Base(fullPath),
		Path:     fullPath,
		Size:     written,
		SHA256:   checksum,
	}, nil
}

func storeQRPayloadUpload(outputDir string, uploadPath string) (uploadResult, bool, error) {
	upload, handled, err := readQRScanUpload(uploadPath)
	if err != nil || !handled {
		return uploadResult{}, handled, err
	}

	chunk, err := parseQRChunkUpload(upload)
	if err != nil {
		return uploadResult{}, true, err
	}

	result, err := writeChunkUpload(outputDir, chunk)
	if err != nil {
		return uploadResult{}, true, err
	}

	return result, true, nil
}

func readQRScanUpload(path string) (qrScanUpload, bool, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return qrScanUpload{}, false, fmt.Errorf("reading upload for QR extraction: %w", err)
	}

	trimmed := bytes.TrimSpace(content)
	if len(trimmed) == 0 {
		return qrScanUpload{}, false, nil
	}

	var upload qrScanUpload
	if err := json.Unmarshal(trimmed, &upload); err != nil {
		return qrScanUpload{}, false, nil
	}

	if strings.TrimSpace(upload.Raw) == "" && strings.TrimSpace(upload.Content) == "" {
		return qrScanUpload{}, false, nil
	}

	if strings.TrimSpace(upload.Format) != "" && upload.Format != "QR_CODE" {
		return qrScanUpload{}, false, nil
	}

	return upload, true, nil
}

func parseQRChunkUpload(upload qrScanUpload) (qrChunkUpload, error) {
	rawBytes, err := qrUploadBytes(upload)
	if err != nil {
		return qrChunkUpload{}, err
	}

	if bytes.HasPrefix(rawBytes, []byte("CHECKSUM|")) {
		parts := bytes.SplitN(rawBytes, []byte("|"), 4)
		if len(parts) != 4 {
			return qrChunkUpload{}, errors.New("invalid checksum chunk format")
		}

		mode := string(parts[1])
		if mode != "T" {
			return qrChunkUpload{}, fmt.Errorf("unsupported checksum mode %q", mode)
		}

		chunkID := string(parts[2])
		if err := validateChunkID(chunkID); err != nil {
			return qrChunkUpload{}, err
		}

		checksum := strings.TrimSpace(string(parts[3]))
		if checksum == "" {
			return qrChunkUpload{}, errors.New("checksum chunk is empty")
		}

		return qrChunkUpload{
			Mode:       mode,
			ID:         chunkID,
			IsChecksum: true,
			Checksum:   checksum,
		}, nil
	}

	parts := bytes.SplitN(rawBytes, []byte("|"), 5)
	if len(parts) != 5 {
		return qrChunkUpload{}, errors.New("invalid chunk format")
	}

	index, err := strconv.Atoi(string(parts[0]))
	if err != nil || index < 1 {
		return qrChunkUpload{}, errors.New("invalid chunk index")
	}

	total, err := strconv.Atoi(string(parts[1]))
	if err != nil || total < 1 {
		return qrChunkUpload{}, errors.New("invalid chunk total")
	}

	mode := string(parts[2])
	chunkID := string(parts[3])
	if err := validateChunkID(chunkID); err != nil {
		return qrChunkUpload{}, err
	}

	payload, err := decodeChunkPayload(mode, parts[4])
	if err != nil {
		return qrChunkUpload{}, err
	}

	return qrChunkUpload{
		Index:   index,
		Total:   total,
		Mode:    mode,
		ID:      chunkID,
		Payload: payload,
	}, nil
}

func qrUploadBytes(upload qrScanUpload) ([]byte, error) {
	if strings.TrimSpace(upload.Raw) != "" {
		decoded, err := hex.DecodeString(strings.TrimSpace(upload.Raw))
		if err != nil {
			return nil, fmt.Errorf("invalid QR raw payload: %w", err)
		}
		return decoded, nil
	}

	if upload.Content == "" {
		return nil, errors.New("QR payload is empty")
	}

	return []byte(upload.Content), nil
}

func validateChunkID(chunkID string) error {
	if utf8.RuneCountInString(chunkID) != 2 {
		return fmt.Errorf("invalid chunk id %q: expected exactly 2 characters", chunkID)
	}
	return nil
}

func decodeChunkPayload(mode string, encoded []byte) ([]byte, error) {
	switch mode {
	case "T":
		return append([]byte(nil), encoded...), nil
	case "B":
		decoded, err := base64.StdEncoding.DecodeString(string(encoded))
		if err != nil {
			return nil, fmt.Errorf("invalid base64 payload: %w", err)
		}
		return decoded, nil
	default:
		return nil, fmt.Errorf("unsupported chunk mode %q", mode)
	}
}

func writeChunkUpload(outputDir string, chunk qrChunkUpload) (uploadResult, error) {
	fileName := chunkFileName(chunk)
	fullPath := filepath.Join(outputDir, fileName)

	content, err := chunkFileContent(chunk)
	if err != nil {
		return uploadResult{}, err
	}

	checksum := sha256.Sum256(content)
	checksumText := hex.EncodeToString(checksum[:])

	if existing, err := os.ReadFile(fullPath); err == nil {
		if bytes.Equal(existing, content) {
			fmt.Printf("Skipped duplicate chunk %s\n", fullPath)
			return uploadResult{
				FileName:     fileName,
				Path:         fullPath,
				Size:         int64(len(content)),
				Duplicate:    true,
				ExistingPath: fullPath,
				SHA256:       checksumText,
			}, nil
		}
		return uploadResult{}, fmt.Errorf("conflicting content already exists at %s", fullPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return uploadResult{}, fmt.Errorf("checking existing chunk file: %w", err)
	}

	if err := os.WriteFile(fullPath, content, 0644); err != nil {
		return uploadResult{}, fmt.Errorf("writing chunk payload file: %w", err)
	}

	fmt.Printf("Saved chunk payload %s (%d bytes, sha256=%s)\n", fullPath, len(content), checksumText)
	return uploadResult{
		FileName: fileName,
		Path:     fullPath,
		Size:     int64(len(content)),
		SHA256:   checksumText,
	}, nil
}

func chunkFileName(chunk qrChunkUpload) string {
	base := chunkFileBase(chunk.ID)
	if chunk.IsChecksum {
		return fmt.Sprintf("%s.sha256", base)
	}
	return fmt.Sprintf("%s.part%s", base, alphaPartSuffix(chunk.Index-1))
}

func chunkFileBase(chunkID string) string {
	cleaned := strings.Map(func(r rune) rune {
		switch {
		case r == '/':
			return '_'
		case r == '\\':
			return '_'
		case r < 32:
			return '_'
		default:
			return r
		}
	}, chunkID)
	cleaned = strings.TrimSpace(cleaned)
	if cleaned == "" {
		return "chunk"
	}
	return cleaned
}

func alphaPartSuffix(index int) string {
	if index < 0 {
		return "aa"
	}

	value := index
	suffix := ""
	for {
		suffix = string(rune('a'+(value%26))) + suffix
		value /= 26
		if value == 0 {
			break
		}
	}

	for len(suffix) < 2 {
		suffix = "a" + suffix
	}

	return suffix
}

func chunkFileContent(chunk qrChunkUpload) ([]byte, error) {
	if chunk.IsChecksum {
		return []byte(chunk.Checksum + "\n"), nil
	}
	return chunk.Payload, nil
}

func findDuplicateByHash(outputDir string, ignoredPath string, checksum string, size int64) (string, error) {
	entries, err := os.ReadDir(outputDir)
	if err != nil {
		return "", fmt.Errorf("reading output directory: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		candidatePath := filepath.Join(outputDir, entry.Name())
		if candidatePath == ignoredPath {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			return "", fmt.Errorf("reading file info: %w", err)
		}
		if info.Size() != size {
			continue
		}

		candidateHash, err := dedupeSHA256(candidatePath)
		if err != nil {
			return "", err
		}
		if candidateHash == checksum {
			return candidatePath, nil
		}
	}

	return "", nil
}

func dedupeSHA256(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading upload for dedupe: %w", err)
	}

	normalized := normalizedDedupeBytes(content)
	hash := sha256.Sum256(normalized)
	return hex.EncodeToString(hash[:]), nil
}

func normalizedDedupeBytes(content []byte) []byte {
	trimmed := bytes.TrimSpace(content)
	if len(trimmed) == 0 {
		return trimmed
	}

	var payload any
	if err := json.Unmarshal(trimmed, &payload); err != nil {
		return trimmed
	}

	normalized := normalizeDedupePayload(payload)
	encoded, err := json.Marshal(normalized)
	if err != nil {
		return trimmed
	}

	return encoded
}

func normalizeDedupePayload(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		format, _ := typed["format"].(string)
		if raw, ok := typed["raw"].(string); ok && strings.TrimSpace(raw) != "" {
			if strings.TrimSpace(format) != "" {
				return map[string]string{"format": format, "raw": raw}
			}
			return map[string]string{"raw": raw}
		}
		if content, ok := typed["content"].(string); ok && strings.TrimSpace(content) != "" {
			if strings.TrimSpace(format) != "" {
				return map[string]string{"format": format, "content": content}
			}
			return map[string]string{"content": content}
		}

		normalized := make(map[string]any, len(typed))
		for key, item := range typed {
			if key == "timestamp" {
				continue
			}
			normalized[key] = normalizeDedupePayload(item)
		}
		return normalized
	case []any:
		normalized := make([]any, len(typed))
		for index, item := range typed {
			normalized[index] = normalizeDedupePayload(item)
		}
		return normalized
	default:
		return value
	}
}

func requestedFileName(r *http.Request) string {
	if name := strings.TrimSpace(r.URL.Query().Get("filename")); name != "" {
		return name
	}
	if name := strings.TrimSpace(r.Header.Get("X-Filename")); name != "" {
		return name
	}
	if disposition := r.Header.Get("Content-Disposition"); disposition != "" {
		_, params, err := mime.ParseMediaType(disposition)
		if err == nil {
			return params["filename"]
		}
	}
	return ""
}

func sanitizeFilename(name string) string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return ""
	}
	return filepath.Base(strings.ReplaceAll(trimmed, "\\", "/"))
}

func fallbackFileName(name string, contentType string) string {
	if name != "" {
		return name
	}

	ext := ".bin"
	if mediaType, _, err := mime.ParseMediaType(contentType); err == nil {
		if exts, extErr := mime.ExtensionsByType(mediaType); extErr == nil && len(exts) > 0 {
			ext = exts[0]
		}
	}

	return fmt.Sprintf("upload-%s%s", time.Now().Format("20060102-150405"), ext)
}

func uniqueDestination(dir string, name string) (string, error) {
	base := strings.TrimSuffix(name, filepath.Ext(name))
	ext := filepath.Ext(name)
	if base == "" {
		base = "upload"
	}

	path := filepath.Join(dir, name)
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return path, nil
	}

	for i := 2; ; i++ {
		candidate := filepath.Join(dir, fmt.Sprintf("%s-%d%s", base, i, ext))
		if _, err := os.Stat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate, nil
		}
	}
}

func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Printf("%s %s from %s\n", r.Method, r.URL.Path, r.RemoteAddr)
		next.ServeHTTP(w, r)
	})
}

func setCORSHeaders(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Filename")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
}

func listenURLs(host string, port string) []string {
	if host != "" && host != "0.0.0.0" && host != "::" {
		return []string{fmt.Sprintf("http://%s:%s/upload", host, port)}
	}

	urls := []string{fmt.Sprintf("http://127.0.0.1:%s/upload", port)}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return urls
	}

	seen := map[string]bool{}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP.IsLoopback() {
			continue
		}
		ip := ipNet.IP.To4()
		if ip == nil {
			continue
		}
		url := fmt.Sprintf("http://%s:%s/upload", ip.String(), port)
		if !seen[url] {
			seen[url] = true
			urls = append(urls, url)
		}
	}

	return urls
}

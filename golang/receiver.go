package main

import (
	"context"
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
	"strings"
	"syscall"
	"time"
)

type uploadResult struct {
	FileName string `json:"fileName"`
	Path     string `json:"path"`
	Size     int64  `json:"size"`
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
			fileName string
			fullPath string
			size     int64
			err      error
		)

		contentType := r.Header.Get("Content-Type")
		if strings.HasPrefix(contentType, "multipart/form-data") {
			fileName, fullPath, size, err = saveMultipartUpload(r, outputDir)
		} else {
			fileName, fullPath, size, err = saveRawUpload(r, outputDir)
		}

		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(uploadResult{
			FileName: fileName,
			Path:     fullPath,
			Size:     size,
		})
	}
}

func saveMultipartUpload(r *http.Request, outputDir string) (string, string, int64, error) {
	reader, err := r.MultipartReader()
	if err != nil {
		return "", "", 0, fmt.Errorf("invalid multipart upload: %w", err)
	}

	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", "", 0, fmt.Errorf("reading multipart upload: %w", err)
		}
		if part.FileName() == "" {
			continue
		}

		fileName := fallbackFileName(sanitizeFilename(part.FileName()), r.Header.Get("Content-Type"))
		fullPath, err := uniqueDestination(outputDir, fileName)
		if err != nil {
			return "", "", 0, err
		}

		written, err := copyToFile(fullPath, part)
		if err != nil {
			return "", "", 0, err
		}

		fmt.Printf("Saved upload %s (%d bytes)\n", fullPath, written)
		return filepath.Base(fullPath), fullPath, written, nil
	}

	return "", "", 0, errors.New("no file field found in multipart upload")
}

func saveRawUpload(r *http.Request, outputDir string) (string, string, int64, error) {
	requested := sanitizeFilename(requestedFileName(r))
	fileName := fallbackFileName(requested, r.Header.Get("Content-Type"))
	fullPath, err := uniqueDestination(outputDir, fileName)
	if err != nil {
		return "", "", 0, err
	}

	written, err := copyToFile(fullPath, r.Body)
	if err != nil {
		return "", "", 0, err
	}

	if written == 0 {
		os.Remove(fullPath)
		return "", "", 0, errors.New("request body is empty")
	}

	fmt.Printf("Saved upload %s (%d bytes)\n", fullPath, written)
	return filepath.Base(fullPath), fullPath, written, nil
}

func copyToFile(path string, src io.Reader) (int64, error) {
	file, err := os.Create(path)
	if err != nil {
		return 0, fmt.Errorf("creating destination file: %w", err)
	}
	defer file.Close()

	written, err := io.Copy(file, src)
	if err != nil {
		return 0, fmt.Errorf("writing upload: %w", err)
	}

	return written, nil
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

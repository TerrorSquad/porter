package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func runJoin(flags map[string]string, files []string) {
	if len(files) != 1 {
		fmt.Fprintln(os.Stderr, "Error: join mode expects exactly one transfer id or transfer file path.")
		os.Exit(1)
	}

	sourceDir := strings.TrimSpace(flags["dir"])
	if sourceDir == "" {
		sourceDir = "."
	}

	transferID, resolvedDir, err := resolveJoinSource(files[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	if resolvedDir != "" {
		sourceDir = resolvedDir
	}

	sourceDir = resolveTransferRoot(sourceDir, transferID)

	manifest, manifestPath, err := loadOrBuildTransferManifest(sourceDir, transferID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	transferDir := transferDirectory(sourceDir, manifest.ID)
	if len(manifest.PartFiles) == 0 {
		fmt.Fprintf(os.Stderr, "Error: no chunk files found for transfer %q in %s\n", transferID, transferDir)
		os.Exit(1)
	}
	if len(manifest.MissingParts) > 0 {
		fmt.Fprintf(os.Stderr, "Error: transfer %q is incomplete; missing parts %v\n", manifest.ID, manifest.MissingParts)
		os.Exit(1)
	}

	outputPath := strings.TrimSpace(flags["output"])
	if outputPath == "" {
		outputPath = transferJoinPath(sourceDir, manifest.ID)
	}

	if err := ensureJoinOutputPath(outputPath, transferDir, manifest.PartFiles, flags["force"] == "true"); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	joinedHash, err := joinTransferFiles(transferDir, manifest, outputPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if manifest.Checksum != "" && !strings.EqualFold(joinedHash, manifest.Checksum) {
		os.Remove(outputPath)
		fmt.Fprintf(os.Stderr, "Error: checksum mismatch for %q: joined=%s expected=%s\n", manifest.ID, joinedHash, manifest.Checksum)
		os.Exit(1)
	}

	fmt.Printf("Joined %d parts into %s\n", len(manifest.PartFiles), outputPath)
	if manifest.Checksum != "" {
		fmt.Printf("Verified SHA256: %s\n", joinedHash)
	} else {
		fmt.Printf("SHA256: %s\n", joinedHash)
	}
	fmt.Printf("Manifest: %s\n", manifestPath)
}

func resolveJoinSource(source string) (string, string, error) {
	trimmed := strings.TrimSpace(source)
	if trimmed == "" {
		return "", "", fmt.Errorf("join source cannot be empty")
	}

	if info, err := os.Stat(trimmed); err == nil {
		if info.IsDir() {
			return chunkFileBase(filepath.Base(trimmed)), filepath.Dir(trimmed), nil
		}
		return transferIDFromPath(trimmed)
	}

	if strings.Contains(trimmed, string(filepath.Separator)) {
		return transferIDFromPath(trimmed)
	}

	return chunkFileBase(trimmed), "", nil
}

func resolveTransferRoot(sourceDir string, transferID string) string {
	transferDir := transferDirectory(sourceDir, transferID)
	if info, err := os.Stat(transferDir); err == nil && info.IsDir() {
		return sourceDir
	}
	legacyManifest := filepath.Join(sourceDir, fmt.Sprintf("%s.meta.json", chunkFileBase(transferID)))
	if _, err := os.Stat(legacyManifest); err == nil {
		return sourceDir
	}
	return sourceDir
}

func transferIDFromPath(path string) (string, string, error) {
	baseName := filepath.Base(path)
	dirName := filepath.Dir(path)
	for _, suffix := range []string{".meta.json", ".sha256"} {
		if strings.HasSuffix(baseName, suffix) {
			return chunkFileBase(strings.TrimSuffix(baseName, suffix)), dirName, nil
		}
	}
	if idx := strings.Index(baseName, ".part"); idx > 0 {
		return chunkFileBase(baseName[:idx]), dirName, nil
	}
	if baseName == "" {
		return "", "", fmt.Errorf("could not derive transfer id from %q", path)
	}
	return chunkFileBase(baseName), dirName, nil
}

func ensureJoinOutputPath(outputPath string, sourceDir string, partFiles []string, force bool) error {
	outputAbs, err := filepath.Abs(outputPath)
	if err != nil {
		return fmt.Errorf("resolving output path: %w", err)
	}

	for _, partFile := range partFiles {
		partAbs, err := filepath.Abs(filepath.Join(sourceDir, partFile))
		if err != nil {
			return fmt.Errorf("resolving part path: %w", err)
		}
		if partAbs == outputAbs {
			return fmt.Errorf("output path %s overlaps an input part file", outputPath)
		}
	}

	if _, err := os.Stat(outputPath); err == nil {
		if !force {
			return fmt.Errorf("output file %s already exists; use --force to overwrite", outputPath)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("checking output path: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(outputPath), 0755); err != nil {
		return fmt.Errorf("creating output directory: %w", err)
	}

	return nil
}

func joinTransferFiles(sourceDir string, manifest transferManifest, outputPath string) (string, error) {
	tempFile, err := os.CreateTemp(filepath.Dir(outputPath), ".porter-join-*")
	if err != nil {
		return "", fmt.Errorf("creating temporary output: %w", err)
	}
	tempPath := tempFile.Name()
	defer func() {
		tempFile.Close()
		os.Remove(tempPath)
	}()

	hasher := sha256.New()
	writer := io.MultiWriter(tempFile, hasher)

	for _, partFile := range manifest.PartFiles {
		partPath := filepath.Join(sourceDir, partFile)
		partHandle, err := os.Open(partPath)
		if err != nil {
			return "", fmt.Errorf("opening %s: %w", partPath, err)
		}
		if _, err := io.Copy(writer, partHandle); err != nil {
			partHandle.Close()
			return "", fmt.Errorf("copying %s: %w", partPath, err)
		}
		partHandle.Close()
	}

	if err := tempFile.Close(); err != nil {
		return "", fmt.Errorf("closing output: %w", err)
	}

	if _, err := os.Stat(outputPath); err == nil {
		if err := os.Remove(outputPath); err != nil {
			return "", fmt.Errorf("removing existing output: %w", err)
		}
	}

	if err := os.Rename(tempPath, outputPath); err != nil {
		return "", fmt.Errorf("moving joined file into place: %w", err)
	}
	tempPath = ""

	return hex.EncodeToString(hasher.Sum(nil)), nil
}
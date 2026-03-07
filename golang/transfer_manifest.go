package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type transferManifest struct {
	ID               string   `json:"id"`
	Directory        string   `json:"directory,omitempty"`
	TotalParts       int      `json:"totalParts,omitempty"`
	ReceivedParts    int      `json:"receivedParts"`
	MissingParts     []int    `json:"missingParts,omitempty"`
	PartFiles        []string `json:"partFiles,omitempty"`
	Checksum         string   `json:"checksum,omitempty"`
	ChecksumFile     string   `json:"checksumFile,omitempty"`
	JoinedFile       string   `json:"joinedFile,omitempty"`
	JoinedSHA256     string   `json:"joinedSha256,omitempty"`
	ChecksumVerified bool     `json:"checksumVerified"`
	Complete         bool     `json:"complete"`
	UpdatedAt        string   `json:"updatedAt"`
}

func transferManifestPath(outputDir string, transferID string) string {
	transferDir := transferDirectory(outputDir, transferID)
	return filepath.Join(transferDir, fmt.Sprintf("%s.meta.json", chunkFileBase(transferID)))
}


func transferDirectory(outputDir string, transferID string) string {
	return filepath.Join(outputDir, chunkFileBase(transferID))
}

func transferJoinPath(outputDir string, transferID string) string {
	transferDir := transferDirectory(outputDir, transferID)
	return filepath.Join(transferDir, fmt.Sprintf("%s.joined", chunkFileBase(transferID)))
}

func updateTransferManifest(outputDir string, chunk qrChunkUpload) (transferManifest, string, string, error) {
	existing, manifestPath, err := loadTransferManifest(outputDir, chunk.ID)
	if err != nil {
		return transferManifest{}, "", "", err
	}

	totalHint := existing.TotalParts
	if chunk.Total > totalHint {
		totalHint = chunk.Total
	}

	manifest, err := buildTransferManifest(outputDir, chunk.ID, totalHint)
	if err != nil {
		return transferManifest{}, "", "", err
	}

	joinedPath := ""
	if manifest.Complete {
		joinedPath, manifest, err = autoJoinTransfer(outputDir, manifest)
		if err != nil {
			return transferManifest{}, "", "", err
		}
	}

	if err := writeTransferManifest(manifestPath, manifest); err != nil {
		return transferManifest{}, "", "", err
	}

	return manifest, manifestPath, joinedPath, nil
}

func loadOrBuildTransferManifest(outputDir string, transferID string) (transferManifest, string, error) {
	existing, manifestPath, err := loadTransferManifest(outputDir, transferID)
	if err != nil {
		return transferManifest{}, "", err
	}

	manifest, err := buildTransferManifest(outputDir, transferID, existing.TotalParts)
	if err != nil {
		return transferManifest{}, "", err
	}

	if err := writeTransferManifest(manifestPath, manifest); err != nil {
		return transferManifest{}, "", err
	}

	return manifest, manifestPath, nil
}

func loadTransferManifest(outputDir string, transferID string) (transferManifest, string, error) {
	manifestPath := transferManifestPath(outputDir, transferID)
	content, err := os.ReadFile(manifestPath)
	if os.IsNotExist(err) {
		return transferManifest{ID: chunkFileBase(transferID)}, manifestPath, nil
	}
	if err != nil {
		return transferManifest{}, "", fmt.Errorf("reading transfer manifest: %w", err)
	}

	var manifest transferManifest
	if err := json.Unmarshal(content, &manifest); err != nil {
		return transferManifest{}, "", fmt.Errorf("parsing transfer manifest %s: %w", manifestPath, err)
	}
	if manifest.ID == "" {
		manifest.ID = chunkFileBase(transferID)
	}

	return manifest, manifestPath, nil
}

func buildTransferManifest(outputDir string, transferID string, totalHint int) (transferManifest, error) {
	base := chunkFileBase(transferID)
	transferDir := transferDirectory(outputDir, transferID)
	partFiles, maxIndex, err := scanTransferPartFiles(transferDir, base)
	if err != nil {
		return transferManifest{}, err
	}

	totalParts := max(totalHint, maxIndex)
	missingParts := missingTransferParts(totalParts, partFiles)
	checksum, checksumFile, err := readTransferChecksum(transferDir, base)
	if err != nil {
		return transferManifest{}, err
	}

	manifest := transferManifest{
		ID:            base,
		Directory:     filepath.Base(transferDir),
		TotalParts:    totalParts,
		ReceivedParts: len(partFiles),
		MissingParts:  missingParts,
		PartFiles:     orderedTransferPartFiles(partFiles),
		Checksum:      checksum,
		ChecksumFile:  checksumFile,
		Complete:      totalParts > 0 && len(missingParts) == 0,
		UpdatedAt:     time.Now().UTC().Format(time.RFC3339),
	}

	if manifest.Complete {
		joinedSHA256, err := computeJoinedPartsSHA256(transferDir, manifest.PartFiles)
		if err != nil {
			return transferManifest{}, err
		}
		manifest.JoinedSHA256 = joinedSHA256
		manifest.JoinedFile = filepath.Base(transferJoinPath(outputDir, transferID))
		manifest.ChecksumVerified = checksum != "" && strings.EqualFold(joinedSHA256, checksum)
	}

	return manifest, nil
}

func writeTransferManifest(path string, manifest transferManifest) error {
	content, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding transfer manifest: %w", err)
	}
	content = append(content, '\n')

	tempFile, err := os.CreateTemp(filepath.Dir(path), ".manifest-*")
	if err != nil {
		return fmt.Errorf("creating temporary manifest: %w", err)
	}
	tempPath := tempFile.Name()
	defer func() {
		tempFile.Close()
		os.Remove(tempPath)
	}()

	if _, err := tempFile.Write(content); err != nil {
		return fmt.Errorf("writing transfer manifest: %w", err)
	}
	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("closing transfer manifest: %w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("moving transfer manifest into place: %w", err)
	}

	return nil
}

func scanTransferPartFiles(transferDir string, base string) (map[int]string, int, error) {
	entries, err := os.ReadDir(transferDir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[int]string{}, 0, nil
		}
		return nil, 0, fmt.Errorf("reading transfer directory: %w", err)
	}

	partFiles := make(map[int]string)
	maxIndex := 0
	prefix := base + ".part"

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		suffix := strings.TrimPrefix(name, prefix)
		index, ok := alphaPartIndex(suffix)
		if !ok {
			continue
		}
		partNumber := index + 1
		partFiles[partNumber] = name
		if partNumber > maxIndex {
			maxIndex = partNumber
		}
	}

	return partFiles, maxIndex, nil
}

func orderedTransferPartFiles(partFiles map[int]string) []string {
	indexes := make([]int, 0, len(partFiles))
	for index := range partFiles {
		indexes = append(indexes, index)
	}
	sort.Ints(indexes)

	ordered := make([]string, 0, len(indexes))
	for _, index := range indexes {
		ordered = append(ordered, partFiles[index])
	}
	return ordered
}

func missingTransferParts(totalParts int, partFiles map[int]string) []int {
	if totalParts <= 0 {
		return nil
	}

	missing := make([]int, 0)
	for index := 1; index <= totalParts; index++ {
		if _, ok := partFiles[index]; !ok {
			missing = append(missing, index)
		}
	}
	return missing
}


func autoJoinTransfer(outputDir string, manifest transferManifest) (string, transferManifest, error) {
	joinedPath := transferJoinPath(outputDir, manifest.ID)
	transferDir := transferDirectory(outputDir, manifest.ID)
	if err := ensureJoinOutputPath(joinedPath, transferDir, manifest.PartFiles, true); err != nil {
		return "", transferManifest{}, err
	}

	joinedHash, err := joinTransferFiles(transferDir, manifest, joinedPath)
	if err != nil {
		return "", transferManifest{}, err
	}

	manifest.JoinedFile = filepath.Base(joinedPath)
	manifest.JoinedSHA256 = joinedHash
	manifest.ChecksumVerified = manifest.Checksum != "" && strings.EqualFold(joinedHash, manifest.Checksum)

	return joinedPath, manifest, nil
}

func readTransferChecksum(transferDir string, base string) (string, string, error) {
	checksumFile := fmt.Sprintf("%s.sha256", base)
	checksumPath := filepath.Join(transferDir, checksumFile)
	content, err := os.ReadFile(checksumPath)
	if os.IsNotExist(err) {
		return "", "", nil
	}
	if err != nil {
		return "", "", fmt.Errorf("reading checksum file: %w", err)
	}

	fields := strings.Fields(string(content))
	if len(fields) == 0 {
		return "", checksumFile, nil
	}

	return fields[0], checksumFile, nil
}

func computeJoinedPartsSHA256(transferDir string, orderedPartFiles []string) (string, error) {
	hasher := sha256.New()
	for _, partFile := range orderedPartFiles {
		partPath := filepath.Join(transferDir, partFile)
		content, err := os.ReadFile(partPath)
		if err != nil {
			return "", fmt.Errorf("reading %s for checksum verification: %w", partPath, err)
		}
		if _, err := hasher.Write(content); err != nil {
			return "", fmt.Errorf("hashing %s: %w", partPath, err)
		}
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func alphaPartIndex(suffix string) (int, bool) {
	if len(suffix) < 2 {
		return 0, false
	}

	value := 0
	for _, r := range suffix {
		if r < 'a' || r > 'z' {
			return 0, false
		}
		value = value*26 + int(r-'a')
	}

	return value, true
}
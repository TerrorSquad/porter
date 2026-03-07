package main

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"math"
)

const chunkIDAlphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

type ChunkOptions struct {
	Buffer       int
	UseBase64    bool
	AddHeader    bool
	ECCLevel     string
	CurrentPart  *int // nil = not part of multi-part
	TotalParts   *int
	AddChecksum  bool
}

type Chunker struct {
	Chunks    []string
	Version   int
	ChunkSize int
	ChunkID   string
	Checksum  string
	content   []byte
}

func NewChunker(content []byte) *Chunker {
	hash := sha256.Sum256(content)
	checksum := fmt.Sprintf("%x", hash)
	chunkID := makeChunkID(hash[0], hash[1])

	return &Chunker{
		Chunks:   []string{},
		Version:  1,
		ChunkID:  chunkID,
		content:  content,
		Checksum: checksum,
	}
}

func makeChunkID(high byte, low byte) string {
	value := int(high)<<8 | int(low)
	return string([]byte{
		chunkIDAlphabet[(value>>6)&0x3f],
		chunkIDAlphabet[value&0x3f],
	})
}

var capacityTable = map[string]map[int]int{
	"L": {1: 41, 2: 77, 3: 127, 4: 187, 5: 255, 6: 322, 7: 370, 8: 461, 9: 525, 10: 581,
		11: 655, 12: 733, 13: 815, 14: 901, 15: 991, 16: 1085, 17: 1156, 18: 1258, 19: 1364, 20: 1474,
		21: 1588, 22: 1706, 23: 1828, 24: 1954, 25: 2048, 26: 2188, 27: 2332, 28: 2492, 29: 2665, 30: 2844,
		31: 3033, 32: 3057, 33: 3283, 34: 3517, 35: 3557, 36: 3807, 37: 4096, 38: 4452, 39: 4632, 40: 4836},
	"M": {1: 34, 2: 60, 3: 95, 4: 142, 5: 195, 6: 224, 7: 271, 8: 335, 9: 395, 10: 468,
		11: 535, 12: 619, 13: 667, 14: 758, 15: 854, 16: 938, 17: 1046, 18: 1159, 19: 1224, 20: 1358,
		21: 1468, 22: 1588, 23: 1704, 24: 1853, 25: 1990, 26: 2132, 27: 2223, 28: 2369, 29: 2520, 30: 2677,
		31: 2840, 32: 3009, 33: 3183, 34: 3351, 35: 3537, 36: 3729, 37: 3927, 38: 4087, 39: 4296, 40: 4544},
	"Q": {1: 27, 2: 45, 3: 77, 4: 111, 5: 154, 6: 195, 7: 224, 8: 279, 9: 335, 10: 405,
		11: 468, 12: 541, 13: 579, 14: 656, 15: 734, 16: 816, 17: 909, 18: 970, 19: 1035, 20: 1144,
		21: 1222, 22: 1276, 23: 1395, 24: 1518, 25: 1663, 26: 1663, 27: 1859, 28: 1950, 29: 2071, 30: 2191,
		31: 2306, 32: 2434, 33: 2566, 34: 2702, 35: 2812, 36: 2956, 37: 3108, 38: 3246, 39: 3391, 40: 3563},
	"H": {1: 17, 2: 34, 3: 58, 4: 82, 5: 106, 6: 139, 7: 154, 8: 202, 9: 235, 10: 288,
		11: 331, 12: 374, 13: 395, 14: 446, 15: 510, 16: 560, 17: 615, 18: 666, 19: 722, 20: 824,
		21: 868, 22: 969, 23: 1056, 24: 1108, 25: 1228, 26: 1286, 27: 1368, 28: 1531, 29: 1675, 30: 1810,
		31: 1952, 32: 2068, 33: 2188, 34: 2369, 35: 2506, 36: 2632, 37: 2780, 38: 2894, 39: 3054, 40: 3220},
}

func getMaxCapacity(version int, eccLevel string) int {
	if cap, ok := capacityTable[eccLevel][version]; ok {
		return cap
	}
	return 100 // fallback
}

func (c *Chunker) CalculateLayout(rows int, options ChunkOptions) {
	availableRows := rows - options.Buffer
	// QR version N produces (4*N + 17) modules.
	// The qrterminal library renders 1 module per terminal row (full block chars).
	// Plus ~4 rows quiet zone. So total QR height = 4*N + 21
	// We need QR height <= availableRows, so: N <= (availableRows - 21) / 4
	// Cap at version 15 max for practical terminal sizes
	maxVer := int(math.Max(1, math.Min(15, float64((availableRows-21)/4))))
	c.Version = maxVer

	ecc := options.ECCLevel
	if ecc == "" {
		ecc = "L"
	}

	charCapacity := getMaxCapacity(c.Version, ecc)

	headerSize := 0
	if options.AddHeader {
		headerSize = 16
	}

	workingCapacity := charCapacity - headerSize
	c.ChunkSize = workingCapacity

	if options.UseBase64 {
		c.ChunkSize = int(float64(workingCapacity) * 0.75)
	}

	if c.ChunkSize <= 0 {
		c.ChunkSize = 50
	}

	c.Chunks = []string{}

	totalLength := len(c.content)
	tempChunksCount := (totalLength + c.ChunkSize - 1) / c.ChunkSize

	for i := 0; i < totalLength; i += c.ChunkSize {
		end := i + c.ChunkSize
		if end > totalLength {
			end = totalLength
		}

		chunk := c.content[i:end]
		var payload string

		if options.UseBase64 {
			payload = base64.StdEncoding.EncodeToString(chunk)
		} else {
			payload = string(chunk)
		}

		if options.AddHeader {
			currentChunkIndex := i/c.ChunkSize + 1
			modeChar := "T"
			if options.UseBase64 {
				modeChar = "B"
			}

			payload = fmt.Sprintf("%d|%d|%s|%s|%s",
				currentChunkIndex, tempChunksCount,
				modeChar, c.ChunkID, payload)
		}

		c.Chunks = append(c.Chunks, payload)
	}

	if options.AddChecksum {
		checksumChunk := fmt.Sprintf("CHECKSUM|T|%s|%s",
			c.ChunkID, c.Checksum)
		c.Chunks = append(c.Chunks, checksumChunk)
	}
}

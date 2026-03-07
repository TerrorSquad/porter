
import crypto from 'crypto';
import { getMaxCapacity } from './constants';

export interface ChunkOptions {
  buffer: number;
  useBase64: boolean;
  addHeader?: boolean;
  eccLevel?: 'L' | 'M' | 'Q' | 'H';
  currentPart?: number;      // Which part file (1-indexed)
  totalParts?: number;       // Total number of part files
  addChecksum?: boolean;     // Add SHA256 as final chunk
}

export class Chunker {
  public chunks: string[] = [];
  public version: number = 1;
  public chunkSize: number = 500;
  public checksum: string = ''; // SHA256 of content

  private content: Buffer;

  constructor(content: Buffer) {
    this.content = content;
    this.checksum = crypto.createHash('sha256').update(content).digest('hex');
  }

  public getSha256(): string {
    return this.checksum;
  }

  public getMd5(): string {
    return crypto.createHash('md5').update(this.content).digest('hex');
  }

  public calculateLayout(rows: number, options: ChunkOptions) {
    const availableRows = rows - options.buffer;
    // Heuristic for QR version capacity based on terminal height:
    // QR Size (modules) = 17 + 4 * version
    // Using half-blocks, we need `modules / 2` rows.
    // So: rows * 2 >= 17 + 4 * version
    // 4 * version <= 2 * rows - 17
    // version <= (2 * rows - 17) / 4

    // We add margin (-4) to be safe
    const maxVer = Math.floor(((availableRows * 2) - 17 - 4) / 4);
    this.version = Math.max(1, Math.min(40, maxVer));

    // Get exact capacity from table based on version and ECC
    const ecc = options.eccLevel || 'L';
    const charCapacity = getMaxCapacity(this.version, ecc);

    // Reserve space for header "NNN|NNN|" -> approx 12 chars
    const headerSize = options.addHeader ? 12 : 0;
    const workingCapacity = charCapacity - headerSize;

    // If using Base64, source chunk size is smaller due to ~33% overhead
    // base64 size = ceil(n / 3) * 4. So n approx 0.75 * size
    this.chunkSize = options.useBase64
      ? Math.floor(workingCapacity * 0.75)
      : workingCapacity;

    if (this.chunkSize <= 0) this.chunkSize = 50; // Safety floor

    this.chunks = [];

    const totalLength = this.content.length;

    // First pass to determine total chunks
    const tempChunksCount = Math.ceil(totalLength / this.chunkSize);

    for (let i = 0; i < totalLength; i += this.chunkSize) {
      const chunkBuffer = this.content.subarray(i, i + this.chunkSize);
      let payload = options.useBase64
        ? chunkBuffer.toString('base64')
        : chunkBuffer.toString('utf8');

      if (options.addHeader) {
        // We use 1-based index for display/header
        const currentChunkIndex = Math.floor(i / this.chunkSize) + 1;
        let modeChar = options.useBase64 ? 'B' : 'T';

        // Format: chunkIdx|chunkTotal|partNum|partTotal|mode|payload
        // If no parts specified, use 1|1 for single-file mode
        const partNum = options.currentPart || 1;
        const partTotal = options.totalParts || 1;

        payload = `${currentChunkIndex}|${tempChunksCount}|${partNum}|${partTotal}|${modeChar}|${payload}`;
      }

      this.chunks.push(payload);
    }

    // Add checksum as final chunk if requested
    if (options.addChecksum) {
      // Format: CHECKSUM|partNum|partTotal|mode|sha256hash
      const partNum = options.currentPart || 1;
      const partTotal = options.totalParts || 1;
      const checksumChunk = `CHECKSUM|${partNum}|${partTotal}|T|${this.checksum}`;
      this.chunks.push(checksumChunk);
    }
  }
}

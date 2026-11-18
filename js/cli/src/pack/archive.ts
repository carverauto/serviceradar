// Deterministic `.srpack` (`tar.zst`) archive reader and writer using purely
// Node built-in modules (`node:fs`, `node:path`, `node:zlib`).
//
// Wire contract (shared with `ServiceRadar.Catalog.PackArchive`):
//   - Primary compression: zstd level 3 (`zlib.zstdCompressSync`, magic
//     `0x28 0xB5 0x2F 0xFD`), with deterministic gzip fallback if an older
//     Node 20 runtime lacks `zstdCompressSync`.
//   - Tar framing: POSIX.1-1988 USTAR (`"ustar\0"` + `"00"`), regular files
//     only (`typeflag = '0'`), entries sorted in UTF-8 byte order by path,
//     `mode = 0644`, `uid = 0`, `gid = 0`, `mtime = 0`, `uname = ""`,
//     `gname = ""`, `devmajor = 0`, `devminor = 0`, two trailing 512-byte
//     zero EOF blocks.
//   - Extraction caps: 25 MB compressed, 64 MB uncompressed, max 256 entries,
//     strict rejection of `..`, leading `/`, `\`, NUL bytes, symlinks,
//     hardlinks, and device nodes.

import {lstatSync, readdirSync, readFileSync} from "node:fs"
import {join} from "node:path"
import * as zlib from "node:zlib"
import {compareUtf8Keys} from "./canonical.js"

export const MAX_COMPRESSED_ARCHIVE_BYTES = 25 * 1024 * 1024
export const MAX_UNCOMPRESSED_ARCHIVE_BYTES = 64 * 1024 * 1024
export const MAX_ARCHIVE_ENTRIES = 256
const TAR_BLOCK_SIZE = 512

interface ZlibWithZstd {
  constants?: Record<string, number>
  zstdCompressSync?: (buffer: Buffer, options?: Record<string, unknown>) => Buffer
  zstdDecompressSync?: (buffer: Buffer, options?: Record<string, unknown>) => Buffer
}

export interface ArchiveEntry {
  path: string
  data: Buffer
  mode?: number
}

export function normalizeArchivePath(rawPath: string): string {
  if (typeof rawPath !== "string" || rawPath.length === 0) {
    throw new Error("invalid archive entry path: path is empty")
  }
  if (rawPath.includes("\0") || rawPath.includes("\\")) {
    throw new Error(`unsafe archive entry path "${rawPath}": contains forbidden characters`)
  }
  if (rawPath.startsWith("/")) {
    throw new Error(`unsafe archive entry path "${rawPath}": absolute paths are forbidden`)
  }
  const segments = rawPath.split("/")
  if (segments.some((seg) => seg === "" || seg === "." || seg === "..")) {
    throw new Error(`unsafe archive entry path "${rawPath}": path traversal segments are forbidden`)
  }
  const normalized = segments.join("/")
  if (Buffer.byteLength(normalized, "utf8") > 255) {
    throw new Error(`archive entry path exceeds 255 bytes: "${normalized}"`)
  }
  return normalized
}

export function collectPackDirectoryFiles(rootDir: string): Map<string, Buffer> {
  const rootStat = lstatSync(rootDir)
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
    throw new Error(`pack path "${rootDir}" must be a real directory (not a symlink)`)
  }

  const collected: ArchiveEntry[] = []
  let totalBytes = 0

  function walk(currentAbs: string, relPrefix: string): void {
    const entries = readdirSync(currentAbs).sort(compareUtf8Keys)
    for (const name of entries) {
      if (name === ".DS_Store") {
        continue
      }
      const relPath = relPrefix ? `${relPrefix}/${name}` : name
      const normalized = normalizeArchivePath(relPath)
      const fullPath = join(currentAbs, name)
      const st = lstatSync(fullPath)

      if (st.isSymbolicLink()) {
        throw new Error(`unsafe symlink in pack directory: "${normalized}"`)
      }
      if (st.isDirectory()) {
        walk(fullPath, normalized)
        continue
      }
      if (!st.isFile()) {
        throw new Error(`unsupported special file in pack directory: "${normalized}"`)
      }
      if (collected.length >= MAX_ARCHIVE_ENTRIES) {
        throw new Error(`pack exceeds maximum entry count of ${MAX_ARCHIVE_ENTRIES}`)
      }
      const data = readFileSync(fullPath)
      totalBytes += data.length
      if (totalBytes > MAX_UNCOMPRESSED_ARCHIVE_BYTES) {
        throw new Error(`pack exceeds maximum uncompressed size of ${MAX_UNCOMPRESSED_ARCHIVE_BYTES} bytes`)
      }
      collected.push({path: normalized, data})
    }
  }

  walk(rootDir, "")
  collected.sort((a, b) => compareUtf8Keys(a.path, b.path))

  const files = new Map<string, Buffer>()
  for (const entry of collected) {
    files.set(entry.path, entry.data)
  }
  return files
}

export function buildDeterministicTar(entries: ArchiveEntry[]): Buffer {
  if (entries.length > MAX_ARCHIVE_ENTRIES) {
    throw new Error(`pack exceeds maximum entry count of ${MAX_ARCHIVE_ENTRIES}`)
  }

  const seen = new Set<string>()
  const normalizedEntries = entries.map((entry) => {
    const normalizedPath = normalizeArchivePath(entry.path)
    if (seen.has(normalizedPath)) {
      throw new Error(`duplicate archive entry path: "${normalizedPath}"`)
    }
    seen.add(normalizedPath)
    return {
      path: normalizedPath,
      data: entry.data,
      mode: entry.mode === 0o755 ? 0o755 : 0o644,
    }
  })

  normalizedEntries.sort((a, b) => compareUtf8Keys(a.path, b.path))

  const chunks: Buffer[] = []
  let totalUncompressed = 0

  for (const entry of normalizedEntries) {
    totalUncompressed += entry.data.length
    if (totalUncompressed > MAX_UNCOMPRESSED_ARCHIVE_BYTES) {
      throw new Error(`pack exceeds maximum uncompressed size of ${MAX_UNCOMPRESSED_ARCHIVE_BYTES} bytes`)
    }

    chunks.push(encodeUstarHeader(entry.path, entry.data.length, entry.mode))
    if (entry.data.length > 0) {
      chunks.push(entry.data)
      const remainder = entry.data.length % TAR_BLOCK_SIZE
      if (remainder !== 0) {
        chunks.push(Buffer.alloc(TAR_BLOCK_SIZE - remainder, 0))
      }
    }
  }

  // Standard POSIX tar EOF marker: two 512-byte zero blocks.
  chunks.push(Buffer.alloc(TAR_BLOCK_SIZE * 2, 0))
  return Buffer.concat(chunks)
}

export function compressSrpackTar(tarBuffer: Buffer): Buffer {
  const z = zlib as unknown as ZlibWithZstd
  if (typeof z.zstdCompressSync === "function") {
    const levelKey = z.constants?.ZSTD_c_compressionLevel ?? 100
    const compressed = z.zstdCompressSync(tarBuffer, {
      params: {
        [levelKey]: 3,
      },
    })
    if (compressed.length > MAX_COMPRESSED_ARCHIVE_BYTES) {
      throw new Error(`compressed .srpack exceeds ${MAX_COMPRESSED_ARCHIVE_BYTES} bytes`)
    }
    return compressed
  }

  // Deterministic RFC 1952 gzip fallback for older Node 20 runtimes without zstd.
  const gz = Buffer.from(zlib.gzipSync(tarBuffer, {level: 9}))
  if (gz.length >= 10) {
    gz.writeUInt32LE(0, 4) // mtime = 0
    gz[9] = 0xff // OS = unknown (255) for cross-platform byte determinism
  }
  if (gz.length > MAX_COMPRESSED_ARCHIVE_BYTES) {
    throw new Error(`compressed .srpack exceeds ${MAX_COMPRESSED_ARCHIVE_BYTES} bytes`)
  }
  return gz
}

export function buildSrpackArchive(entries: ArchiveEntry[]): Buffer {
  const tar = buildDeterministicTar(entries)
  return compressSrpackTar(tar)
}

export function readSrpackArchive(archiveBytes: Buffer): Map<string, Buffer> {
  if (archiveBytes.length === 0) {
    throw new Error("invalid .srpack archive: file is empty")
  }
  if (archiveBytes.length > MAX_COMPRESSED_ARCHIVE_BYTES) {
    throw new Error(
      `invalid .srpack archive: compressed size ${archiveBytes.length} exceeds ${MAX_COMPRESSED_ARCHIVE_BYTES} bytes`,
    )
  }

  const tarBytes = decompressToTar(archiveBytes)
  return parseUstarArchive(tarBytes)
}

function decompressToTar(archiveBytes: Buffer): Buffer {
  // Zstandard magic: 0x28 0xB5 0x2F 0xFD
  if (
    archiveBytes.length >= 4 &&
    archiveBytes[0] === 0x28 &&
    archiveBytes[1] === 0xb5 &&
    archiveBytes[2] === 0x2f &&
    archiveBytes[3] === 0xfd
  ) {
    const z = zlib as unknown as ZlibWithZstd
    if (typeof z.zstdDecompressSync !== "function") {
      throw new Error("this Node.js runtime does not provide zlib.zstdDecompressSync for zstd .srpack archives")
    }
    return z.zstdDecompressSync(archiveBytes, {
      maxOutputLength: MAX_UNCOMPRESSED_ARCHIVE_BYTES,
    })
  }

  // Gzip magic: 0x1F 0x8B
  if (archiveBytes.length >= 2 && archiveBytes[0] === 0x1f && archiveBytes[1] === 0x8b) {
    return zlib.gunzipSync(archiveBytes, {
      maxOutputLength: MAX_UNCOMPRESSED_ARCHIVE_BYTES,
    })
  }

  // Raw USTAR tar stream (`"ustar"` at offset 257).
  if (
    archiveBytes.length >= TAR_BLOCK_SIZE &&
    archiveBytes.subarray(257, 262).toString("ascii") === "ustar"
  ) {
    if (archiveBytes.length > MAX_UNCOMPRESSED_ARCHIVE_BYTES) {
      throw new Error(`tar archive exceeds ${MAX_UNCOMPRESSED_ARCHIVE_BYTES} bytes`)
    }
    return archiveBytes
  }

  throw new Error("unrecognized .srpack archive format (expected tar.zst, tar.gz, or POSIX ustar)")
}

function encodeUstarHeader(path: string, size: number, mode: number): Buffer {
  if (size < 0 || size > MAX_UNCOMPRESSED_ARCHIVE_BYTES) {
    throw new Error(`archive entry "${path}" size ${size} is out of bounds`)
  }

  const header = Buffer.alloc(TAR_BLOCK_SIZE, 0)
  const {name, prefix} = splitUstarPath(path)

  header.write(name, 0, Math.min(Buffer.byteLength(name, "utf8"), 100), "utf8")
  writeOctalField(header, 100, 8, mode) // mode: "0000644\0"
  writeOctalField(header, 108, 8, 0) // uid: "0000000\0"
  writeOctalField(header, 116, 8, 0) // gid: "0000000\0"
  writeOctalField(header, 124, 12, size) // size: 11 octal digits + "\0"
  writeOctalField(header, 136, 12, 0) // mtime: "00000000000\0"

  // Fill checksum field [148..155] with ASCII spaces during calculation.
  header.fill(0x20, 148, 156)
  header[156] = 0x30 // typeflag '0' (regular file)
  header.write("ustar\0", 257, 6, "ascii")
  header.write("00", 263, 2, "ascii")
  // uname [265..296] and gname [297..328] stay zeroed ("")
  writeOctalField(header, 329, 8, 0) // devmajor
  writeOctalField(header, 337, 8, 0) // devminor

  if (prefix) {
    header.write(prefix, 345, Math.min(Buffer.byteLength(prefix, "utf8"), 155), "utf8")
  }

  let checksum = 0
  for (let i = 0; i < TAR_BLOCK_SIZE; i += 1) {
    checksum += header[i]
  }
  const chksumStr = checksum.toString(8).padStart(6, "0") + "\0 "
  header.write(chksumStr, 148, 8, "ascii")

  return header
}

function writeOctalField(buf: Buffer, offset: number, length: number, value: number): void {
  const digits = length - 1
  const encoded = value.toString(8).padStart(digits, "0")
  if (encoded.length > digits) {
    throw new Error(`octal header field overflow for value ${value}`)
  }
  buf.write(encoded + "\0", offset, length, "ascii")
}

function splitUstarPath(normalizedPath: string): {name: string; prefix: string} {
  if (Buffer.byteLength(normalizedPath, "utf8") <= 100) {
    return {name: normalizedPath, prefix: ""}
  }

  const parts = normalizedPath.split("/")
  for (let i = parts.length - 1; i >= 1; i -= 1) {
    const prefix = parts.slice(0, i).join("/")
    const name = parts.slice(i).join("/")
    if (Buffer.byteLength(prefix, "utf8") <= 155 && Buffer.byteLength(name, "utf8") <= 100) {
      return {name, prefix}
    }
  }

  throw new Error(`archive path "${normalizedPath}" cannot be encoded in POSIX ustar name+prefix`)
}

function parseUstarArchive(tarBytes: Buffer): Map<string, Buffer> {
  if (tarBytes.length % TAR_BLOCK_SIZE !== 0) {
    throw new Error("corrupt tar stream inside .srpack: length is not a multiple of 512 bytes")
  }

  const files = new Map<string, Buffer>()
  let offset = 0
  let totalBytes = 0

  while (offset + TAR_BLOCK_SIZE <= tarBytes.length) {
    const header = tarBytes.subarray(offset, offset + TAR_BLOCK_SIZE)
    offset += TAR_BLOCK_SIZE

    if (isZeroBlock(header)) {
      break
    }

    verifyHeaderChecksum(header)

    const typeFlag = header[156]
    const namePart = readNullTerminatedUtf8(header.subarray(0, 100))
    const prefixPart = readNullTerminatedUtf8(header.subarray(345, 500))
    const rawPath = prefixPart ? `${prefixPart}/${namePart}` : namePart

    // Reject symlinks ('2'), hardlinks ('1'), char/block devices ('3', '4'), FIFOs ('6'), etc.
    if (typeFlag === 0x35 /* '5' directory */) {
      const cleanDir = rawPath.replace(/\/+$/, "")
      if (cleanDir) {
        normalizeArchivePath(cleanDir)
      }
      continue
    }

    if (typeFlag !== 0x30 /* '0' */ && typeFlag !== 0x00) {
      throw new Error(
        `unsupported or unsafe tar entry type "${String.fromCharCode(typeFlag)}" for "${rawPath}"`,
      )
    }

    const normalizedPath = normalizeArchivePath(rawPath)
    if (files.has(normalizedPath)) {
      throw new Error(`duplicate entry in .srpack archive: "${normalizedPath}"`)
    }
    if (files.size >= MAX_ARCHIVE_ENTRIES) {
      throw new Error(`.srpack archive exceeds maximum of ${MAX_ARCHIVE_ENTRIES} entries`)
    }

    const size = parseOctalField(header.subarray(124, 136), "size")
    totalBytes += size
    if (totalBytes > MAX_UNCOMPRESSED_ARCHIVE_BYTES) {
      throw new Error(`.srpack archive exceeds maximum uncompressed size of ${MAX_UNCOMPRESSED_ARCHIVE_BYTES} bytes`)
    }

    const paddedSize = Math.ceil(size / TAR_BLOCK_SIZE) * TAR_BLOCK_SIZE
    if (offset + paddedSize > tarBytes.length) {
      throw new Error(`truncated tar entry "${normalizedPath}" in .srpack archive`)
    }

    const content = Buffer.from(tarBytes.subarray(offset, offset + size))
    offset += paddedSize
    files.set(normalizedPath, content)
  }

  return files
}

function isZeroBlock(block: Buffer): boolean {
  for (let i = 0; i < block.length; i += 1) {
    if (block[i] !== 0) return false
  }
  return true
}

function readNullTerminatedUtf8(slice: Buffer): string {
  const zeroIdx = slice.indexOf(0)
  const end = zeroIdx === -1 ? slice.length : zeroIdx
  return slice.subarray(0, end).toString("utf8")
}

function parseOctalField(slice: Buffer, fieldName: string): number {
  const raw = readNullTerminatedUtf8(slice).trim()
  if (raw === "") return 0
  if (!/^[0-7]+$/.test(raw)) {
    throw new Error(`invalid octal ${fieldName} field "${raw}" in tar header`)
  }
  return parseInt(raw, 8)
}

function verifyHeaderChecksum(header: Buffer): void {
  const expected = parseOctalField(header.subarray(148, 156), "chksum")
  let unsignedSum = 0
  for (let i = 0; i < TAR_BLOCK_SIZE; i += 1) {
    unsignedSum += i >= 148 && i < 156 ? 0x20 : header[i]
  }
  if (unsignedSum !== expected) {
    throw new Error(`corrupt tar header checksum: expected ${expected}, got ${unsignedSum}`)
  }
}

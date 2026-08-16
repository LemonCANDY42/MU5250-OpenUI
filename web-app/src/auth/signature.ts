export function normalizeP256Signature(signature: ArrayBuffer | Uint8Array): Uint8Array {
  const bytes = signature instanceof Uint8Array ? signature : new Uint8Array(signature)
  if (bytes.length === 64) {
    // Exactly 64 bytes can be either IEEE P1363 raw or a short canonical DER
    // sequence. Preserve the bytes so the server can try both interpretations
    // and accept only the one that actually verifies.
    return bytes.slice()
  }
  if (bytes.length < 8 || bytes[0] !== 0x30 || bytes[1] !== bytes.length - 2) {
    throw new Error('invalid P-256 signature encoding')
  }

  let offset = 2
  const r = readInteger(bytes, offset)
  offset = r.next
  const s = readInteger(bytes, offset)
  if (s.next !== bytes.length) {
    throw new Error('invalid P-256 signature encoding')
  }

  const raw = new Uint8Array(64)
  raw.set(r.value, 32 - r.value.length)
  raw.set(s.value, 64 - s.value.length)
  return raw
}

function readInteger(bytes: Uint8Array, offset: number): { value: Uint8Array; next: number } {
  if (bytes[offset] !== 0x02) {
    throw new Error('invalid P-256 signature integer')
  }
  const length = bytes[offset + 1]
  const start = offset + 2
  const end = start + length
  if (length < 1 || length > 33 || end > bytes.length) {
    throw new Error('invalid P-256 signature integer')
  }
  const encoded = bytes.subarray(start, end)
  if ((encoded[0] & 0x80) !== 0) {
    throw new Error('negative P-256 signature integer')
  }
  if (encoded.length > 1 && encoded[0] === 0 && (encoded[1] & 0x80) === 0) {
    throw new Error('non-canonical P-256 signature integer')
  }
  const value = encoded[0] === 0 ? encoded.subarray(1) : encoded
  if (value.length > 32) {
    throw new Error('oversized P-256 signature integer')
  }
  return { value, next: end }
}

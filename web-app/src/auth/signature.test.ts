import { describe, expect, it } from 'vitest'

import { normalizeP256Signature } from './signature'

describe('P-256 signature normalization', () => {
  it('preserves WebCrypto raw signatures', () => {
    const raw = Uint8Array.from({ length: 64 }, (_, index) => index)
    expect(normalizeP256Signature(raw)).toEqual(raw)
  })

  it('converts canonical DER signatures into fixed-width raw signatures', () => {
    const r = Uint8Array.from([0x80, 0x01])
    const s = Uint8Array.from([0x01, 0x02, 0x03])
    const der = derSignature(r, s)
    const raw = normalizeP256Signature(der)
    expect(raw).toHaveLength(64)
    expect(raw.slice(30, 32)).toEqual(r)
    expect(raw.slice(61)).toEqual(s)
  })

  it('preserves an exact 64-byte DER sequence for server-side disambiguation', () => {
    const der = Uint8Array.from([
      0x30,
      62,
      0x02,
      29,
      ...Array<number>(29).fill(1),
      0x02,
      29,
      ...Array<number>(29).fill(2),
    ])
    expect(der).toHaveLength(64)
    expect(normalizeP256Signature(der)).toEqual(der)
  })

  it('rejects malformed, negative, and non-canonical DER', () => {
    const malformed = [
      Uint8Array.from([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01]),
      Uint8Array.from([0x30, 0x06, 0x02, 0x01, 0x80, 0x02, 0x01, 0x01]),
      Uint8Array.from([0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01]),
    ]
    for (const value of malformed) {
      expect(() => normalizeP256Signature(value)).toThrow()
    }
  })
})

function derSignature(r: Uint8Array, s: Uint8Array): Uint8Array {
  const rEncoded = (r[0] & 0x80) === 0 ? r : Uint8Array.from([0, ...r])
  const sEncoded = (s[0] & 0x80) === 0 ? s : Uint8Array.from([0, ...s])
  return Uint8Array.from([
    0x30,
    rEncoded.length + sEncoded.length + 4,
    0x02,
    rEncoded.length,
    ...rEncoded,
    0x02,
    sEncoded.length,
    ...sEncoded,
  ])
}

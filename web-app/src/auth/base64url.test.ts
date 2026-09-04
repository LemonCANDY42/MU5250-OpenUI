import { describe, expect, it } from 'vitest'

import { decodeBase64Url, encodeBase64Url } from './base64url'

describe('base64url', () => {
  it('round-trips binary data without padding', () => {
    const bytes = Uint8Array.from([0, 1, 2, 127, 128, 254, 255])
    const encoded = encodeBase64Url(bytes)
    expect(encoded).toBe('AAECf4D-_w')
    expect(encoded).not.toContain('=')
    expect(decodeBase64Url(encoded)).toEqual(bytes)
  })

  it('fails closed for padding, alphabet, and impossible lengths', () => {
    for (const value of ['AA==', 'AA+_', 'A', 'not a value']) {
      expect(() => decodeBase64Url(value)).toThrow('invalid base64url value')
    }
  })
})

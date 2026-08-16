const BASE64URL = /^[A-Za-z0-9_-]*$/

export function encodeBase64Url(bytes: ArrayBuffer | Uint8Array): string {
  const input = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let binary = ''
  for (let offset = 0; offset < input.length; offset += 0x8000) {
    binary += String.fromCharCode(...input.subarray(offset, offset + 0x8000))
  }
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '')
}

export function decodeBase64Url(value: string): Uint8Array {
  if (!BASE64URL.test(value) || value.length % 4 === 1) {
    throw new Error('invalid base64url value')
  }
  const padding = '='.repeat((4 - (value.length % 4)) % 4)
  let binary: string
  try {
    binary = atob(value.replaceAll('-', '+').replaceAll('_', '/') + padding)
  } catch {
    throw new Error('invalid base64url value')
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0))
}

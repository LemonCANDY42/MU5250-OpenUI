import { indexedDB as fakeIndexedDB } from 'fake-indexeddb'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { decodeBase64Url, encodeBase64Url } from './base64url'
import {
  pairBrowserCredential,
  signInWithCredential,
  signInWithPassword,
} from './auth-service'
import { CREDENTIAL_DB_NAME } from './credential-store'
import { clearSessionToken, getJson, hasSessionToken, setSessionToken } from '../data/client'

const TOKEN = 'T'.repeat(43)
const NONCE = 'N'.repeat(43)

describe('browser pairing and authentication', () => {
  beforeEach(async () => {
    clearSessionToken()
    Object.defineProperty(globalThis, 'indexedDB', {
      configurable: true,
      value: fakeIndexedDB,
    })
    await deleteDatabase()
  })

  it('pairs, signs the exact challenge, and creates an in-memory session', async () => {
    const message = Uint8Array.from({ length: 32 }, (_, index) => 255 - index)
    let publicKey: CryptoKey | undefined
    const paths: string[] = []
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
        const path = String(input)
        paths.push(path)
        const body = init?.body === undefined ? {} : JSON.parse(String(init.body))
        if (path === '/v1/auth/pair') {
          expect(body.pairing_nonce).toBe(NONCE)
          publicKey = await crypto.subtle.importKey(
            'spki',
            arrayBuffer(decodeBase64Url(body.public_key_spki)),
            { name: 'ECDSA', namedCurve: 'P-256' },
            true,
            ['verify'],
          )
          return json({ id: 'credential-1', label: 'Test browser' })
        }
        if (path === '/v1/auth/challenge') {
          expect(body).toEqual({ credential_id: 'credential-1' })
          return json({
            challenge_id: 'challenge-1',
            message: encodeBase64Url(message),
            expires_in_seconds: 120,
          })
        }
        if (path === '/v1/auth/challenge/verify') {
          expect(publicKey).toBeDefined()
          const valid = await crypto.subtle.verify(
            { name: 'ECDSA', hash: 'SHA-256' },
            publicKey as CryptoKey,
            arrayBuffer(decodeBase64Url(body.signature)),
            arrayBuffer(message),
          )
          expect(valid).toBe(true)
          return json(session())
        }
        throw new Error(`unexpected path: ${path}`)
      }),
    )

    const credential = await pairBrowserCredential(NONCE, ' Test browser ')
    expect(credential.privateKey.extractable).toBe(false)
    await signInWithCredential(credential)

    expect(paths).toEqual([
      '/v1/auth/pair',
      '/v1/auth/challenge',
      '/v1/auth/challenge/verify',
    ])
    expect(hasSessionToken()).toBe(true)
  })

  it('uses password fallback without touching browser persistence APIs', async () => {
    vi.stubGlobal('localStorage', forbiddenStorage())
    vi.stubGlobal('sessionStorage', forbiddenStorage())
    vi.stubGlobal('indexedDB', forbiddenIndexedDb())
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      if (String(input) === '/v1/auth/password/session') {
        expect(JSON.parse(String(init?.body))).toEqual({ password: 'not saved' })
        return json(session())
      }
      if (String(input) === '/v1/device') {
        expect(new Headers(init?.headers).get('Authorization')).toBe(`Bearer ${TOKEN}`)
        return json({ marker: true })
      }
      throw new Error('unexpected request')
    })
    vi.stubGlobal('fetch', fetchMock)

    await signInWithPassword('not saved')
    expect(hasSessionToken()).toBe(true)
    await expect(getJson('/v1/device')).resolves.toEqual({ marker: true })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('rejects invalid session tokens before retaining them', () => {
    expect(() => setSessionToken('short')).toThrow('invalid session token')
    expect(hasSessionToken()).toBe(false)
  })
})

function session() {
  return {
    token: TOKEN,
    token_type: 'Bearer',
    scopes: ['read', 'daily'],
    idle_expires_in_seconds: 3600,
    absolute_expires_in_seconds: 43200,
  }
}

function json(data: unknown): Response {
  return new Response(JSON.stringify({ ok: true, data }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  })
}

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return Uint8Array.from(bytes).buffer
}

function forbiddenStorage(): Storage {
  return new Proxy({} as Storage, {
    get: () => {
      throw new Error('persistent storage must not be read')
    },
  })
}

function forbiddenIndexedDb(): IDBFactory {
  return new Proxy({} as IDBFactory, {
    get: () => {
      throw new Error('credential storage must not hold a session token')
    },
  })
}

function deleteDatabase(): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(CREDENTIAL_DB_NAME)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(new Error('test database cleanup failed'))
    request.onblocked = () => reject(new Error('test database cleanup blocked'))
  })
}

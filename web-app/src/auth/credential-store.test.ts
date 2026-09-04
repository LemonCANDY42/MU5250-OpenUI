import { indexedDB as fakeIndexedDB } from 'fake-indexeddb'
import { beforeEach, describe, expect, it } from 'vitest'

import {
  CREDENTIAL_DB_NAME,
  listCredentials,
  saveCredential,
  type BrowserCredential,
} from './credential-store'

describe('browser credential storage', () => {
  beforeEach(async () => {
    Object.defineProperty(globalThis, 'indexedDB', {
      configurable: true,
      value: fakeIndexedDB,
    })
    await deleteDatabase()
  })

  it('stores the CryptoKey pair and metadata while the private key stays non-exportable', async () => {
    const pair = await crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign', 'verify'],
    )
    const credential: BrowserCredential = {
      id: 'browser-key-1',
      label: 'Test browser',
      privateKey: pair.privateKey,
      publicKey: pair.publicKey,
      createdAt: 1,
    }
    await saveCredential(credential)
    const [stored] = await listCredentials()

    expect(stored.id).toBe(credential.id)
    expect(stored.label).toBe(credential.label)
    expect(stored.privateKey.extractable).toBe(false)
    expect(stored.publicKey.extractable).toBe(true)
    await expect(crypto.subtle.exportKey('pkcs8', stored.privateKey)).rejects.toThrow()
    await expect(crypto.subtle.exportKey('spki', stored.publicKey)).resolves.toBeInstanceOf(ArrayBuffer)
  })
})

function deleteDatabase(): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(CREDENTIAL_DB_NAME)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(new Error('test database cleanup failed'))
    request.onblocked = () => reject(new Error('test database cleanup blocked'))
  })
}

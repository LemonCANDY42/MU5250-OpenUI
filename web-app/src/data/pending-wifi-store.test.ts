import { indexedDB as fakeIndexedDB } from 'fake-indexeddb'
import { beforeEach, describe, expect, it } from 'vitest'

import {
  clearPendingWifiConfirmation,
  loadPendingWifiConfirmation,
  savePendingWifiConfirmation,
  WIFI_PENDING_DB_NAME,
} from './pending-wifi-store'

describe('pending Wi-Fi confirmation storage', () => {
  beforeEach(async () => {
    Object.defineProperty(globalThis, 'indexedDB', {
      configurable: true,
      value: fakeIndexedDB,
    })
    await deleteDatabase()
  })

  it('survives a page reload without browser key-value storage', async () => {
    const pending = {
      transactionId: 'abcdefghijklmnopqrstuvwx',
      expiresAt: Date.now() + 120_000,
    }
    await savePendingWifiConfirmation(pending)

    await expect(loadPendingWifiConfirmation()).resolves.toEqual(pending)
  })

  it('removes expired metadata', async () => {
    await savePendingWifiConfirmation({
      transactionId: 'abcdefghijklmnopqrstuvwx',
      expiresAt: Date.now() - 1,
    })

    await expect(loadPendingWifiConfirmation()).resolves.toBeUndefined()
    await expect(loadPendingWifiConfirmation()).resolves.toBeUndefined()
  })

  it('can be cleared after confirmation', async () => {
    await savePendingWifiConfirmation({
      transactionId: 'abcdefghijklmnopqrstuvwx',
      expiresAt: Date.now() + 120_000,
    })
    await clearPendingWifiConfirmation()

    await expect(loadPendingWifiConfirmation()).resolves.toBeUndefined()
  })
})

function deleteDatabase(): Promise<void> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(WIFI_PENDING_DB_NAME)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(new Error('test database cleanup failed'))
    request.onblocked = () => reject(new Error('test database cleanup blocked'))
  })
}

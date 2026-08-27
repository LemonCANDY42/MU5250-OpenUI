export const WIFI_PENDING_DB_NAME = 'u60-browser-state'

const STORE_NAME = 'wifi-confirmation'
const DATABASE_VERSION = 1
const RECORD_KEY = 'pending'

export interface PersistedWifiConfirmation {
  transactionId: string
  expiresAt: number
}

interface StoredWifiConfirmation extends PersistedWifiConfirmation {
  key: typeof RECORD_KEY
}

export async function savePendingWifiConfirmation(
  pending: PersistedWifiConfirmation,
): Promise<void> {
  assertPendingWifiConfirmation(pending)
  const database = await openDatabase()
  try {
    const transaction = database.transaction(STORE_NAME, 'readwrite')
    const record: StoredWifiConfirmation = { key: RECORD_KEY, ...pending }
    transaction.objectStore(STORE_NAME).put(record)
    await transactionFinished(transaction)
  } finally {
    database.close()
  }
}

export async function loadPendingWifiConfirmation(): Promise<
  PersistedWifiConfirmation | undefined
> {
  const database = await openDatabase()
  try {
    const transaction = database.transaction(STORE_NAME, 'readonly')
    const record = await requestResult<unknown>(
      transaction.objectStore(STORE_NAME).get(RECORD_KEY),
    )
    await transactionFinished(transaction)
    if (record === undefined) return undefined
    try {
      assertStoredWifiConfirmation(record)
      if (record.expiresAt > Date.now()) {
        return { transactionId: record.transactionId, expiresAt: record.expiresAt }
      }
    } catch {
      // Invalid or expired recovery metadata is removed below.
    }
  } finally {
    database.close()
  }
  await clearPendingWifiConfirmation()
  return undefined
}

export async function clearPendingWifiConfirmation(): Promise<void> {
  const database = await openDatabase()
  try {
    const transaction = database.transaction(STORE_NAME, 'readwrite')
    transaction.objectStore(STORE_NAME).delete(RECORD_KEY)
    await transactionFinished(transaction)
  } finally {
    database.close()
  }
}

function openDatabase(): Promise<IDBDatabase> {
  if (!('indexedDB' in globalThis)) {
    return Promise.reject(new Error('IndexedDB is unavailable'))
  }
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(WIFI_PENDING_DB_NAME, DATABASE_VERSION)
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME, { keyPath: 'key' })
      }
    }
    request.onerror = () => reject(new Error('Could not open the Wi-Fi recovery store'))
    request.onblocked = () => reject(new Error('The Wi-Fi recovery store is blocked'))
    request.onsuccess = () => {
      request.result.onversionchange = () => request.result.close()
      resolve(request.result)
    }
  })
}

function transactionFinished(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(new Error('Wi-Fi recovery storage failed'))
    transaction.onabort = () => reject(new Error('Wi-Fi recovery storage was aborted'))
  })
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(new Error('Wi-Fi recovery storage failed'))
  })
}

function assertStoredWifiConfirmation(
  value: unknown,
): asserts value is StoredWifiConfirmation {
  if (typeof value !== 'object' || value === null) {
    throw new Error('invalid Wi-Fi recovery record')
  }
  const record = value as Partial<StoredWifiConfirmation>
  if (record.key !== RECORD_KEY) {
    throw new Error('invalid Wi-Fi recovery record')
  }
  assertPendingWifiConfirmation(record)
}

function assertPendingWifiConfirmation(
  value: unknown,
): asserts value is PersistedWifiConfirmation {
  if (typeof value !== 'object' || value === null) {
    throw new Error('invalid Wi-Fi recovery record')
  }
  const record = value as Partial<PersistedWifiConfirmation>
  if (
    typeof record.transactionId !== 'string' ||
    !/^[A-Za-z0-9_-]{24}$/.test(record.transactionId) ||
    typeof record.expiresAt !== 'number' ||
    !Number.isSafeInteger(record.expiresAt) ||
    record.expiresAt < 0
  ) {
    throw new Error('invalid Wi-Fi recovery record')
  }
}

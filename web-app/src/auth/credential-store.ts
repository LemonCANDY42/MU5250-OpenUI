export const CREDENTIAL_DB_NAME = 'u60-browser-credentials'

const STORE_NAME = 'credentials'
const DATABASE_VERSION = 1

export interface BrowserCredential {
  id: string
  label: string
  privateKey: CryptoKey
  publicKey: CryptoKey
  createdAt: number
}

export async function saveCredential(credential: BrowserCredential): Promise<void> {
  assertCredential(credential)
  const database = await openDatabase()
  try {
    const transaction = database.transaction(STORE_NAME, 'readwrite')
    transaction.objectStore(STORE_NAME).put(credential)
    await transactionFinished(transaction)
  } finally {
    database.close()
  }
}

export async function listCredentials(): Promise<BrowserCredential[]> {
  const database = await openDatabase()
  try {
    const transaction = database.transaction(STORE_NAME, 'readonly')
    const records = await requestResult<unknown[]>(transaction.objectStore(STORE_NAME).getAll())
    await transactionFinished(transaction)
    const credentials = records.map((record) => {
      assertCredential(record)
      return record
    })
    return credentials.sort((left, right) => right.createdAt - left.createdAt)
  } finally {
    database.close()
  }
}

export async function deleteCredential(id: string): Promise<void> {
  if (!isCredentialId(id)) {
    throw new Error('invalid browser credential id')
  }
  const database = await openDatabase()
  try {
    const transaction = database.transaction(STORE_NAME, 'readwrite')
    transaction.objectStore(STORE_NAME).delete(id)
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
    const request = indexedDB.open(CREDENTIAL_DB_NAME, DATABASE_VERSION)
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME, { keyPath: 'id' })
      }
    }
    request.onerror = () => reject(new Error('Could not open the browser credential store'))
    request.onblocked = () => reject(new Error('The browser credential store is blocked'))
    request.onsuccess = () => {
      request.result.onversionchange = () => request.result.close()
      resolve(request.result)
    }
  })
}

function transactionFinished(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(new Error('Browser credential storage failed'))
    transaction.onabort = () => reject(new Error('Browser credential storage was aborted'))
  })
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(new Error('Browser credential storage failed'))
  })
}

function assertCredential(value: unknown): asserts value is BrowserCredential {
  if (typeof value !== 'object' || value === null) {
    throw new Error('invalid browser credential record')
  }
  const record = value as Partial<BrowserCredential>
  if (
    !isCredentialId(record.id) ||
    !isLabel(record.label) ||
    !isP256Key(record.privateKey, 'private', false, 'sign') ||
    !isP256Key(record.publicKey, 'public', true, 'verify') ||
    typeof record.createdAt !== 'number' ||
    !Number.isSafeInteger(record.createdAt) ||
    record.createdAt < 0
  ) {
    throw new Error('invalid browser credential record')
  }
}

function isP256Key(
  value: unknown,
  type: KeyType,
  extractable: boolean,
  usage: KeyUsage,
): value is CryptoKey {
  if (typeof value !== 'object' || value === null) {
    return false
  }
  const key = value as Partial<CryptoKey>
  const algorithm = key.algorithm as Partial<EcKeyAlgorithm> | undefined
  return (
    key.type === type &&
    key.extractable === extractable &&
    algorithm?.name === 'ECDSA' &&
    algorithm.namedCurve === 'P-256' &&
    Array.isArray(key.usages) &&
    key.usages.includes(usage)
  )
}

function isCredentialId(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(value)
}

function isLabel(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length >= 1 &&
    [...value].length <= 64 &&
    !/\p{Cc}/u.test(value)
  )
}

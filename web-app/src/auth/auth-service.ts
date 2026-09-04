import { decodeBase64Url, encodeBase64Url } from './base64url'
import {
  listCredentials,
  saveCredential,
  type BrowserCredential,
} from './credential-store'
import { normalizeP256Signature } from './signature'
import {
  AgentError,
  clearSessionToken,
  isRecord,
  postJson,
  setSessionToken,
} from '../data/client'
import type {
  V1ChallengeGrant,
  V1RegisteredCredential,
  V1SessionGrant,
} from '../data/v1-contract'

export function supportsBrowserCredentials(): boolean {
  return (
    typeof globalThis.crypto === 'object' &&
    globalThis.crypto !== null &&
    globalThis.crypto.subtle !== undefined &&
    typeof globalThis.indexedDB === 'object' &&
    globalThis.indexedDB !== null
  )
}

let activeScopes = new Set<string>()

export function hasDailyManagement(): boolean {
  return activeScopes.has('daily')
}

export async function storedCredentials(): Promise<BrowserCredential[]> {
  return listCredentials()
}

export async function pairBrowserCredential(
  pairingNonce: string,
  requestedLabel: string,
): Promise<BrowserCredential> {
  if (!supportsBrowserCredentials()) {
    throw new AgentError('This browser cannot store a local signing key')
  }
  const label = requestedLabel.trim()
  if (!/^[A-Za-z0-9_-]{43}$/.test(pairingNonce)) {
    throw new AgentError('Enter the complete one-time pairing nonce')
  }
  if (label.length < 1 || [...label].length > 64 || /\p{Cc}/u.test(label)) {
    throw new AgentError('The browser key label must be 1–64 visible characters')
  }

  const generated = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign', 'verify'],
  )
  if (!('privateKey' in generated) || generated.privateKey.extractable) {
    throw new AgentError('The browser did not create a non-exportable private key')
  }
  const publicKeySpki = encodeBase64Url(await crypto.subtle.exportKey('spki', generated.publicKey))
  const registered = parseRegisteredCredential(
    await postJson('/v1/auth/pair', {
      pairing_nonce: pairingNonce,
      label,
      public_key_spki: publicKeySpki,
    }),
  )
  const credential: BrowserCredential = {
    id: registered.id,
    label: registered.label,
    privateKey: generated.privateKey,
    publicKey: generated.publicKey,
    createdAt: Date.now(),
  }
  try {
    await saveCredential(credential)
  } catch {
    throw new AgentError(
      'The key was registered but could not be stored locally. Revoke the browser credential with the maintenance CLI before retrying.',
    )
  }
  return credential
}

export async function signInWithCredential(credential: BrowserCredential): Promise<void> {
  const challenge = parseChallenge(
    await postJson('/v1/auth/challenge', { credential_id: credential.id }),
  )
  let message: Uint8Array
  try {
    message = decodeBase64Url(challenge.message)
  } catch {
    throw new AgentError('The agent returned an invalid signing challenge')
  }
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    credential.privateKey,
    Uint8Array.from(message).buffer,
  )
  let normalized: Uint8Array
  try {
    normalized = normalizeP256Signature(signature)
  } catch {
    throw new AgentError('The browser returned an invalid P-256 signature')
  }
  const session = parseSession(
    await postJson('/v1/auth/challenge/verify', {
      credential_id: credential.id,
      challenge_id: challenge.challenge_id,
      signature: encodeBase64Url(normalized),
    }),
  )
  setSessionToken(session.token)
  activeScopes = new Set(session.scopes)
}

export async function signInWithPassword(password: string): Promise<void> {
  if (password.length === 0) {
    throw new AgentError('Enter the management password')
  }
  const session = parseSession(await postJson('/v1/auth/password/session', { password }))
  setSessionToken(session.token)
  activeScopes = new Set(session.scopes)
}

export function signOut(): void {
  clearSessionToken()
  activeScopes.clear()
}

function parseRegisteredCredential(value: unknown): V1RegisteredCredential {
  if (
    !isRecord(value) ||
    typeof value.id !== 'string' ||
    !/^[A-Za-z0-9_-]{1,64}$/.test(value.id) ||
    typeof value.label !== 'string' ||
    value.label.length < 1 ||
    [...value.label].length > 64 ||
    /\p{Cc}/u.test(value.label)
  ) {
    throw new AgentError('The agent returned an invalid browser credential')
  }
  return value as V1RegisteredCredential
}

function parseChallenge(value: unknown): V1ChallengeGrant {
  if (
    !isRecord(value) ||
    typeof value.challenge_id !== 'string' ||
    !/^[A-Za-z0-9_-]{1,64}$/.test(value.challenge_id) ||
    typeof value.message !== 'string' ||
    !/^[A-Za-z0-9_-]+$/.test(value.message) ||
    value.expires_in_seconds !== 120
  ) {
    throw new AgentError('The agent returned an invalid signing challenge')
  }
  return value as unknown as V1ChallengeGrant
}

function parseSession(value: unknown): V1SessionGrant {
  if (
    !isRecord(value) ||
    typeof value.token !== 'string' ||
    !/^[A-Za-z0-9_-]{43}$/.test(value.token) ||
    value.token_type !== 'Bearer' ||
    !Array.isArray(value.scopes) ||
    !value.scopes.includes('read') ||
    !value.scopes.every((scope) => ['read', 'daily', 'admin', 'advanced'].includes(String(scope))) ||
    !isIntegerBetween(value.idle_expires_in_seconds, 300, 3600) ||
    !isIntegerBetween(value.absolute_expires_in_seconds, 300, 43_200)
  ) {
    throw new AgentError('The agent returned an invalid session')
  }
  return value as unknown as V1SessionGrant
}

function isIntegerBetween(value: unknown, minimum: number, maximum: number): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= minimum && value <= maximum
}

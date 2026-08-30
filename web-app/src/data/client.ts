const V1_PATH = /^\/v1\/[a-z0-9/_-]+$/
const REQUEST_TIMEOUT_MS = 15_000

let sessionToken: string | null = null

export class AgentError extends Error {
  readonly status?: number
  readonly code?: string
  readonly retryAfterSeconds?: number
  readonly recoveryRequired?: boolean

  constructor(
    message: string,
    status?: number,
    code?: string,
    retryAfterSeconds?: number,
    recoveryRequired?: boolean,
  ) {
    super(message)
    this.name = 'AgentError'
    this.status = status
    this.code = code
    this.retryAfterSeconds = retryAfterSeconds
    this.recoveryRequired = recoveryRequired
  }
}

export function setSessionToken(token: string): void {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    throw new AgentError('The agent returned an invalid session token')
  }
  sessionToken = token
}

export function clearSessionToken(): void {
  sessionToken = null
}

export function hasSessionToken(): boolean {
  return sessionToken !== null
}

export async function getJson(path: string): Promise<unknown> {
  return requestJson('GET', path)
}

export async function postJson(path: string, body: unknown): Promise<unknown> {
  return requestJson('POST', path, body)
}

export async function putJson(path: string, body: unknown): Promise<unknown> {
  return requestJson('PUT', path, body)
}

async function requestJson(
  method: 'GET' | 'POST' | 'PUT',
  path: string,
  body?: unknown,
): Promise<unknown> {
  if (!V1_PATH.test(path)) {
    throw new AgentError('Refused a request outside the versioned agent API')
  }

  const headers = new Headers({ Accept: 'application/json' })
  if (sessionToken !== null) {
    headers.set('Authorization', `Bearer ${sessionToken}`)
  }
  if (body !== undefined) {
    headers.set('Content-Type', 'application/json')
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
  try {
    let response: Response
    try {
      response = await fetch(path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: 'no-store',
        credentials: 'same-origin',
        signal: controller.signal,
      })
    } catch {
      if (controller.signal.aborted) {
        throw new AgentError('The secure local agent request timed out')
      }
      throw new AgentError('The secure local agent could not be reached')
    }

    if (response.status === 401) {
      clearSessionToken()
    }
    const contentType = response.headers.get('content-type') ?? ''
    if (!contentType.toLowerCase().startsWith('application/json')) {
      throw new AgentError('The agent returned an invalid response', response.status)
    }

    let payload: unknown
    try {
      payload = await response.json()
    } catch {
      if (controller.signal.aborted) {
        throw new AgentError('The secure local agent request timed out')
      }
      throw new AgentError('The agent returned invalid JSON', response.status)
    }
    if (!isRecord(payload) || typeof payload.ok !== 'boolean') {
      throw new AgentError('The agent returned an invalid response envelope', response.status)
    }
    if (!response.ok || payload.ok !== true) {
      const error = isRecord(payload.error) ? payload.error : {}
      const message =
        typeof error.message === 'string' ? error.message : 'The agent rejected the request'
      const code = typeof error.code === 'string' ? error.code : undefined
      const retry =
        typeof error.retry_after_seconds === 'number' && Number.isInteger(error.retry_after_seconds)
          ? error.retry_after_seconds
          : undefined
      const recovery = isRecord(error.recovery) ? error.recovery : undefined
      const recoveryRequired =
        recovery !== undefined && typeof recovery.required === 'boolean'
          ? recovery.required
          : undefined
      throw new AgentError(message, response.status, code, retry, recoveryRequired)
    }
    if (!('data' in payload)) {
      throw new AgentError('The agent response omitted data', response.status)
    }
    return payload.data
  } finally {
    clearTimeout(timeout)
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

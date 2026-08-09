// HTTP client for the agent: token handling, envelope unwrapping, timeouts.

export const API_BASE = `http://${window.location.hostname}:9090`
export const AUTH_EXPIRED_EVENT = 'zte-auth-expired'

let _token: string | null = sessionStorage.getItem('zte_token')

export function setToken(t: string) {
  _token = t
  sessionStorage.setItem('zte_token', t)
}

export function clearToken() {
  _token = null
  sessionStorage.removeItem('zte_token')
}

export function hasToken() {
  return !!_token
}

export class ApiError extends Error {
  status?: number

  constructor(message: string, status?: number) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

function emitAuthExpired() {
  clearToken()
  window.dispatchEvent(new Event(AUTH_EXPIRED_EVENT))
}

export async function req(
  method: string,
  path: string,
  body?: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = 15_000,
): Promise<Record<string, unknown>> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  const headers: Record<string, string> = { ...(extraHeaders ?? {}) }
  if (_token) headers['Authorization'] = `Bearer ${_token}`
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  try {
    let res: Response
    try {
      res = await fetch(`${API_BASE}${path}`, {
        method,
        headers,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        throw new ApiError('Timed out reaching the agent')
      }
      throw new ApiError(`Failed to reach the agent at ${API_BASE}`)
    }

    let json: { ok?: boolean; data?: unknown; error?: string }
    try {
      json = await res.json()
    } catch {
      throw new ApiError(`Invalid response from agent (${res.status})`, res.status)
    }

    if (res.status === 401 && path !== '/api/auth/login') {
      emitAuthExpired()
    }
    if (!res.ok || !json.ok) {
      throw new ApiError(json.error ?? `request failed (${res.status})`, res.status)
    }
    return (json.data ?? {}) as Record<string, unknown>
  } finally {
    clearTimeout(timeout)
  }
}

export const get = (path: string) => req('GET', path)
export const post = (path: string, body?: unknown, extraHeaders?: Record<string, string>) =>
  req('POST', path, body, extraHeaders)
export const put = (path: string, body: unknown) => req('PUT', path, body)

export async function login(
  credentials: string | { password?: string; pin?: string },
): Promise<{ token: string }> {
  const body = typeof credentials === 'string' ? { password: credentials } : credentials
  const data = await req('POST', '/api/auth/login', body)
  return { token: data.token as string }
}

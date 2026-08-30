import { afterEach, describe, expect, it, vi } from 'vitest'

import { clearSessionToken, getJson, postJson } from './client'

describe('agent request timeout', () => {
  afterEach(() => {
    clearSessionToken()
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('aborts a request that never settles', async () => {
    vi.useFakeTimers()
    let signal: AbortSignal | undefined
    vi.stubGlobal(
      'fetch',
      vi.fn((_input: string | URL | Request, init?: RequestInit) => {
        signal = init?.signal ?? undefined
        return new Promise<Response>((_resolve, reject) => {
          signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
        })
      }),
    )

    const request = getJson('/v1/device')
    const rejected = expect(request).rejects.toThrow('request timed out')
    await vi.advanceTimersByTimeAsync(15_000)
    await rejected
    expect(signal?.aborted).toBe(true)
  })

  it('preserves typed recovery metadata from a rejected Wi-Fi write', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            ok: false,
            error: {
              code: 'source_unavailable',
              message: 'automatic recovery remains pending',
              recovery: { required: true },
            },
          }),
          { status: 503, headers: { 'content-type': 'application/json' } },
        ),
      ),
    )

    await expect(postJson('/v1/wifi/transaction', {})).rejects.toMatchObject({
      status: 503,
      code: 'source_unavailable',
      recoveryRequired: true,
    })
  })
})

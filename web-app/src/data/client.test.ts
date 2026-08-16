import { afterEach, describe, expect, it, vi } from 'vitest'

import { clearSessionToken, getJson } from './client'

describe('agent request timeout', () => {
  afterEach(() => {
    clearSessionToken()
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
})

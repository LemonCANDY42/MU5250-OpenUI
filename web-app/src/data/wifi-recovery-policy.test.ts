import { describe, expect, it } from 'vitest'

import { AgentError } from './client'
import { shouldKeepPendingWifiTransaction } from './wifi-recovery-policy'

describe('Wi-Fi transaction recovery policy', () => {
  it('clears terminal server outcomes and keeps ambiguous confirmation outcomes', () => {
    const terminalConflict = new AgentError('no transaction is pending', 409, 'state_conflict')
    const restored = new AgentError(
      'old settings were restored',
      503,
      'source_unavailable',
      undefined,
      false,
    )
    const recoveryPending = new AgentError(
      'automatic recovery remains pending',
      503,
      'source_unavailable',
      undefined,
      true,
    )
    const expiredSession = new AgentError('session expired', 401, 'authentication_failed')
    const unreachable = new AgentError('agent unreachable')
    const unexpectedServerFailure = new AgentError('unexpected response', 500, 'internal_error')

    expect(shouldKeepPendingWifiTransaction(terminalConflict, 'begin')).toBe(false)
    expect(shouldKeepPendingWifiTransaction(terminalConflict, 'confirm')).toBe(false)
    expect(shouldKeepPendingWifiTransaction(restored, 'confirm')).toBe(false)
    expect(shouldKeepPendingWifiTransaction(recoveryPending, 'confirm')).toBe(true)
    expect(shouldKeepPendingWifiTransaction(expiredSession, 'begin')).toBe(false)
    expect(shouldKeepPendingWifiTransaction(expiredSession, 'confirm')).toBe(true)
    expect(shouldKeepPendingWifiTransaction(unreachable, 'begin')).toBe(true)
    expect(shouldKeepPendingWifiTransaction(unreachable, 'confirm')).toBe(true)
    expect(shouldKeepPendingWifiTransaction(unexpectedServerFailure, 'confirm')).toBe(true)
  })
})

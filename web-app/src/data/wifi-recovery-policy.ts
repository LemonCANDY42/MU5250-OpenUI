import { AgentError } from './client'

export type WifiTransactionPhase = 'begin' | 'confirm'

export function shouldKeepPendingWifiTransaction(
  reason: unknown,
  phase: WifiTransactionPhase,
): boolean {
  if (!(reason instanceof AgentError) || reason.status === undefined) {
    return true
  }
  if (phase === 'confirm' && reason.status === 401) {
    return true
  }
  if (reason.status === 401 || reason.status === 400 || reason.status === 409) {
    return false
  }
  if (reason.status === 503) {
    return reason.recoveryRequired !== false
  }
  return true
}

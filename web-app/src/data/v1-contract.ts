import type { components, paths } from '../generated/u60-v1'

export type V1Device = components['schemas']['Device']
export type V1CapabilityReport = components['schemas']['CapabilityReport']
export type V1SystemStatus = components['schemas']['SystemStatus']
export type V1BatteryStatus = components['schemas']['BatteryStatus']
export type V1ThermalStatus = components['schemas']['ThermalStatus']
export type V1SignalStatus = components['schemas']['SignalStatus']
export type V1CellularStatus = components['schemas']['CellularStatus']
export type V1TrafficStatus = components['schemas']['TrafficStatus']
export type V1WifiStatus = components['schemas']['WifiStatus']
export type V1LanClients = components['schemas']['LanClients']
export type V1SmsPage = components['schemas']['SmsPage']
export type V1Capability = components['schemas']['Capability']
export type V1CapabilityStatus = components['schemas']['CapabilityStatus']
export type V1SessionGrant = components['schemas']['SessionGrant']
export type V1ChallengeGrant = components['schemas']['ChallengeGrant']
export type V1RegisteredCredential = components['schemas']['RegisteredCredential']
export type V1ChargingStatus = components['schemas']['ChargingStatus']
export type V1DashboardSnapshot = components['schemas']['DashboardSnapshot']
export type V1DashboardFailure = components['schemas']['DashboardFailure']
export type V1WifiTransactionGrant = components['schemas']['WifiTransactionGrant']
export type V1WriteResult = components['schemas']['WriteResult']

export interface V1ReadClientContract {
  device(): Promise<V1Device>
  capabilities(): Promise<V1CapabilityReport>
  dashboard(): Promise<V1DashboardSnapshot>
  systemStatus(): Promise<V1SystemStatus>
  batteryStatus(): Promise<V1BatteryStatus>
  thermalStatus(): Promise<V1ThermalStatus>
  signalStatus(): Promise<V1SignalStatus>
  cellularStatus(): Promise<V1CellularStatus>
  trafficStatus(): Promise<V1TrafficStatus>
  wifiStatus(): Promise<V1WifiStatus>
  lanClients(): Promise<V1LanClients>
  smsList(): Promise<V1SmsPage>
}

/** Compile-time guard that every first-slice client path exists in OpenAPI. */
export const V1_READ_PATHS = [
  '/v1/device',
  '/v1/capabilities',
  '/v1/status/dashboard',
  '/v1/status/system',
  '/v1/status/battery',
  '/v1/status/thermal',
  '/v1/status/signal',
  '/v1/status/cellular',
  '/v1/status/traffic',
  '/v1/status/wifi',
  '/v1/lan/clients',
  '/v1/sms',
] as const satisfies readonly (keyof paths)[]

export const V1_DAILY_PATHS = [
  '/v1/sms/send',
  '/v1/charging',
  '/v1/traffic/cycle',
  '/v1/wifi/transaction',
  '/v1/wifi/transaction/confirm',
] as const satisfies readonly (keyof paths)[]

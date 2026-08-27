import { AgentError, getJson, isRecord } from './client'
import type {
  V1BatteryStatus,
  V1Capability,
  V1CapabilityReport,
  V1CellularStatus,
  V1Device,
  V1LanClients,
  V1SignalStatus,
  V1SmsPage,
  V1SystemStatus,
  V1ThermalStatus,
  V1TrafficStatus,
  V1WifiStatus,
} from './v1-contract'

type CapabilityId = V1Capability['id']
type PanelValue =
  | V1Device
  | V1SystemStatus
  | V1BatteryStatus
  | V1ThermalStatus
  | V1SignalStatus
  | V1CellularStatus
  | V1TrafficStatus
  | V1WifiStatus
  | V1LanClients
  | V1SmsPage

export interface DashboardPanel {
  capability: V1Capability
  value?: PanelValue
  error?: string
}

export interface DashboardSnapshot {
  report: V1CapabilityReport
  panels: readonly DashboardPanel[]
}

export function batteryCapacityHealthPercent(
  learnedFullCapacityMah: number | undefined,
  designCapacityMah: number | undefined,
): number | undefined {
  if (
    learnedFullCapacityMah === undefined ||
    designCapacityMah === undefined ||
    !Number.isFinite(learnedFullCapacityMah) ||
    !Number.isFinite(designCapacityMah) ||
    learnedFullCapacityMah <= 0 ||
    designCapacityMah <= 0
  ) {
    return undefined
  }
  const percent = (learnedFullCapacityMah / designCapacityMah) * 100
  return Number.isFinite(percent) ? percent : undefined
}

const ENDPOINTS: Readonly<
  Record<CapabilityId, { path: string; parse: (value: unknown) => PanelValue }>
> = {
  device_identity: { path: '/v1/device', parse: parseDevice },
  system_status: { path: '/v1/status/system', parse: parseSystem },
  battery_status: { path: '/v1/status/battery', parse: parseBattery },
  thermal_status: { path: '/v1/status/thermal', parse: parseThermal },
  signal_status: { path: '/v1/status/signal', parse: parseSignal },
  cellular_status: { path: '/v1/status/cellular', parse: parseCellular },
  traffic_status: { path: '/v1/status/traffic', parse: parseTraffic },
  wifi_status: { path: '/v1/status/wifi', parse: parseWifi },
  lan_clients: { path: '/v1/lan/clients', parse: parseLanClients },
  sms_list: { path: '/v1/sms', parse: parseSmsPage },
}

export async function loadDashboard(): Promise<DashboardSnapshot> {
  const report = parseCapabilityReport(await getJson('/v1/capabilities'))
  const panels = await Promise.all(
    report.capabilities.map(async (capability): Promise<DashboardPanel> => {
      if (capability.status === 'unsupported') {
        return { capability }
      }
      const endpoint = ENDPOINTS[capability.id]
      try {
        return {
          capability,
          value: endpoint.parse(await getJson(endpoint.path)),
        }
      } catch (error) {
        if (error instanceof AgentError && error.status === 401) {
          throw error
        }
        return {
          capability,
          error: error instanceof Error ? error.message : 'Status unavailable',
        }
      }
    }),
  )
  return { report, panels }
}

function parseCapabilityReport(value: unknown): V1CapabilityReport {
  if (
    !isRecord(value) ||
    typeof value.adapter !== 'string' ||
    typeof value.firmware_target !== 'string' ||
    !Array.isArray(value.capabilities)
  ) {
    throw new AgentError('The agent returned an invalid capability report')
  }
  const capabilities = value.capabilities.map(parseCapability)
  const ids = new Set(capabilities.map((capability) => capability.id))
  if (
    capabilities.length !== 10 ||
    ids.size !== 10 ||
    Object.keys(ENDPOINTS).some((id) => !ids.has(id as CapabilityId))
  ) {
    throw new AgentError('The agent capability report is incomplete')
  }
  return {
    adapter: value.adapter,
    firmware_target: value.firmware_target,
    capabilities,
  }
}

function parseCapability(value: unknown): V1Capability {
  if (!isRecord(value) || !isCapabilityId(value.id)) {
    throw new AgentError('The agent returned an invalid capability')
  }
  if (!['available', 'degraded', 'unsupported'].includes(String(value.status))) {
    throw new AgentError('The agent returned an invalid capability state')
  }
  if (
    !isRecord(value.recovery) ||
    typeof value.recovery.required !== 'boolean' ||
    (value.recovery.action !== undefined && typeof value.recovery.action !== 'string') ||
    (value.reason !== undefined && typeof value.reason !== 'string')
  ) {
    throw new AgentError('The agent returned invalid capability recovery metadata')
  }
  return value as unknown as V1Capability
}

function parseDevice(value: unknown): V1Device {
  if (
    !isRecord(value) ||
    !hasStrings(value, ['manufacturer', 'model', 'adapter', 'firmware_target']) ||
    (value.firmware_version !== undefined && typeof value.firmware_version !== 'string') ||
    (value.hardware_version !== undefined && typeof value.hardware_version !== 'string')
  ) {
    throw new AgentError('The agent returned invalid device identity')
  }
  return value as unknown as V1Device
}

function parseSystem(value: unknown): V1SystemStatus {
  const validMemory =
    value !== null &&
    isRecord(value) &&
    optionalCapacityGroup(
      value.memory_total_mb,
      value.memory_available_mb,
      value.memory_used_percent,
    )
  const validStorage =
    value !== null &&
    isRecord(value) &&
    optionalCapacityGroup(
      value.storage_total_mb,
      value.storage_available_mb,
      value.storage_used_percent,
    )
  if (
    !isRecord(value) ||
    !hasStrings(value, ['hostname', 'kernel']) ||
    !isNonNegativeInteger(value.uptime_seconds) ||
    !Array.isArray(value.load_average) ||
    value.load_average.length !== 3 ||
    !value.load_average.every(isFiniteNumber) ||
    !optionalPercent(value.cpu_usage_percent) ||
    !validMemory ||
    !validStorage
  ) {
    throw new AgentError('The agent returned invalid system status')
  }
  return value as unknown as V1SystemStatus
}

function parseBattery(value: unknown): V1BatteryStatus {
  const normalizedState =
    isRecord(value) && typeof value.state === 'string'
      ? value.state.trim().toLowerCase().replaceAll('_', ' ')
      : ''
  if (
    !isRecord(value) ||
    typeof value.state !== 'string' ||
    !isNonNegativeInteger(value.capacity_percent) ||
    value.capacity_percent > 100 ||
    !Number.isInteger(value.voltage_mv) ||
    !Number.isInteger(value.current_ma) ||
    !Number.isInteger(value.power_mw) ||
    !isFiniteNumber(value.temperature_c) ||
    (value.health !== undefined && !BATTERY_HEALTH_VALUES.has(String(value.health))) ||
    !optionalBoundedInteger(value.cycle_count, 1, 100_000) ||
    !optionalBoundedInteger(value.learned_full_capacity_mah, 1, 1_000_000) ||
    !optionalBoundedInteger(value.design_capacity_mah, 1, 1_000_000) ||
    !optionalBoundedInteger(value.charge_counter_mah, -1_000_000, 1_000_000) ||
    !optionalBoundedInteger(value.time_to_empty_seconds, 0, 2_592_000) ||
    !optionalBoundedInteger(value.time_to_full_seconds, 0, 2_592_000) ||
    (value.time_to_empty_seconds !== undefined && normalizedState !== 'discharging') ||
    (value.time_to_full_seconds !== undefined &&
      normalizedState !== 'charging' &&
      !(normalizedState === 'full' && value.time_to_full_seconds === 0))
  ) {
    throw new AgentError('The agent returned invalid battery status')
  }
  return value as unknown as V1BatteryStatus
}

const BATTERY_HEALTH_VALUES = new Set([
  'good',
  'overheat',
  'dead',
  'over_voltage',
  'under_voltage',
  'unspecified_failure',
  'cold',
  'watchdog_timer_expire',
  'safety_timer_expire',
  'over_current',
  'calibration_required',
  'warm',
  'cool',
  'hot',
  'no_battery',
  'blown_fuse',
  'cell_imbalance',
])

function parseThermal(value: unknown): V1ThermalStatus {
  if (
    !isRecord(value) ||
    !Array.isArray(value.sensors) ||
    !value.sensors.every(
      (sensor) =>
        isRecord(sensor) && typeof sensor.sensor === 'string' && isFiniteNumber(sensor.temperature_c),
    )
  ) {
    throw new AgentError('The agent returned invalid thermal status')
  }
  return value as unknown as V1ThermalStatus
}

function parseSignal(value: unknown): V1SignalStatus {
  if (
    !isRecord(value) ||
    typeof value.network_type !== 'string' ||
    !isNonNegativeInteger(value.bars) ||
    value.bars > 5 ||
    typeof value.roaming !== 'boolean' ||
    !optionalString(value.provider) ||
    !optionalString(value.active_band) ||
    !optionalRadio(value.lte) ||
    !optionalRadio(value.nr5g) ||
    (value.network_selection_mode !== undefined &&
      !['automatic', 'manual', 'unknown'].includes(String(value.network_selection_mode))) ||
    !isOptionalCarrierAggregation(value.lte_carrier_aggregation) ||
    !isOptionalCarrierAggregation(value.nr5g_carrier_aggregation) ||
    (value.cell_lock !== undefined &&
      (!isRecord(value.cell_lock) ||
        typeof value.cell_lock.lte !== 'boolean' ||
        typeof value.cell_lock.nr5g !== 'boolean'))
  ) {
    throw new AgentError('The agent returned invalid signal status')
  }
  return value as unknown as V1SignalStatus
}

function isOptionalCarrierAggregation(value: unknown): boolean {
  if (value === undefined) return true
  return (
    isRecord(value) &&
    typeof value.active === 'boolean' &&
    isStringArray(value.bands, 8)
  )
}

function optionalRadio(value: unknown): boolean {
  if (value === undefined) return true
  if (!isRecord(value)) return false
  return (
    optionalString(value.band) &&
    optionalString(value.bandwidth) &&
    optionalNonNegativeInteger(value.channel) &&
    optionalNonNegativeInteger(value.pci) &&
    optionalNonNegativeInteger(value.cell_id) &&
    optionalFiniteNumber(value.rsrp_dbm) &&
    optionalFiniteNumber(value.rsrq_db) &&
    optionalFiniteNumber(value.rssi_dbm) &&
    optionalFiniteNumber(value.snr_db)
  )
}

function parseCellular(value: unknown): V1CellularStatus {
  if (
    !isRecord(value) ||
    typeof value.connected !== 'boolean' ||
    !isNonNegativeInteger(value.uptime_seconds) ||
    typeof value.protocol !== 'string' ||
    !optionalString(value.interface) ||
    !isStringArray(value.ipv4_addresses, 8) ||
    !isStringArray(value.ipv6_addresses, 8)
  ) {
    throw new AgentError('The agent returned invalid cellular status')
  }
  return value as unknown as V1CellularStatus
}

function parseTraffic(value: unknown): V1TrafficStatus {
  if (
    !isRecord(value) ||
    !isTrafficPeriod(value.day) ||
    !isTrafficPeriod(value.cycle) ||
    !isTrafficPeriod(value.since_power_on) ||
    !isTrafficPeriod(value.total) ||
    !isNonNegativeInteger(value.reset_day) ||
    value.reset_day < 1 ||
    value.reset_day > 31 ||
    typeof value.reset_enabled !== 'boolean'
  ) {
    throw new AgentError('The agent returned invalid traffic status')
  }
  return value as unknown as V1TrafficStatus
}

function isTrafficPeriod(value: unknown): boolean {
  return (
    isRecord(value) &&
    isNonNegativeInteger(value.rx_bytes) &&
    isNonNegativeInteger(value.tx_bytes) &&
    isNonNegativeInteger(value.rx_packets) &&
    isNonNegativeInteger(value.tx_packets) &&
    isNonNegativeInteger(value.time_seconds)
  )
}

function parseWifi(value: unknown): V1WifiStatus {
  if (
    !isRecord(value) ||
    typeof value.enabled !== 'boolean' ||
    !Array.isArray(value.bands) ||
    value.bands.length > 2 ||
    !value.bands.every(isWifiBand) ||
    !isOptionalCurrentClientLink(value.current_client_link)
  ) {
    throw new AgentError('The agent returned invalid Wi-Fi status')
  }
  return value as unknown as V1WifiStatus
}

function isOptionalCurrentClientLink(value: unknown): boolean {
  if (value === undefined) return true
  if (
    !isRecord(value) ||
    value.observation !== 'router_observed' ||
    typeof value.band !== 'string' ||
    !Number.isInteger(value.signal_dbm) ||
    Number(value.signal_dbm) < -127 ||
    Number(value.signal_dbm) > 0 ||
    !isFiniteNumber(value.tx_bitrate_mbps) ||
    Number(value.tx_bitrate_mbps) < 0 ||
    !isFiniteNumber(value.rx_bitrate_mbps) ||
    Number(value.rx_bitrate_mbps) < 0 ||
    !optionalFiniteNumber(value.expected_throughput_mbps) ||
    !isNonNegativeInteger(value.connected_seconds)
  ) {
    return false
  }
  return true
}

function isWifiBand(value: unknown): boolean {
  return (
    isRecord(value) &&
    hasStrings(value, ['band', 'ssid', 'encryption', 'channel', 'bandwidth']) &&
    typeof value.enabled === 'boolean' &&
    typeof value.hidden === 'boolean' &&
    optionalNonNegativeInteger(value.clients) &&
    (value.transmit_power_percent === undefined ||
      (isNonNegativeInteger(value.transmit_power_percent) &&
        value.transmit_power_percent <= 100))
  )
}

function parseLanClients(value: unknown): V1LanClients {
  if (
    !isRecord(value) ||
    !Array.isArray(value.clients) ||
    value.clients.length > 256 ||
    !value.clients.every(
      (client) =>
        isRecord(client) &&
        hasStrings(client, ['hostname', 'ipv4_address', 'mac_address']) &&
        isNonNegativeInteger(client.expires_seconds),
    )
  ) {
    throw new AgentError('The agent returned an invalid LAN client list')
  }
  return value as unknown as V1LanClients
}

function parseSmsPage(value: unknown): V1SmsPage {
  if (
    !isRecord(value) ||
    !isNonNegativeInteger(value.page) ||
    !isNonNegativeInteger(value.per_page) ||
    value.per_page < 1 ||
    value.per_page > 100 ||
    !isNonNegativeInteger(value.omitted_messages) ||
    value.omitted_messages > value.per_page ||
    !Array.isArray(value.messages) ||
    value.messages.length + value.omitted_messages > value.per_page ||
    !value.messages.every(
      (message) =>
        isRecord(message) &&
        isNonNegativeInteger(message.id) &&
        message.id > 0 &&
        isBoundedString(message.sender, 64) &&
        isBoundedString(message.timestamp, 64) &&
        isBoundedString(message.content, 4096) &&
        typeof message.content_truncated === 'boolean' &&
        typeof message.read === 'boolean',
    )
  ) {
    throw new AgentError('The agent returned an invalid SMS page')
  }
  return value as unknown as V1SmsPage
}

function isCapabilityId(value: unknown): value is CapabilityId {
  return Object.hasOwn(ENDPOINTS, String(value))
}

function hasStrings(record: Record<string, unknown>, names: readonly string[]): boolean {
  return names.every((name) => typeof record[name] === 'string')
}

function isBoundedString(value: unknown, maximum: number): value is string {
  return typeof value === 'string' && value.length <= maximum
}

function optionalString(value: unknown): boolean {
  return value === undefined || typeof value === 'string'
}

function isStringArray(value: unknown, maximum: number): boolean {
  return Array.isArray(value) && value.length <= maximum && value.every((item) => typeof item === 'string')
}

function optionalNonNegativeInteger(value: unknown): boolean {
  return value === undefined || isNonNegativeInteger(value)
}

function optionalFiniteNumber(value: unknown): boolean {
  return value === undefined || isFiniteNumber(value)
}

function optionalPercent(value: unknown): boolean {
  return value === undefined || (isFiniteNumber(value) && value >= 0 && value <= 100)
}

function optionalBoundedInteger(value: unknown, minimum: number, maximum: number): boolean {
  return (
    value === undefined ||
    (typeof value === 'number' &&
      Number.isSafeInteger(value) &&
      value >= minimum &&
      value <= maximum)
  )
}

function optionalCapacityGroup(total: unknown, available: unknown, usedPercent: unknown): boolean {
  if (total === undefined && available === undefined && usedPercent === undefined) return true
  return (
    isNonNegativeInteger(total) &&
    isNonNegativeInteger(available) &&
    available <= total &&
    isFiniteNumber(usedPercent) &&
    usedPercent >= 0 &&
    usedPercent <= 100
  )
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

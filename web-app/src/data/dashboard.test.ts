import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./client')>()
  return { ...actual, getJson: vi.fn() }
})

import { AgentError, getJson } from './client'
import { batteryCapacityHealthPercent, loadDashboard } from './dashboard'

const getJsonMock = vi.mocked(getJson)

describe('capability-driven dashboard loading', () => {
  beforeEach(() => {
    getJsonMock.mockReset()
  })

  it('does not request unsupported data and still requests degraded data', async () => {
    const responses = fixtures({ battery_status: 'unsupported', thermal_status: 'degraded' })
    getJsonMock.mockImplementation(async (path) => responses[path])

    const snapshot = await loadDashboard()
    expect(getJsonMock.mock.calls.map(([path]) => path)).toEqual([
      '/v1/capabilities',
      '/v1/device',
      '/v1/status/system',
      '/v1/status/thermal',
      '/v1/status/signal',
      '/v1/status/cellular',
      '/v1/status/traffic',
      '/v1/status/wifi',
      '/v1/lan/clients',
      '/v1/sms',
    ])
    expect(
      snapshot.panels.find((panel) => panel.capability.id === 'battery_status')?.value,
    ).toBeUndefined()
    expect(
      snapshot.panels.find((panel) => panel.capability.id === 'thermal_status')?.value,
    ).toBeDefined()
  })

  it('uses only the contracted read paths when every capability is available', async () => {
    const responses = fixtures({})
    getJsonMock.mockImplementation(async (path) => responses[path])

    await loadDashboard()
    expect(new Set(getJsonMock.mock.calls.map(([path]) => path))).toEqual(
      new Set([
        '/v1/capabilities',
        '/v1/device',
        '/v1/status/system',
        '/v1/status/battery',
        '/v1/status/thermal',
        '/v1/status/signal',
        '/v1/status/cellular',
        '/v1/status/traffic',
        '/v1/status/wifi',
        '/v1/lan/clients',
        '/v1/sms',
      ]),
    )
  })

  it('propagates an authentication failure instead of rendering partial stale state', async () => {
    const responses = fixtures({})
    getJsonMock.mockImplementation(async (path) => {
      if (path === '/v1/status/system') {
        throw new AgentError('authentication failed', 401, 'authentication_failed')
      }
      return responses[path]
    })

    await expect(loadDashboard()).rejects.toMatchObject({ status: 401 })
  })

  it('accepts earlier V1 status payloads without the new optional context fields', async () => {
    const responses = fixtures({})
    const signal = responses['/v1/status/signal'] as Record<string, unknown>
    delete signal.network_selection_mode
    delete signal.lte_carrier_aggregation
    delete signal.nr5g_carrier_aggregation
    delete signal.cell_lock
    const wifi = responses['/v1/status/wifi'] as Record<string, unknown>
    delete wifi.current_client_link
    const system = responses['/v1/status/system'] as Record<string, unknown>
    delete system.cpu_usage_percent
    delete system.memory_total_mb
    delete system.memory_available_mb
    delete system.memory_used_percent
    delete system.storage_total_mb
    delete system.storage_available_mb
    delete system.storage_used_percent
    const battery = responses['/v1/status/battery'] as Record<string, unknown>
    delete battery.health
    delete battery.cycle_count
    delete battery.learned_full_capacity_mah
    delete battery.design_capacity_mah
    delete battery.charge_counter_mah
    delete battery.time_to_full_seconds
    getJsonMock.mockImplementation(async (path) => responses[path])

    await expect(loadDashboard()).resolves.toBeDefined()
  })

  it('strictly rejects invalid optional system and battery metrics', async () => {
    const invalidMutations: ((responses: Record<string, unknown>) => void)[] = [
      (responses) => {
        const system = responses['/v1/status/system'] as Record<string, unknown>
        system.cpu_usage_percent = 101
      },
      (responses) => {
        const system = responses['/v1/status/system'] as Record<string, unknown>
        system.memory_available_mb = 9000
      },
      (responses) => {
        const battery = responses['/v1/status/battery'] as Record<string, unknown>
        battery.health = 'Unknown'
      },
      (responses) => {
        const battery = responses['/v1/status/battery'] as Record<string, unknown>
        battery.cycle_count = 100_001
      },
      (responses) => {
        const battery = responses['/v1/status/battery'] as Record<string, unknown>
        battery.cycle_count = 0
      },
      (responses) => {
        const battery = responses['/v1/status/battery'] as Record<string, unknown>
        battery.time_to_full_seconds = 2_592_001
      },
      (responses) => {
        const battery = responses['/v1/status/battery'] as Record<string, unknown>
        battery.time_to_empty_seconds = 60
      },
      (responses) => {
        const battery = responses['/v1/status/battery'] as Record<string, unknown>
        battery.state = 'Full'
        battery.time_to_full_seconds = 1
      },
    ]

    for (const mutate of invalidMutations) {
      const responses = fixtures({})
      mutate(responses)
      getJsonMock.mockImplementation(async (path) => responses[path])
      const snapshot = await loadDashboard()
      expect(
        snapshot.panels.some(
          (panel) =>
            (panel.capability.id === 'system_status' || panel.capability.id === 'battery_status') &&
            panel.error !== undefined,
        ),
      ).toBe(true)
    }
  })

  it('accepts zero kernel completion estimates only in applicable battery states', async () => {
    const chargingResponses = fixtures({})
    const chargingBattery = chargingResponses['/v1/status/battery'] as Record<string, unknown>
    chargingBattery.time_to_full_seconds = 0
    getJsonMock.mockImplementation(async (path) => chargingResponses[path])
    await expect(loadDashboard()).resolves.toBeDefined()

    const fullResponses = fixtures({})
    const fullBattery = fullResponses['/v1/status/battery'] as Record<string, unknown>
    fullBattery.state = 'Full'
    fullBattery.time_to_full_seconds = 0
    delete fullBattery.time_to_empty_seconds
    getJsonMock.mockImplementation(async (path) => fullResponses[path])
    const snapshot = await loadDashboard()
    expect(
      snapshot.panels.find((panel) => panel.capability.id === 'battery_status')?.error,
    ).toBeUndefined()
  })
})

describe('battery capacity health', () => {
  it('uses design capacity as the baseline without clamping above 100 percent', () => {
    expect(batteryCapacityHealthPercent(5250, 5000)).toBe(105)
  })

  it('omits the metric when either capacity is unavailable or invalid', () => {
    expect(batteryCapacityHealthPercent(undefined, 5000)).toBeUndefined()
    expect(batteryCapacityHealthPercent(5000, undefined)).toBeUndefined()
    expect(batteryCapacityHealthPercent(5000, 0)).toBeUndefined()
  })
})

type CapabilityState = 'available' | 'degraded' | 'unsupported'

function fixtures(overrides: Partial<Record<string, CapabilityState>>): Record<string, unknown> {
  const capability = (id: string) => ({
    id,
    status: overrides[id] ?? 'available',
    reason: overrides[id] === 'degraded' ? 'partial source' : undefined,
    recovery: { required: overrides[id] !== undefined, action: 'check source' },
  })
  return {
    '/v1/capabilities': {
      adapter: 'b04',
      firmware_target: 'HK_B04',
      capabilities: [
        capability('device_identity'),
        capability('system_status'),
        capability('battery_status'),
        capability('thermal_status'),
        capability('signal_status'),
        capability('cellular_status'),
        capability('traffic_status'),
        capability('wifi_status'),
        capability('lan_clients'),
        capability('sms_list'),
      ],
    },
    '/v1/device': {
      manufacturer: 'ZTE',
      model: 'MU5250',
      adapter: 'b04',
      firmware_target: 'HK_B04',
    },
    '/v1/status/system': {
      hostname: 'u60',
      kernel: 'test',
      uptime_seconds: 10,
      load_average: [0, 0, 0],
      cpu_usage_percent: 12.5,
      memory_total_mb: 4096,
      memory_available_mb: 1024,
      memory_used_percent: 75,
      storage_total_mb: 65536,
      storage_available_mb: 32768,
      storage_used_percent: 50,
    },
    '/v1/status/battery': {
      state: 'charging',
      capacity_percent: 80,
      voltage_mv: 4000,
      current_ma: 100,
      power_mw: 400,
      temperature_c: 30,
      health: 'good',
      cycle_count: 321,
      learned_full_capacity_mah: 4800,
      design_capacity_mah: 5000,
      charge_counter_mah: -120,
      time_to_full_seconds: 0,
    },
    '/v1/status/thermal': {
      sensors: [{ sensor: 'battery', temperature_c: 30 }],
    },
    '/v1/status/signal': {
      network_type: 'NR5G',
      provider: 'Example',
      bars: 4,
      roaming: false,
      network_selection_mode: 'automatic',
      lte_carrier_aggregation: { active: false, bands: [] },
      nr5g_carrier_aggregation: { active: false, bands: [] },
      cell_lock: { lte: false, nr5g: false },
      nr5g: { band: 'n78', rsrp_dbm: -88 },
    },
    '/v1/status/cellular': {
      connected: true,
      uptime_seconds: 10,
      protocol: 'dhcp',
      ipv4_addresses: ['10.0.0.2'],
      ipv6_addresses: [],
    },
    '/v1/status/traffic': {
      day: trafficPeriod(),
      cycle: trafficPeriod(),
      since_power_on: trafficPeriod(),
      total: trafficPeriod(),
      reset_day: 1,
      reset_enabled: true,
    },
    '/v1/status/wifi': {
      enabled: true,
      bands: [
        {
          band: '2.4 GHz',
          enabled: true,
          ssid: 'Two',
          hidden: false,
          encryption: 'psk2',
          channel: 'auto',
          bandwidth: 'HE40',
          clients: 1,
        },
      ],
      current_client_link: {
        observation: 'router_observed',
        band: '5 GHz',
        signal_dbm: -51,
        tx_bitrate_mbps: 1200.9,
        rx_bitrate_mbps: 960.8,
        expected_throughput_mbps: 487.1,
        connected_seconds: 679,
      },
    },
    '/v1/lan/clients': {
      clients: [
        {
          hostname: 'phone',
          ipv4_address: '192.168.0.2',
          mac_address: '02:00:00:00:00:01',
          expires_seconds: 100,
        },
      ],
    },
    '/v1/sms': {
      page: 0,
      per_page: 100,
      omitted_messages: 0,
      messages: [
        {
          id: 1,
          sender: '+100',
          timestamp: 'now',
          content: 'hello',
          content_truncated: false,
          read: true,
        },
      ],
    },
  }
}

function trafficPeriod() {
  return { rx_bytes: 1, tx_bytes: 2, rx_packets: 3, tx_packets: 4, time_seconds: 5 }
}

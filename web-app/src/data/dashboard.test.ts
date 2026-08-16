import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./client')>()
  return { ...actual, getJson: vi.fn() }
})

import { AgentError, getJson } from './client'
import { loadDashboard } from './dashboard'

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
    },
    '/v1/status/battery': {
      state: 'charging',
      capacity_percent: 80,
      voltage_mv: 4000,
      current_ma: 100,
      temperature_c: 30,
    },
    '/v1/status/thermal': {
      sensors: [{ sensor: 'battery', temperature_c: 30 }],
    },
    '/v1/status/signal': {
      network_type: 'NR5G',
      provider: 'Example',
      bars: 4,
      roaming: false,
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

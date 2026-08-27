import './index.css'

import {
  pairBrowserCredential,
  hasDailyManagement,
  signInWithCredential,
  signInWithPassword,
  signOut,
  storedCredentials,
  supportsBrowserCredentials,
} from './auth/auth-service'
import type { BrowserCredential } from './auth/credential-store'
import { AgentError, getJson, hasSessionToken, postJson, putJson } from './data/client'
import { loadDashboard, type DashboardPanel, type DashboardSnapshot } from './data/dashboard'
import {
  clearPendingWifiConfirmation,
  loadPendingWifiConfirmation,
  savePendingWifiConfirmation,
} from './data/pending-wifi-store'
import type {
  V1BatteryStatus,
  V1ChargingStatus,
  V1CellularStatus,
  V1Device,
  V1LanClients,
  V1SignalStatus,
  V1SmsPage,
  V1SystemStatus,
  V1ThermalStatus,
  V1TrafficStatus,
  V1WifiStatus,
  V1WifiTransactionGrant,
} from './data/v1-contract'

const rootElement = document.querySelector<HTMLElement>('#root')
if (rootElement === null) {
  throw new Error('dashboard root is missing')
}
const root: HTMLElement = rootElement

void renderLogin()

async function renderLogin(notice?: string): Promise<void> {
  signOut()
  const skip = link('#main', 'Skip to sign in', 'skip-link')
  const main = element('main', 'auth-shell')
  main.id = 'main'
  const panel = element('section', 'auth-panel')
  panel.append(
    element('p', 'eyebrow', 'LOCAL · OWNER OPERATED'),
    element('h1', '', 'U60 B04 Dashboard'),
    element(
      'p',
      'lede',
      'Sign in over this secure origin. Session tokens stay only in this page’s memory.',
    ),
  )
  const message = element('p', 'notice')
  message.setAttribute('role', 'status')
  message.setAttribute('aria-live', 'polite')
  if (notice !== undefined) message.textContent = notice
  const error = element('p', 'error')
  error.setAttribute('role', 'alert')
  panel.append(message, error)
  root.replaceChildren(skip, main)
  main.append(panel)

  let credentials: BrowserCredential[] = []
  if (supportsBrowserCredentials()) {
    try {
      credentials = await storedCredentials()
    } catch {
      setError(error, 'Stored browser keys are unavailable. Password sign-in remains available.')
    }
  }
  if (credentials.length > 0) {
    panel.append(browserKeyForm(credentials, message, error))
  } else {
    panel.append(
      element(
        'p',
        'empty-state',
        supportsBrowserCredentials()
          ? 'No browser key is paired yet.'
          : 'This browser cannot keep a non-exportable local key.',
      ),
    )
  }
  panel.append(passwordForm(message, error))
  if (supportsBrowserCredentials()) {
    panel.append(pairingDisclosure(message, error))
  }
}

function browserKeyForm(
  credentials: BrowserCredential[],
  message: HTMLElement,
  error: HTMLElement,
): HTMLFormElement {
  const form = element('form', 'auth-form')
  const heading = element('h2', '', 'Paired browser key')
  const label = element('label', '', 'Browser key')
  label.htmlFor = 'credential'
  const select = element('select', '')
  select.id = 'credential'
  for (const credential of credentials) {
    const option = element('option', '', credential.label)
    option.value = credential.id
    select.append(option)
  }
  const submit = button('Sign in with browser key', 'primary')
  form.append(heading, label, select, submit)
  let busy = false
  form.addEventListener('submit', (event) => {
    event.preventDefault()
    if (busy) return
    const credential = credentials.find((item) => item.id === select.value)
    if (credential === undefined) {
      setError(error, 'Select a valid stored browser key.')
      return
    }
    busy = true
    setBusy(form, submit, true, 'Signing…')
    clearMessages(message, error)
    void signInWithCredential(credential)
      .then(() => renderDashboard())
      .catch((reason: unknown) => setError(error, errorMessage(reason)))
      .finally(() => {
        busy = false
        setBusy(form, submit, false, 'Sign in with browser key')
      })
  })
  return form
}

function passwordForm(message: HTMLElement, error: HTMLElement): HTMLFormElement {
  const form = element('form', 'auth-form')
  const heading = element('h2', '', 'Password recovery sign-in')
  const hint = element(
    'p',
    'hint',
    'Enter the separate management password. The dashboard does not persist it; browser password-manager behavior is controlled separately.',
  )
  hint.id = 'password-hint'
  const label = element('label', '', 'Management password')
  label.htmlFor = 'management-password'
  const password = element('input', '')
  password.id = 'management-password'
  password.type = 'password'
  password.required = true
  password.autocomplete = 'off'
  password.setAttribute('aria-describedby', hint.id)
  const submit = button('Sign in with password', 'secondary')
  form.append(heading, hint, label, password, submit)
  let busy = false
  form.addEventListener('submit', (event) => {
    event.preventDefault()
    if (busy) return
    busy = true
    const submittedPassword = password.value
    password.value = ''
    setBusy(form, submit, true, 'Signing…')
    clearMessages(message, error)
    void signInWithPassword(submittedPassword)
      .then(() => renderDashboard())
      .catch((reason: unknown) => setError(error, errorMessage(reason)))
      .finally(() => {
        busy = false
        setBusy(form, submit, false, 'Sign in with password')
      })
  })
  return form
}

function pairingDisclosure(message: HTMLElement, error: HTMLElement): HTMLDetailsElement {
  const details = element('details', 'pairing')
  details.append(element('summary', '', 'Pair this browser'))
  const intro = element(
    'p',
    'hint',
    'Open a five-minute window with the maintenance CLI, then paste its one-time nonce.',
  )
  intro.id = 'pairing-hint'
  const form = element('form', 'auth-form compact')
  const nonceLabel = element('label', '', 'One-time pairing nonce')
  nonceLabel.htmlFor = 'pairing-nonce'
  const nonce = element('input', '')
  nonce.id = 'pairing-nonce'
  nonce.type = 'password'
  nonce.required = true
  nonce.autocomplete = 'off'
  nonce.spellcheck = false
  nonce.setAttribute('aria-describedby', intro.id)
  const keyLabel = element('label', '', 'Browser key label')
  keyLabel.htmlFor = 'browser-key-label'
  const label = element('input', '')
  label.id = 'browser-key-label'
  label.type = 'text'
  label.required = true
  label.maxLength = 64
  label.autocomplete = 'off'
  label.value = 'Browser dashboard'
  const submit = button('Create browser key', 'secondary')
  form.append(nonceLabel, nonce, keyLabel, label, submit)
  details.append(intro, form)
  let busy = false
  form.addEventListener('submit', (event) => {
    event.preventDefault()
    if (busy) return
    busy = true
    const submittedNonce = nonce.value.trim()
    nonce.value = ''
    setBusy(form, submit, true, 'Pairing…')
    clearMessages(message, error)
    void pairBrowserCredential(submittedNonce, label.value)
      .then(() => renderLogin('Browser key paired. Sign in with it to continue.'))
      .catch((reason: unknown) => setError(error, errorMessage(reason)))
      .finally(() => {
        busy = false
        setBusy(form, submit, false, 'Create browser key')
      })
  })
  return details
}

async function renderDashboard(): Promise<void> {
  if (!hasSessionToken()) {
    await renderLogin('Your session ended. Sign in again.')
    return
  }
  const skip = link('#main', 'Skip to status', 'skip-link')
  const header = element('header', 'topbar')
  const titleGroup = element('div', '')
  titleGroup.append(element('p', 'eyebrow', 'MU5250 · HK B04'), element('h1', '', 'Local control'))
  const actions = element('div', 'actions')
  const refresh = button('Refresh', 'secondary')
  refresh.type = 'button'
  const logout = button('Sign out', 'quiet')
  logout.type = 'button'
  actions.append(refresh, logout)
  header.append(titleGroup, actions)
  const main = element('main', 'dashboard')
  main.id = 'main'
  const live = element('p', 'notice', 'Loading capability report…')
  live.setAttribute('role', 'status')
  live.setAttribute('aria-live', 'polite')
  const grid = element('div', 'card-grid')
  main.append(live, grid)
  if (hasDailyManagement()) {
    main.append(dailyManagement())
  }
  root.replaceChildren(skip, header, main)

  logout.addEventListener('click', () => void renderLogin('Signed out.'))
  let busy = false
  const reload = async () => {
    if (busy) return
    busy = true
    setBusy(main, refresh, true, 'Refreshing…')
    live.textContent = 'Loading capability report…'
    grid.replaceChildren()
    try {
      const snapshot = await loadDashboard()
      renderSnapshot(snapshot, grid)
      live.textContent = `Adapter ${snapshot.report.adapter} · target ${snapshot.report.firmware_target}`
    } catch (reason) {
      if (!hasSessionToken()) {
        await renderLogin('Your session ended. Sign in again.')
        return
      }
      live.textContent = errorMessage(reason)
    } finally {
      busy = false
      setBusy(main, refresh, false, 'Refresh')
    }
  }
  refresh.addEventListener('click', () => void reload())
  await reload()
}

function dailyManagement(): HTMLElement {
  const section = element('section', 'management')
  section.append(
    element('p', 'eyebrow', 'DAILY SCOPE'),
    element('h2', '', 'Owner controls'),
    element(
      'p',
      'hint',
      'Only fixed, validated B04 operations are available. Wi-Fi changes roll back unless confirmed within two minutes.',
    ),
  )
  const status = element('p', 'notice')
  status.setAttribute('role', 'status')
  status.setAttribute('aria-live', 'polite')
  const error = element('p', 'error')
  error.setAttribute('role', 'alert')
  const grid = element('div', 'management-grid')
  grid.append(
    smsForm(status, error),
    chargingForm(status, error),
    trafficCycleForm(status, error),
    wifiTransactionForm(status, error),
  )
  section.append(status, error, grid)
  return section
}

function smsForm(status: HTMLElement, error: HTMLElement): HTMLFormElement {
  const form = controlForm('Send SMS')
  const recipient = textInput('SMS recipient', 'sms-recipient')
  recipient.inputMode = 'tel'
  recipient.maxLength = 32
  const message = element('textarea', '')
  message.id = 'sms-message'
  message.required = true
  message.maxLength = 160
  const messageLabel = element('label', '', 'Message')
  messageLabel.htmlFor = message.id
  const submit = button('Send', 'secondary')
  form.append(recipientLabel(recipient, 'Recipient'), recipient, messageLabel, message, submit)
  bindForm(form, submit, status, error, 'Sending…', 'Send', async () => {
    await postJson('/v1/sms/send', { recipient: recipient.value.trim(), message: message.value })
    message.value = ''
    return 'SMS accepted by the modem.'
  })
  return form
}

function chargingForm(_status: HTMLElement, error: HTMLElement): HTMLFormElement {
  const form = controlForm('Charging status')
  const current = element('p', 'hint', 'Loading charging status…')
  form.append(current)
  const updateCurrent = (value: V1ChargingStatus) => {
    current.textContent = `${value.capacity_percent}% · ${value.paused ? 'charging stopped' : 'charging allowed'}`
  }
  void getJson('/v1/charging')
    .then((value) => updateCurrent(value as V1ChargingStatus))
    .catch((reason: unknown) => setError(error, errorMessage(reason)))
  return form
}

function trafficCycleForm(status: HTMLElement, error: HTMLElement): HTMLFormElement {
  const form = controlForm('Traffic cycle')
  const day = element('input', '')
  day.id = 'traffic-reset-day'
  day.type = 'number'
  day.min = '1'
  day.max = '31'
  day.value = '1'
  const enabled = element('input', '')
  enabled.id = 'traffic-cycle-enabled'
  enabled.type = 'checkbox'
  enabled.checked = true
  const enabledLabel = recipientLabel(enabled, 'Enable monthly reset')
  const submit = button('Apply cycle', 'secondary')
  form.append(recipientLabel(day, 'Reset day'), day, enabledLabel, enabled, submit)
  bindForm(form, submit, status, error, 'Applying…', 'Apply cycle', async () => {
    await putJson('/v1/traffic/cycle', {
      reset_day: Number(day.value),
      enabled: enabled.checked,
    })
    return 'Traffic cycle applied and verified.'
  })
  return form
}

function wifiTransactionForm(status: HTMLElement, error: HTMLElement): HTMLFormElement {
  const form = controlForm('Wi-Fi transaction')
  const ssid2g = textInput('2.4 GHz SSID', 'wifi-ssid-2g')
  const pass2g = passwordInput('2.4 GHz passphrase', 'wifi-pass-2g')
  const ssid5g = textInput('5 GHz SSID', 'wifi-ssid-5g')
  const pass5g = passwordInput('5 GHz passphrase', 'wifi-pass-5g')
  const submit = button('Apply for 2 minutes', 'secondary')
  const confirm = button('Confirm current Wi-Fi', 'primary')
  confirm.type = 'button'
  confirm.disabled = true
  let pendingId: string | undefined
  form.append(
    recipientLabel(ssid2g, '2.4 GHz SSID (optional)'),
    ssid2g,
    recipientLabel(pass2g, '2.4 GHz passphrase (optional)'),
    pass2g,
    recipientLabel(ssid5g, '5 GHz SSID (optional)'),
    ssid5g,
    recipientLabel(pass5g, '5 GHz passphrase (optional)'),
    pass5g,
    submit,
    confirm,
  )
  void loadPendingWifiConfirmation()
    .then((restoredPending) => {
      pendingId = restoredPending?.transactionId
      confirm.disabled = restoredPending === undefined
    })
    .catch((reason: unknown) => {
      setError(error, `Wi-Fi recovery metadata is unavailable: ${errorMessage(reason)}`)
    })
  bindForm(form, submit, status, error, 'Applying…', 'Apply for 2 minutes', async () => {
    const transactionId = makeWifiTransactionId()
    const pending = {
      transactionId,
      expiresAt: Date.now() + 120_000,
    }
    await savePendingWifiConfirmation(pending)
    pendingId = transactionId
    confirm.disabled = false
    const body: Record<string, string> = { transaction_id: transactionId }
    if (ssid2g.value !== '') body.ssid_2g = ssid2g.value
    if (pass2g.value !== '') body.passphrase_2g = pass2g.value
    if (ssid5g.value !== '') body.ssid_5g = ssid5g.value
    if (pass5g.value !== '') body.passphrase_5g = pass5g.value
    let grant: V1WifiTransactionGrant
    try {
      grant = (await postJson('/v1/wifi/transaction', body)) as V1WifiTransactionGrant
    } catch (reason: unknown) {
      if (reason instanceof AgentError && reason.status === 400) {
        await clearPendingWifiConfirmation()
        pendingId = undefined
        confirm.disabled = true
      }
      throw reason
    }
    if (grant.transaction_id !== transactionId) {
      throw new AgentError('The U60 returned a mismatched Wi-Fi transaction identifier')
    }
    pass2g.value = ''
    pass5g.value = ''
    confirm.disabled = false
    return `Wi-Fi pending. Reconnect if needed and confirm within ${grant.confirm_within_seconds} seconds.`
  })
  confirm.addEventListener('click', () => {
    if (pendingId === undefined) return
    clearMessages(status, error)
    confirm.disabled = true
    void postJson('/v1/wifi/transaction/confirm', { transaction_id: pendingId })
      .then(async () => {
        pendingId = undefined
        await clearPendingWifiConfirmation()
        status.textContent =
          'Reconnected to the U60. The new Wi-Fi settings were verified and automatic rollback was cancelled.'
      })
      .catch((reason: unknown) => {
        confirm.disabled = false
        setError(error, errorMessage(reason))
      })
  })
  return form
}

function makeWifiTransactionId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18))
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}

function controlForm(title: string): HTMLFormElement {
  const form = element('form', 'control-card')
  form.append(element('h3', '', title))
  return form
}

function textInput(_name: string, id: string): HTMLInputElement {
  const input = element('input', '')
  input.id = id
  input.type = 'text'
  input.autocomplete = 'off'
  return input
}

function passwordInput(_name: string, id: string): HTMLInputElement {
  const input = textInput('', id)
  input.type = 'password'
  input.autocomplete = 'new-password'
  return input
}

function recipientLabel(input: HTMLInputElement, text: string): HTMLLabelElement {
  const label = element('label', '', text)
  label.htmlFor = input.id
  return label
}

function bindForm(
  form: HTMLFormElement,
  submit: HTMLButtonElement,
  status: HTMLElement,
  error: HTMLElement,
  busyLabel: string,
  idleLabel: string,
  operation: () => Promise<string>,
): void {
  let busy = false
  form.addEventListener('submit', (event) => {
    event.preventDefault()
    if (busy) return
    busy = true
    clearMessages(status, error)
    setBusy(form, submit, true, busyLabel)
    void operation()
      .then((message) => {
        status.textContent = message
      })
      .catch((reason: unknown) => setError(error, errorMessage(reason)))
      .finally(() => {
        busy = false
        setBusy(form, submit, false, idleLabel)
      })
  })
}

function renderSnapshot(snapshot: DashboardSnapshot, grid: HTMLElement): void {
  grid.replaceChildren(...snapshot.panels.map(renderPanel))
}

function renderPanel(panel: DashboardPanel): HTMLElement {
  const card = element('section', 'card')
  const header = element('div', 'card-header')
  header.append(
    element('h2', '', capabilityTitle(panel.capability.id)),
    element('span', `badge ${panel.capability.status}`, panel.capability.status),
  )
  card.append(header)
  if (panel.capability.reason !== undefined) {
    card.append(element('p', 'reason', panel.capability.reason))
  }
  if (panel.capability.recovery.required) {
    card.append(
      element(
        'p',
        'recovery',
        panel.capability.recovery.action ?? 'Maintenance action is required.',
      ),
    )
  }
  if (panel.error !== undefined) {
    card.append(element('p', 'error', panel.error))
    return card
  }
  if (panel.value === undefined) {
    card.append(element('p', 'empty-state', 'This capability is not available on the current runtime.'))
    return card
  }

  switch (panel.capability.id) {
    case 'device_identity':
      appendDevice(card, panel.value as V1Device)
      break
    case 'system_status':
      appendSystem(card, panel.value as V1SystemStatus)
      break
    case 'battery_status':
      appendBattery(card, panel.value as V1BatteryStatus)
      break
    case 'thermal_status':
      appendThermal(card, panel.value as V1ThermalStatus)
      break
    case 'signal_status':
      appendSignal(card, panel.value as V1SignalStatus)
      break
    case 'cellular_status':
      appendCellular(card, panel.value as V1CellularStatus)
      break
    case 'traffic_status':
      appendTraffic(card, panel.value as V1TrafficStatus)
      break
    case 'wifi_status':
      appendWifi(card, panel.value as V1WifiStatus)
      break
    case 'lan_clients':
      appendLanClients(card, panel.value as V1LanClients)
      break
    case 'sms_list':
      appendSms(card, panel.value as V1SmsPage)
      break
  }
  return card
}

function appendDevice(card: HTMLElement, value: V1Device): void {
  appendDefinitionList(card, [
    ['Model', `${value.manufacturer} ${value.model}`],
    ['Firmware target', value.firmware_target],
    ['Firmware', value.firmware_version ?? 'Not reported'],
    ['Hardware', value.hardware_version ?? 'Not reported'],
  ])
}

function appendSystem(card: HTMLElement, value: V1SystemStatus): void {
  appendDefinitionList(card, [
    ['Hostname', value.hostname],
    ['Kernel', value.kernel],
    ['Uptime', formatDuration(value.uptime_seconds)],
    ['Load average', value.load_average.map((item) => item.toFixed(2)).join(' · ')],
  ])
}

function appendBattery(card: HTMLElement, value: V1BatteryStatus): void {
  appendDefinitionList(card, [
    ['State', value.state],
    ['Capacity', `${value.capacity_percent}%`],
    ['Voltage', `${value.voltage_mv} mV`],
    ['Current', `${value.current_ma} mA`],
    ['Power', `${(Math.abs(value.power_mw) / 1000).toFixed(2)} W`],
    ['Temperature', `${value.temperature_c.toFixed(1)} °C`],
  ])
}

function appendThermal(card: HTMLElement, value: V1ThermalStatus): void {
  if (value.sensors.length === 0) {
    card.append(element('p', 'empty-state', 'No validated thermal sensors were reported.'))
    return
  }
  appendDefinitionList(
    card,
    value.sensors.map((sensor) => [sensor.sensor, `${sensor.temperature_c.toFixed(1)} °C`]),
  )
}

function appendSignal(card: HTMLElement, value: V1SignalStatus): void {
  const metrics: [string, string][] = [
    ['Network', value.network_type],
    ['Provider', value.provider ?? 'Not reported'],
    ['Strength', `${value.bars} / 5`],
    ['Roaming', value.roaming ? 'Yes' : 'No'],
    ['Active band', value.active_band ?? 'Not reported'],
  ]
  if (value.network_selection_mode !== undefined) {
    metrics.push(['Network selection', value.network_selection_mode])
  }
  if (value.lte_carrier_aggregation !== undefined) {
    metrics.push(['LTE aggregation', aggregationText(value.lte_carrier_aggregation)])
  }
  if (value.nr5g_carrier_aggregation !== undefined) {
    metrics.push(['5G aggregation', aggregationText(value.nr5g_carrier_aggregation)])
  }
  if (value.cell_lock !== undefined) {
    metrics.push(['LTE cell lock', value.cell_lock.lte ? 'Configured' : 'Off'])
    metrics.push(['5G cell lock', value.cell_lock.nr5g ? 'Configured' : 'Off'])
  }
  if (value.lte !== undefined) {
    metrics.push(
      ['LTE band', value.lte.band ?? 'Not reported'],
      ['LTE RSRP', formatOptionalUnit(value.lte.rsrp_dbm, 'dBm')],
      ['LTE RSRQ', formatOptionalUnit(value.lte.rsrq_db, 'dB')],
      ['LTE SNR', formatOptionalUnit(value.lte.snr_db, 'dB')],
    )
  }
  if (value.nr5g !== undefined) {
    metrics.push(
      ['5G band', value.nr5g.band ?? 'Not reported'],
      ['5G channel', value.nr5g.channel?.toString() ?? 'Not reported'],
      ['5G PCI', value.nr5g.pci?.toString() ?? 'Not reported'],
      ['5G RSRP', formatOptionalUnit(value.nr5g.rsrp_dbm, 'dBm')],
      ['5G RSRQ', formatOptionalUnit(value.nr5g.rsrq_db, 'dB')],
      ['5G SNR', formatOptionalUnit(value.nr5g.snr_db, 'dB')],
    )
  }
  appendDefinitionList(card, metrics)
}

function aggregationText(
  value: NonNullable<V1SignalStatus['lte_carrier_aggregation']>,
): string {
  if (!value.active) return 'Not aggregated'
  return value.bands.length > 0 ? value.bands.join(' + ') : 'Active'
}

function appendCellular(card: HTMLElement, value: V1CellularStatus): void {
  appendDefinitionList(card, [
    ['State', value.connected ? 'Connected' : 'Disconnected'],
    ['Protocol', value.protocol],
    ['Interface', value.interface ?? 'Not reported'],
    ['Uptime', formatDuration(value.uptime_seconds)],
    ['IPv4', value.ipv4_addresses.join(', ') || 'None'],
    ['IPv6', value.ipv6_addresses.join(', ') || 'None'],
  ])
}

function appendTraffic(card: HTMLElement, value: V1TrafficStatus): void {
  appendDefinitionList(card, [
    ['Today', formatTraffic(value.day.rx_bytes, value.day.tx_bytes)],
    ['Billing cycle', formatTraffic(value.cycle.rx_bytes, value.cycle.tx_bytes)],
    ['Since power-on', formatTraffic(value.since_power_on.rx_bytes, value.since_power_on.tx_bytes)],
    ['All time', formatTraffic(value.total.rx_bytes, value.total.tx_bytes)],
    ['Cycle reset', value.reset_enabled ? `Day ${value.reset_day}` : 'Disabled'],
  ])
}

function appendWifi(card: HTMLElement, value: V1WifiStatus): void {
  const metrics: [string, string][] = [['Overall', value.enabled ? 'Enabled' : 'Disabled']]
  for (const band of value.bands) {
    metrics.push(
      [`${band.band} network`, band.enabled ? band.ssid : 'Disabled'],
      [`${band.band} radio`, `${band.channel} · ${band.bandwidth}`],
      [`${band.band} security`, `${band.encryption}${band.hidden ? ' · hidden' : ''}`],
      [`${band.band} clients`, band.clients?.toString() ?? 'Not reported'],
    )
  }
  if (value.current_client_link !== undefined) {
    const link = value.current_client_link
    metrics.push(
      ['Observation', 'Router-observed for this browser'],
      ['Client band', link.band],
      ['Client signal', `${link.signal_dbm} dBm`],
      ['Client TX rate', `${link.tx_bitrate_mbps.toFixed(1)} Mbps`],
      ['Client RX rate', `${link.rx_bitrate_mbps.toFixed(1)} Mbps`],
      ['Client expected throughput', link.expected_throughput_mbps === undefined ? 'Not reported' : `${link.expected_throughput_mbps.toFixed(1)} Mbps`],
      ['Client connected', formatDuration(link.connected_seconds)],
    )
  }
  appendDefinitionList(card, metrics)
}

function appendLanClients(card: HTMLElement, value: V1LanClients): void {
  if (value.clients.length === 0) {
    card.append(element('p', 'empty-state', 'No current DHCP clients.'))
    return
  }
  appendDefinitionList(
    card,
    value.clients.map((client) => [
      client.hostname || client.mac_address,
      `${client.ipv4_address} · ${client.mac_address}`,
    ]),
  )
}

function appendSms(card: HTMLElement, value: V1SmsPage): void {
  if (value.messages.length === 0) {
    card.append(element('p', 'empty-state', 'No SMS messages.'))
    return
  }
  appendDefinitionList(
    card,
    value.messages
      .slice(0, 20)
      .map((message) => [
        `${message.read ? '' : 'Unread · '}${message.sender}`,
        `${message.timestamp} · ${message.content}${message.content_truncated ? ' … [truncated]' : ''}`,
      ]),
  )
  if (value.messages.length > 20) {
    card.append(element('p', 'hint', `Showing 20 of ${value.messages.length} recent messages.`))
  }
  if (value.omitted_messages > 0) {
    card.append(
      element(
        'p',
        'hint',
        `${value.omitted_messages} malformed message entr${value.omitted_messages === 1 ? 'y was' : 'ies were'} omitted.`,
      ),
    )
  }
}

function appendDefinitionList(card: HTMLElement, values: readonly (readonly [string, string])[]): void {
  const list = element('dl', 'metrics')
  for (const [term, description] of values) {
    list.append(element('dt', '', term), element('dd', '', description))
  }
  card.append(list)
}

function capabilityTitle(id: DashboardPanel['capability']['id']): string {
  return {
    device_identity: 'Device',
    system_status: 'System',
    battery_status: 'Battery',
    thermal_status: 'Thermal',
    signal_status: 'Signal',
    cellular_status: 'Cellular',
    traffic_status: 'Traffic',
    wifi_status: 'Wi-Fi',
    lan_clients: 'LAN clients',
    sms_list: 'Messages',
  }[id]
}

function formatOptionalUnit(value: number | undefined, unit: string): string {
  return value === undefined ? 'Not reported' : `${value} ${unit}`
}

function formatTraffic(received: number, transmitted: number): string {
  return `↓ ${formatBytes(received)} · ↑ ${formatBytes(transmitted)}`
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`
  const units = ['KiB', 'MiB', 'GiB', 'TiB']
  let amount = value / 1024
  let index = 0
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024
    index += 1
  }
  return `${amount.toFixed(amount >= 10 ? 1 : 2)} ${units[index]}`
}

function formatDuration(seconds: number): string {
  const days = Math.floor(seconds / 86_400)
  const hours = Math.floor((seconds % 86_400) / 3_600)
  const minutes = Math.floor((seconds % 3_600) / 60)
  return days > 0 ? `${days}d ${hours}h` : `${hours}h ${minutes}m`
}

function setBusy(container: HTMLElement, action: HTMLButtonElement, busy: boolean, label: string): void {
  container.setAttribute('aria-busy', String(busy))
  action.textContent = label
}

function clearMessages(message: HTMLElement, error: HTMLElement): void {
  message.textContent = ''
  error.textContent = ''
}

function setError(target: HTMLElement, message: string): void {
  target.textContent = message
}

function errorMessage(reason: unknown): string {
  if (reason instanceof AgentError && reason.retryAfterSeconds !== undefined) {
    return `${reason.message} Try again in ${reason.retryAfterSeconds} seconds.`
  }
  return reason instanceof Error ? reason.message : 'The operation could not be completed.'
}

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className = '',
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

function button(label: string, style: string): HTMLButtonElement {
  const action = element('button', `button ${style}`, label)
  action.type = 'submit'
  return action
}

function link(href: string, label: string, className: string): HTMLAnchorElement {
  const anchor = element('a', className, label)
  anchor.href = href
  return anchor
}

import Foundation

struct DashboardSnapshot: Sendable {
    let report: Components.Schemas.CapabilityReport
    let device: Components.Schemas.Device?
    let system: Components.Schemas.SystemStatus?
    let battery: Components.Schemas.BatteryStatus?
    let thermal: Components.Schemas.ThermalStatus?
    let signal: Components.Schemas.SignalStatus?
    let cellular: Components.Schemas.CellularStatus?
    let traffic: Components.Schemas.TrafficStatus?
    let wifi: Components.Schemas.WifiStatus?
    let lanClients: Components.Schemas.LanClients?
    let sms: Components.Schemas.SmsPage?
    let failures: [String: String]
}

func batteryCapacityHealthPercent(
    learnedFullCapacityMah: Int?,
    designCapacityMah: Int?
) -> Double? {
    guard
        let learnedFullCapacityMah,
        let designCapacityMah,
        learnedFullCapacityMah > 0,
        designCapacityMah > 0
    else {
        return nil
    }

    let percent = Double(learnedFullCapacityMah) / Double(designCapacityMah) * 100
    return percent.isFinite ? percent : nil
}

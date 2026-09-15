import Foundation

/// 已同步健康运动的聚合值，不携带逐条记录或设备标识。
struct HealthActivityDigest: Codable, Equatable {
    var workoutCount = 0
    var totalMinutes: Double = 0
    var distanceKm: Double = 0
    var distanceRecords = 0
    var energyAverageKcal: Double = 0
    var energyDays = 0

    var hasData: Bool { workoutCount > 0 || energyDays > 0 }

    var summaryText: String {
        var parts: [String] = []
        if workoutCount > 0 {
            var line = "Apple 健康运动：已同步 \(workoutCount) 次，累计 \(Int(totalMinutes.rounded())) 分钟"
            if distanceRecords > 0 {
                line += "；\(distanceRecords) 次有距离，合计 \(String(format: "%.1f", distanceKm))km"
            }
            parts.append(line)
        }
        if energyDays > 0 {
            parts.append("活动能量：\(energyDays) 天有值，日均 \(Int(energyAverageKcal.rounded()))kcal；不含静息消耗，不等于总消耗或单次训练消耗")
        }
        return parts.joined(separator: "\n")
    }
}

import HealthKit

enum Health {
    private static let store = HKHealthStore()

    static func save(sys: Int, dia: Int, pulse: Int?, at date: Date = .now) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HKError(.errorHealthDataUnavailable) }
        let sysType = HKQuantityType(.bloodPressureSystolic)
        let diaType = HKQuantityType(.bloodPressureDiastolic)
        let hrType = HKQuantityType(.heartRate)
        try await store.requestAuthorization(toShare: [sysType, diaType, hrType], read: [])

        let mmHg = HKUnit.millimeterOfMercury()
        let bp = HKCorrelation(
            type: HKCorrelationType(.bloodPressure), start: date, end: date,
            objects: [
                HKQuantitySample(type: sysType, quantity: HKQuantity(unit: mmHg, doubleValue: Double(sys)), start: date, end: date),
                HKQuantitySample(type: diaType, quantity: HKQuantity(unit: mmHg, doubleValue: Double(dia)), start: date, end: date),
            ])
        var samples: [HKSample] = [bp]
        if let pulse {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            samples.append(HKQuantitySample(type: hrType, quantity: HKQuantity(unit: bpm, doubleValue: Double(pulse)), start: date, end: date))
        }
        try await store.save(samples)
    }
}

import HealthKit

/// One blood pressure correlation from Health.
struct BPSample: Identifiable {
    let id: UUID
    let date: Date
    let sys: Int
    let dia: Int
}

enum Health {
    private static let store = HKHealthStore()
    private static let sysType = HKQuantityType(.bloodPressureSystolic)
    private static let diaType = HKQuantityType(.bloodPressureDiastolic)
    private static let hrType = HKQuantityType(.heartRate)
    private static let mmHg = HKUnit.millimeterOfMercury()

    private static func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HKError(.errorHealthDataUnavailable) }
        try await store.requestAuthorization(toShare: [sysType, diaType, hrType], read: [sysType, diaType])
    }

    static func save(sys: Int, dia: Int, pulse: Int?, at date: Date = .now) async throws {
        try await authorize()
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

    /// The most recent readings from any source, oldest first. Empty if read access was denied.
    static func recent(limit: Int = 60) async throws -> [BPSample] {
        try await authorize()
        let query = HKSampleQueryDescriptor(
            predicates: [.correlation(type: HKCorrelationType(.bloodPressure))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: limit)
        let samples: [BPSample] = try await query.result(for: store).compactMap { bp in
            guard let sys = bp.objects(for: sysType).first as? HKQuantitySample,
                  let dia = bp.objects(for: diaType).first as? HKQuantitySample else { return nil }
            return BPSample(id: bp.uuid, date: bp.startDate,
                            sys: Int(sys.quantity.doubleValue(for: mmHg).rounded()),
                            dia: Int(dia.quantity.doubleValue(for: mmHg).rounded()))
        }
        return samples.reversed()
    }
}

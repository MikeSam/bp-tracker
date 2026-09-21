import HealthKit

/// One blood pressure correlation from Health, with the pulse recorded alongside it if any.
struct BPSample: Identifiable {
    let id: UUID
    let date: Date
    let sys: Int
    let dia: Int
    var pulse: Int?
}

enum Health {
    private static let store = HKHealthStore()
    private static let sysType = HKQuantityType(.bloodPressureSystolic)
    private static let diaType = HKQuantityType(.bloodPressureDiastolic)
    private static let hrType = HKQuantityType(.heartRate)
    private static let mmHg = HKUnit.millimeterOfMercury()
    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    private static func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HKError(.errorHealthDataUnavailable) }
        try await store.requestAuthorization(toShare: [sysType, diaType, hrType], read: [sysType, diaType, hrType])
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
            samples.append(HKQuantitySample(type: hrType, quantity: HKQuantity(unit: bpm, doubleValue: Double(pulse)), start: date, end: date))
        }
        try await store.save(samples)
    }

    /// Every blood pressure reading from any source, oldest first, re-emitted whenever Health changes.
    /// Pulse is the heart rate this app saved within a minute of the reading.
    // ponytail: only our own heart-rate samples are matched; a Watch writes thousands a day and would swamp the stream
    static func readings() -> AsyncThrowingStream<[BPSample], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                try await authorize()
                let merged = Merged()
                // HealthKit doesn't deliver live updates for correlation types, so watch the systolic samples
                // (one per reading) and re-read all correlations whenever they change.
                let sysQuery = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: sysType)], anchor: nil)
                let bpQuery = HKSampleQueryDescriptor(predicates: [.correlation(type: HKCorrelationType(.bloodPressure))], sortDescriptors: [])
                let hrQuery = HKAnchoredObjectQueryDescriptor(
                    predicates: [.quantitySample(type: hrType, predicate: HKQuery.predicateForObjects(from: .default()))], anchor: nil)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        for try await _ in sysQuery.results(for: store) {
                            merged.bps = try await bpQuery.result(for: store).compactMap { BPSample($0) }
                            continuation.yield(merged.readings)
                        }
                    }
                    group.addTask { @MainActor in
                        for try await update in hrQuery.results(for: store) {
                            for deleted in update.deletedObjects { merged.pulses[deleted.uuid] = nil }
                            for hr in update.addedSamples { merged.pulses[hr.uuid] = (hr.startDate, Int(hr.quantity.doubleValue(for: bpm).rounded())) }
                            continuation.yield(merged.readings)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor private final class Merged {
        var bps: [BPSample] = []
        var pulses: [UUID: (date: Date, bpm: Int)] = [:]

        var readings: [BPSample] {
            bps.map { bp in
                var sample = bp
                let nearest = pulses.values.min { abs($0.date.timeIntervalSince(bp.date)) < abs($1.date.timeIntervalSince(bp.date)) }
                if let nearest, abs(nearest.date.timeIntervalSince(bp.date)) <= 60 { sample.pulse = nearest.bpm }
                return sample
            }
            .sorted { $0.date < $1.date }
        }
    }
}

private extension BPSample {
    init?(_ bp: HKCorrelation) {
        let mmHg = HKUnit.millimeterOfMercury()
        guard let sys = bp.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample,
              let dia = bp.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample else { return nil }
        self.init(id: bp.uuid, date: bp.startDate,
                  sys: Int(sys.quantity.doubleValue(for: mmHg).rounded()),
                  dia: Int(dia.quantity.doubleValue(for: mmHg).rounded()))
    }
}

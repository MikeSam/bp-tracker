import HealthKit

/// One blood pressure correlation from Health, with the pulse recorded alongside it if any.
struct BPSample: Identifiable {
    let id: UUID              // the correlation's UUID
    let date: Date
    let sys: Int
    let dia: Int
    var pulse: Int?
    /// The heart-rate sample known to belong to this reading (saved with it by this app), if any.
    /// Only this one is edited or deleted with the reading; `pulse` alone may come from a nearby sample.
    var pulseID: UUID?
    /// Saved by this app. HealthKit only lets an app delete what it saved itself.
    var isOwn = false
    var sourceName = ""
    var readingID: String?    // links the correlation and its heart rate; missing on readings saved before IDs were added
}

enum HealthError: LocalizedError {
    case gone, notOurs, changed, oldNotRemoved

    var errorDescription: String? {
        switch self {
        case .gone: String(localized: "This reading is no longer in Health.")
        case .notOurs: String(localized: "This reading was added by another app. BP Tracker can't change it.")
        case .changed: String(localized: "This reading changed in Health. Open it again.")
        case .oldNotRemoved: String(localized: "Saved the new reading, but couldn't remove the old one. Delete it in History.")
        }
    }
}

enum Health {
    private static let store = HKHealthStore()
    private static let sysType = HKQuantityType(.bloodPressureSystolic)
    private static let diaType = HKQuantityType(.bloodPressureDiastolic)
    private static let hrType = HKQuantityType(.heartRate)
    private static let bpType = HKCorrelationType(.bloodPressure)
    private static let mmHg = HKUnit.millimeterOfMercury()
    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    /// Metadata stamped on a reading's correlation and its heart-rate sample, so the pair can be found again.
    static let readingIDKey = "BPTrackerReadingID"

    private static func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HKError(.errorHealthDataUnavailable) }
        try await store.requestAuthorization(toShare: [sysType, diaType, hrType], read: [sysType, diaType, hrType])
    }

    static func save(sys: Int, dia: Int, pulse: Int?, at date: Date = .now) async throws {
        guard Limits.allows(sys: sys, dia: dia, pulse: pulse) else { throw HKError(.errorInvalidArgument) }   // the form checks first; never write a typo to Health
        try await authorize()
        let metadata = [readingIDKey: UUID().uuidString]
        let bp = HKCorrelation(
            type: bpType, start: date, end: date,
            objects: [
                HKQuantitySample(type: sysType, quantity: HKQuantity(unit: mmHg, doubleValue: Double(sys)), start: date, end: date),
                HKQuantitySample(type: diaType, quantity: HKQuantity(unit: mmHg, doubleValue: Double(dia)), start: date, end: date),
            ],
            metadata: metadata)
        var samples: [HKSample] = [bp]
        if let pulse {
            samples.append(HKQuantitySample(type: hrType, quantity: HKQuantity(unit: bpm, doubleValue: Double(pulse)), start: date, end: date, metadata: metadata))
        }
        try await store.save(samples)   // all or nothing
    }

    /// Edits a reading. Health has no update, so the new reading is saved first and the old one deleted after:
    /// if the delete fails the user has a duplicate to remove, never a lost reading.
    static func replace(_ old: BPSample, sys: Int, dia: Int, pulse: Int?, at date: Date) async throws {
        try await authorize()
        let targets = try await deletionTargets(for: old)   // before saving: the new reading must never be among them
        // The editor showed the pulse it knew of; if Health now links a different one, the user hasn't seen it.
        let oldPulse = targets.first { ($0 as? HKQuantitySample)?.quantityType == hrType }
        guard oldPulse?.uuid == old.pulseID else { throw HealthError.changed }
        try await save(sys: sys, dia: dia, pulse: pulse, at: date)
        do { try await store.delete(targets) } catch { throw HealthError.oldNotRemoved }
    }

    static func delete(_ sample: BPSample) async throws {
        try await authorize()
        try await store.delete(deletionTargets(for: sample))
    }

    /// The reading's correlation, its systolic and diastolic samples, and its own heart rate, all fetched fresh from Health:
    /// a reading shown on screen may be out of date, so it only says which correlation is meant.
    /// Deleting the correlation alone isn't documented to remove its samples, so every one is deleted explicitly.
    // ponytail: with heart-rate read access revoked Health returns no samples, so the pulse is left behind
    private static func deletionTargets(for sample: BPSample) async throws -> [HKObject] {
        let bpQuery = HKSampleQueryDescriptor(
            predicates: [.correlation(type: bpType, predicate: HKQuery.predicateForObject(with: sample.id))], sortDescriptors: [])
        guard let bp = try await bpQuery.result(for: store).first else { throw HealthError.gone }
        guard isOwn(bp) else { throw HealthError.notOurs }
        var targets: [HKObject] = [bp] + bp.objects.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        if let hr = try await ownPulse(of: bp) { targets.append(hr) }
        guard targets.allSatisfy(isOwn) else { throw HealthError.notOurs }
        return targets
    }

    /// The heart rate saved with this reading, by the same rule `Merged` uses for display, on fresh queries.
    private static func ownPulse(of bp: HKCorrelation) async throws -> HKSample? {
        let own = HKQuery.predicateForObjects(from: .default())
        let id = readingID(bp)
        let match = id.map { HKQuery.predicateForObjects(withMetadataKey: readingIDKey, allowedValues: [$0]) }
            ?? around(bp.startDate)
        let hrQuery = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: hrType, predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [own, match]))], sortDescriptors: [])
        let hrs = try await hrQuery.result(for: store).filter { $0.startDate == bp.startDate || id != nil }
        var unlinkedReadings = 0
        if id == nil {   // before IDs the link is by time alone, so it only holds if no other unlinked reading shares that time
            let sameTime = HKSampleQueryDescriptor(
                predicates: [.correlation(type: bpType, predicate: around(bp.startDate))],
                sortDescriptors: [])
            unlinkedReadings = try await sameTime.result(for: store).filter { $0.startDate == bp.startDate && readingID($0) == nil }.count
        }
        let linked = linkedPulse(readingID: id, unlinkedReadingsAtSameTime: unlinkedReadings,
                                 candidates: hrs.map { ($0.uuid, readingID($0)) })
        return hrs.first { $0.uuid == linked }
    }

    /// Samples near a time; callers keep only the exact timestamp. A strict zero-width interval matches nothing:
    /// HealthKit's end bound is exclusive.
    private static func around(_ date: Date) -> NSPredicate {
        let window = timeWindow(around: date)
        return HKQuery.predicateForSamples(withStart: window.lowerBound, end: window.upperBound)
    }

    nonisolated static func timeWindow(around date: Date) -> ClosedRange<Date> {
        date.addingTimeInterval(-1)...date.addingTimeInterval(1)
    }

    /// Which heart rate belongs to a reading of ours. `candidates` are this app's heart rates with the reading's ID, or,
    /// for a reading saved before IDs, at its exact time. Before IDs the link needs exactly one unlinked reading and one
    /// unlinked heart rate at that time (this app saved both at once); anything else is ambiguous and nothing is linked.
    nonisolated static func linkedPulse(readingID: String?, unlinkedReadingsAtSameTime: Int, candidates: [(id: UUID, readingID: String?)]) -> UUID? {
        let matches = candidates.filter { $0.readingID == readingID }
        guard matches.count == 1, readingID != nil || unlinkedReadingsAtSameTime == 1 else { return nil }
        return matches[0].id
    }

    private static func isOwn(_ object: HKObject) -> Bool {
        object.sourceRevision.source.bundleIdentifier == HKSource.default().bundleIdentifier
    }

    private static func readingID(_ object: HKObject) -> String? { object.metadata?[readingIDKey] as? String }

    /// Every blood pressure reading from any source, oldest first, re-emitted whenever Health changes.
    // ponytail: only our own heart-rate samples are matched; a Watch writes thousands a day and would swamp the stream
    static func readings() -> AsyncThrowingStream<[BPSample], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                try await authorize()
                let merged = Merged()
                // HealthKit doesn't deliver live updates for correlation types, so watch the systolic samples
                // (one per reading) and re-read all correlations whenever they change.
                let sysQuery = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: sysType)], anchor: nil)
                let bpQuery = HKSampleQueryDescriptor(predicates: [.correlation(type: bpType)], sortDescriptors: [])
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
                            for hr in update.addedSamples {
                                merged.pulses[hr.uuid] = Merged.Pulse(date: hr.startDate, bpm: Int(hr.quantity.doubleValue(for: bpm).rounded()), readingID: readingID(hr))
                            }
                            continuation.yield(merged.readings)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor final class Merged {
        struct Pulse { let date: Date; let bpm: Int; let readingID: String? }
        var bps: [BPSample] = []
        var pulses: [UUID: Pulse] = [:]   // this app's heart-rate samples

        /// Each reading with its pulse. A heart rate linked by reading ID (or, before IDs, by the exact time when
        /// nothing else shares it) is the reading's own and is edited with it. Readings without a link only borrow
        /// the nearest unlinked heart rate within a minute for display.
        var readings: [BPSample] {
            let byReadingID = Dictionary(grouping: pulses.filter { $0.value.readingID != nil }) { $0.value.readingID! }
            let unlinkedBPs = Dictionary(grouping: bps.filter { $0.readingID == nil }, by: \.date)
            let unlinkedHRs = Dictionary(grouping: pulses.filter { $0.value.readingID == nil }) { $0.value.date }
            var linked: [UUID: UUID] = [:]   // reading -> heart rate
            for bp in bps where bp.isOwn {
                let candidates = bp.readingID.map { byReadingID[$0] ?? [] } ?? unlinkedHRs[bp.date] ?? []
                linked[bp.id] = Health.linkedPulse(readingID: bp.readingID, unlinkedReadingsAtSameTime: unlinkedBPs[bp.date]?.count ?? 0,
                                                   candidates: candidates.map { ($0.key, $0.value.readingID) })
            }
            let claimed = Set(linked.values)
            return bps.map { bp in
                var sample = bp
                if let hr = linked[bp.id] {
                    sample.pulseID = hr
                    sample.pulse = pulses[hr]!.bpm
                } else if bp.readingID == nil {   // a reading saved with an ID but no pulse had none
                    let nearest = pulses.filter { !claimed.contains($0.key) && $0.value.readingID == nil }.values
                        .min { abs($0.date.timeIntervalSince(bp.date)) < abs($1.date.timeIntervalSince(bp.date)) }
                    if let nearest, abs(nearest.date.timeIntervalSince(bp.date)) <= 60 { sample.pulse = nearest.bpm }
                }
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
                  dia: Int(dia.quantity.doubleValue(for: mmHg).rounded()),
                  isOwn: bp.sourceRevision.source.bundleIdentifier == HKSource.default().bundleIdentifier,
                  sourceName: bp.sourceRevision.source.name,
                  readingID: bp.metadata?[Health.readingIDKey] as? String)
    }
}

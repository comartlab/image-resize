// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum OutputEstimateValue {
    case ready(OutputSizeEstimate)
    case unavailable(String)
}

/// Main-thread estimate ledger. Membership and generation reject completions
/// from an old setting, removed file, or earlier import of the same path.
final class OutputEstimateStore {
    private(set) var generation = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var failureCount = 0
    private(set) var skippedCount = 0
    private var members = Set<UUID>()
    private var values: [UUID: OutputEstimateValue] = [:]
    private var bytesHigh: UInt64 = 0
    private var bytesLow: UInt64 = 0

    var count: Int { members.count }
    var completedCount: Int { values.count }
    var pendingCount: Int { count - completedCount }
    func value(for id: UUID) -> OutputEstimateValue? { values[id] }

    func append(_ ids: [UUID]) { members.formUnion(ids) }

    func reset() {
        generation += 1
        values.removeAll(keepingCapacity: true)
        totalBytes = 0; failureCount = 0; skippedCount = 0
        bytesHigh = 0; bytesLow = 0
    }

    func clear() { members.removeAll(keepingCapacity: true); reset() }

    func remove(_ ids: [UUID]) {
        for id in ids {
            members.remove(id)
            if let old = values.removeValue(forKey: id) { subtract(old) }
        }
    }

    @discardableResult
    func record(_ value: OutputEstimateValue, for id: UUID, generation expected: Int) -> Bool {
        guard expected == generation, members.contains(id) else { return false }
        if let old = values[id] { subtract(old) }
        values[id] = value
        switch value {
        case .unavailable: failureCount += 1
        case .ready(let estimate):
            if estimate.skipped { skippedCount += 1 }
            let amount = estimate.skipped ? 0 : UInt64(max(0, estimate.outputBytes))
            let (low, carry) = bytesLow.addingReportingOverflow(amount)
            bytesLow = low
            if carry { bytesHigh += 1 }
        }
        updateTotal()
        return true
    }

    private func subtract(_ value: OutputEstimateValue) {
        switch value {
        case .unavailable: failureCount -= 1
        case .ready(let estimate):
            if estimate.skipped { skippedCount -= 1 }
            let amount = estimate.skipped ? 0 : UInt64(max(0, estimate.outputBytes))
            let (low, borrow) = bytesLow.subtractingReportingOverflow(amount)
            bytesLow = low
            if borrow { bytesHigh -= 1 }
        }
        updateTotal()
    }

    private func updateTotal() {
        totalBytes = bytesHigh > 0 || bytesLow > UInt64(Int64.max) ? Int64.max : Int64(bytesLow)
    }
}

// Copyright (c) 2026 The Commercial Art Lab
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Queue state owned by the application's main thread. Adding files uses only
/// lexical URL normalization; decoding and filesystem inspection happen later.
final class ImageQueue {
    private(set) var items: [ImageItem] = []
    private(set) var inspectedCount = 0
    private(set) var totalBytes: Int64 = 0

    private var indices: [UUID: Int] = [:]
    private var paths = Set<String>()
    // Keep a wider running sum so an unrepresentable display total can clamp
    // safely and still recover correctly when files are removed or updated.
    private var bytesHigh: UInt64 = 0
    private var bytesLow: UInt64 = 0

    @discardableResult
    func append(_ urls: [URL]) -> Range<Int> {
        let start = items.count
        for url in urls {
            let normalized = url.standardizedFileURL
            guard paths.insert(normalized.path).inserted else { continue }
            let item = ImageItem.queued(normalized)
            indices[item.id] = items.count
            items.append(item)
        }
        return start..<items.count
    }

    /// Reject a completion for a removed item, even if its old path has since
    /// been added again with a fresh identity.
    @discardableResult
    func update(_ item: ImageItem) -> Int? {
        guard let index = indices[item.id],
              items[index].url.standardizedFileURL.path == item.url.standardizedFileURL.path else { return nil }
        let previous = items[index]
        if previous.isInspected { inspectedCount -= 1 }
        subtractBytes(previous.fileBytes)
        items[index] = item
        if item.isInspected { inspectedCount += 1 }
        addBytes(item.fileBytes)
        return index
    }

    func index(of id: UUID) -> Int? { indices[id] }

    @discardableResult
    func remove(at selection: IndexSet) -> [UUID] {
        guard !selection.isEmpty else { return [] }
        var remaining: [ImageItem] = []
        remaining.reserveCapacity(items.count)
        var nextIndices: [UUID: Int] = [:]
        nextIndices.reserveCapacity(items.count)
        var removed: [UUID] = []
        for (index, item) in items.enumerated() {
            if selection.contains(index) {
                removed.append(item.id)
                paths.remove(item.url.standardizedFileURL.path)
                if item.isInspected { inspectedCount -= 1 }
                subtractBytes(item.fileBytes)
            } else {
                nextIndices[item.id] = remaining.count
                remaining.append(item)
            }
        }
        items = remaining
        indices = nextIndices
        return removed
    }

    func clear() {
        items.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        paths.removeAll(keepingCapacity: true)
        inspectedCount = 0
        bytesHigh = 0
        bytesLow = 0
        totalBytes = 0
    }

    private func addBytes(_ bytes: Int64) {
        let (low, carry) = bytesLow.addingReportingOverflow(UInt64(max(0, bytes)))
        bytesLow = low
        if carry { bytesHigh += 1 }
        updateDisplayedTotal()
    }

    private func subtractBytes(_ bytes: Int64) {
        let (low, borrow) = bytesLow.subtractingReportingOverflow(UInt64(max(0, bytes)))
        bytesLow = low
        if borrow { bytesHigh -= 1 }
        updateDisplayedTotal()
    }

    private func updateDisplayedTotal() {
        totalBytes = bytesHigh > 0 || bytesLow > UInt64(Int64.max) ? Int64.max : Int64(bytesLow)
    }
}

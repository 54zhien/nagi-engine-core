/// What can go wrong while assembling a page map.
public enum PageMapError: Error, Equatable, Sendable {
    /// A page-break entry named a unit the manifest does not contain.
    ///
    /// Reported rather than dropped: an entry that quietly does nothing is
    /// indistinguishable from one that worked, which is the failure this
    /// repository keeps refusing to build.
    case unknownUnitID(DocumentUnitID)
}

/// Which page a position lands on, for one manifest.
///
/// A pure value. It never measures text and never reaches a layout backend —
/// this module depends on none. The page boundaries are handed in by whoever did
/// the layout; this type only answers the question those boundaries make
/// answerable, and it is where that question is answered once rather than at
/// every call site.
///
/// **Partially complete by construction.** A unit with no entry in the breaks
/// has no known pages, and a lookup against it returns `nil`. That is the same
/// refusal the spike's fixed-page metric makes on reflowable content: this map
/// does not invent a page number in order to have something to say.
///
/// The answer is a page ordinal **within its unit**, not a publication-wide page
/// number. Turning it into "page 47" means prefix-summing the page counts of the
/// units before it, which requires knowing whether those units have been
/// paginated yet — something this type deliberately does not claim. A partial
/// map that reported a publication-wide ordinal would undercount, and the wrong
/// answer would look exactly like the right one.
public struct PageMap: Sendable {
    /// The manifest the answers are relative to.
    ///
    /// Held, not referenced from elsewhere: a key is only meaningful against the
    /// snapshot that produced it, and the cheapest way to make that true is for
    /// the map to own the manifest it was built from.
    private let manifest: DocumentManifest

    /// Page start keys, one array per unit index. An empty array means "no page
    /// information for this unit"; a non-empty one always begins at that unit's
    /// offset 0, so every offset inside a known unit falls on some page.
    private let pageStartsByUnit: [[DocumentOrderKey]]

    /// - Parameter pageBreaks: for each unit whose pages are known, the offsets
    ///   at which a new page begins — ascending, and greater than zero. An empty
    ///   array describes a unit that is exactly one page; leaving the unit out
    ///   describes one whose pages are not known yet. Ordering is the caller's
    ///   responsibility: this initializer neither sorts nor validates offsets,
    ///   for the same reason `DocumentManifest` does not validate unit fields.
    /// - Throws: `PageMapError.unknownUnitID` when an entry names a unit this
    ///   manifest does not have.
    public init(manifest: DocumentManifest, pageBreaks: [DocumentUnitID: [Int]]) throws {
        var starts = [[DocumentOrderKey]](repeating: [], count: manifest.readingOrder.count)

        for (unitID, breaks) in pageBreaks {
            guard let unitIndex = manifest.readingOrderIndex(of: unitID) else {
                throw PageMapError.unknownUnitID(unitID)
            }

            var keys = [DocumentOrderKey(unitIndex: unitIndex, utf16Offset: 0)]
            keys.append(contentsOf: breaks.map {
                DocumentOrderKey(unitIndex: unitIndex, utf16Offset: $0)
            })
            starts[unitIndex] = keys
        }

        self.manifest = manifest
        self.pageStartsByUnit = starts
    }

    /// The zero-based page within its unit that contains `utf16Offset`, or `nil`
    /// when this map knows nothing about that unit's pages.
    ///
    /// The lookup is two layers, which is what a hard pagination boundary means:
    /// the unit's index selects the unit, and only then does the offset get
    /// compared — inside that unit. Two units sharing an offset have nothing to
    /// do with each other here.
    ///
    /// Containment: an offset sitting exactly on a break belongs to the page that
    /// break starts, and an offset past the last break belongs to the last page,
    /// so no offset at or beyond zero is left unanswered for a known unit. A
    /// **negative** offset is not a position at all and answers `nil` — the map
    /// says it cannot place it rather than returning page 0.
    ///
    /// Note what is *not* checked: whether the offset is inside the unit's text.
    /// A manifest carries no lengths, and the map will not demand them.
    public func page(containingUnit unitID: DocumentUnitID, at utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0 else { return nil }
        guard let key = manifest.orderKey(of: unitID, at: utf16Offset) else { return nil }

        let starts = pageStartsByUnit[key.unitIndex]
        guard !starts.isEmpty else { return nil }

        return PageMap.lastIndex(atOrBefore: key, in: starts)
    }

    /// The index of the last page start that is not after `key`.
    ///
    /// `starts` is ascending and non-empty, and its first element is the unit's
    /// offset 0, so a key at or beyond zero always matches at least one entry.
    private static func lastIndex(
        atOrBefore key: DocumentOrderKey,
        in starts: [DocumentOrderKey]
    ) -> Int {
        var low = 0
        var high = starts.count - 1
        var found = 0

        while low <= high {
            let middle = low + (high - low) / 2
            if starts[middle] <= key {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        return found
    }
}

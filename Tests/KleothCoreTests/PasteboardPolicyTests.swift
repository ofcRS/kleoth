import Testing
import Foundation
@testable import KleothCore

@Suite struct PasteboardPolicyTests {
    @Test func restoresOnlyWhenChangeCountStillOwned() {
        // Nobody copied since our write → restore.
        #expect(PasteboardPolicy.shouldRestore(ownedChangeCount: 42, currentChangeCount: 42, exceededCap: false))
        // The user copied something during the 0.5 s window → their copy wins.
        #expect(!PasteboardPolicy.shouldRestore(ownedChangeCount: 42, currentChangeCount: 43, exceededCap: false))
        // A stale/rolled-back count is equally not ours.
        #expect(!PasteboardPolicy.shouldRestore(ownedChangeCount: 42, currentChangeCount: 41, exceededCap: false))
    }

    @Test func neverRestoresWhenCapExceeded() {
        #expect(!PasteboardPolicy.shouldRestore(ownedChangeCount: 7, currentChangeCount: 7, exceededCap: true))
        #expect(!PasteboardPolicy.shouldRestore(ownedChangeCount: 7, currentChangeCount: 9, exceededCap: true))
    }

    @Test func skipsPromisedFileAndFileContentsTypes() {
        #expect(!PasteboardPolicy.shouldCapture(type: "com.apple.pasteboard.promised-file-url"))
        #expect(!PasteboardPolicy.shouldCapture(type: "com.apple.pasteboard.promised-file-content-type"))
        #expect(!PasteboardPolicy.shouldCapture(type: "com.apple.NSFilePromiseItemMetaData"))
        #expect(!PasteboardPolicy.shouldCapture(type: "Apple files promise pasteboard type"))
        #expect(!PasteboardPolicy.shouldCapture(type: "NSFilesPromisePboardType"))
        #expect(!PasteboardPolicy.shouldCapture(type: "NeXT file contents pasteboard type"))
        #expect(!PasteboardPolicy.shouldCapture(type: "NSFileContentsPboardType"))
        // Every skipped spelling is actually in the published set.
        for type in PasteboardPolicy.skippedTypes {
            #expect(!PasteboardPolicy.shouldCapture(type: type))
        }
    }

    @Test func capturesOrdinaryTypes() {
        #expect(PasteboardPolicy.shouldCapture(type: "public.utf8-plain-text"))
        #expect(PasteboardPolicy.shouldCapture(type: "public.rtf"))
        #expect(PasteboardPolicy.shouldCapture(type: "public.png"))
        #expect(PasteboardPolicy.shouldCapture(type: "public.file-url"))
        #expect(PasteboardPolicy.shouldCapture(type: "public.html"))
        #expect(PasteboardPolicy.shouldCapture(type: "org.nspasteboard.TransientType"))
    }

    @Test func typesToCaptureKeepsPreferredAndBudgetsTheRest() {
        // An image-heavy item: the promise type is dropped, every preferred
        // type survives regardless of position, and only the first
        // `maxTypesPerItem` other flavors are read — in declared order.
        var declared = ["com.apple.pasteboard.promised-file-url", "public.tiff"]
        declared += (0..<10).map { "com.example.flavor-\($0)" }
        declared += ["public.utf8-plain-text", "public.file-url"]
        let chosen = PasteboardPolicy.typesToCapture(from: declared)
        #expect(!chosen.contains("com.apple.pasteboard.promised-file-url"))
        #expect(chosen.first == "public.tiff")
        #expect(chosen.suffix(2) == ["public.utf8-plain-text", "public.file-url"])
        let others = chosen.filter { !PasteboardPolicy.preferredTypes.contains($0) }
        #expect(others.count == PasteboardPolicy.maxTypesPerItem)
        #expect(others == ["public.tiff"] + (0..<5).map { "com.example.flavor-\($0)" })
        // A plain text item is untouched.
        #expect(PasteboardPolicy.typesToCapture(from: ["public.utf8-plain-text", "public.rtf"]) == ["public.utf8-plain-text", "public.rtf"])
    }

    @Test func shouldReadStopsEarlyForNonPreferredTypesOnly() {
        #expect(PasteboardPolicy.earlyStopBytes < PasteboardPolicy.maxBytes)
        #expect(PasteboardPolicy.shouldRead(type: "public.tiff", byteCountSoFar: 0))
        #expect(PasteboardPolicy.shouldRead(type: "public.tiff", byteCountSoFar: PasteboardPolicy.earlyStopBytes - 1))
        #expect(!PasteboardPolicy.shouldRead(type: "public.tiff", byteCountSoFar: PasteboardPolicy.earlyStopBytes))
        // Text flavors are still read past the early-stop line (they are what
        // the restore most needs and they are tiny).
        #expect(PasteboardPolicy.shouldRead(type: "public.utf8-plain-text", byteCountSoFar: PasteboardPolicy.maxBytes))
        #expect(PasteboardPolicy.captureTimeout > 0 && PasteboardPolicy.captureTimeout <= 0.5)
    }

    @Test func withinCapIsInclusiveAtBoundary() {
        #expect(PasteboardPolicy.maxBytes == 24 * 1024 * 1024)
        #expect(PasteboardPolicy.withinCap(byteCount: 0))
        #expect(PasteboardPolicy.withinCap(byteCount: PasteboardPolicy.maxBytes - 1))
        #expect(PasteboardPolicy.withinCap(byteCount: PasteboardPolicy.maxBytes))
        #expect(!PasteboardPolicy.withinCap(byteCount: PasteboardPolicy.maxBytes + 1))
    }
}

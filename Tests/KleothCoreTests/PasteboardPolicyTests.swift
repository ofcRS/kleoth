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

    @Test func withinCapIsInclusiveAtBoundary() {
        #expect(PasteboardPolicy.maxBytes == 24 * 1024 * 1024)
        #expect(PasteboardPolicy.withinCap(byteCount: 0))
        #expect(PasteboardPolicy.withinCap(byteCount: PasteboardPolicy.maxBytes - 1))
        #expect(PasteboardPolicy.withinCap(byteCount: PasteboardPolicy.maxBytes))
        #expect(!PasteboardPolicy.withinCap(byteCount: PasteboardPolicy.maxBytes + 1))
    }
}

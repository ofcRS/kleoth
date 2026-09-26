import Foundation
import IOKit.pwr_mgt
import KleothCore

/// PIDs holding a power assertion that means "a live call" in a Chromium
/// browser (`IOPMCopyAssertionsByProcess`, public since 10.7, no permission).
public enum WebCallAssertions {
    public static func pids() -> Set<pid_t> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPid = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out = Set<pid_t>()
        for (pid, assertions) in byPid {
            for assertion in assertions {
                if let name = assertion[kIOPMAssertionNameKey as String] as? String,
                   MeetingAppCatalog.webCallAssertionNames.contains(name) {
                    out.insert(pid_t(pid.int32Value))
                }
            }
        }
        return out
    }
}

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try` and returns the `NSException` it
/// raised, or nil when it returned normally.
///
/// Swift cannot catch `NSException`s, and AppKit's run loop swallows any that
/// reach it — which leaves the Swift concurrency runtime's thread-local
/// executor tracking pointing at a popped stack frame, so the *next* main-actor
/// isolation check in the process crashes (five Kleoth crash reports,
/// 2026-09-04…06, all `swift_task_isCurrentExecutor` → garbage). Every
/// AVFoundation call that is documented to raise (`installTap`, `connect`)
/// therefore goes through this bridge and comes back as a Swift error.
NSException * _Nullable KLCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

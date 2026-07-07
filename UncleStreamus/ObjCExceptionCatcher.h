#ifndef ObjCExceptionCatcher_h
#define ObjCExceptionCatcher_h

#import <Foundation/Foundation.h>

/// Runs `block`, catching any Objective-C `NSException` it throws and returning it
/// (or `nil` if the block completed normally).
///
/// Swift's `try` / `try?` only catches Swift `Error`s — it does **not** catch
/// Objective-C `NSException`s. CoreData / SwiftData (`NSPersistentCloudKitContainer`)
/// can throw an `NSException` from `fetch`/`save` when the store is mid-migration or a
/// CloudKit import is in flight at launch; those blow straight past `try?` and
/// terminate the app. Route such calls through this catcher to make them survivable.
///
/// `static inline` + block-in-header means Swift sees it via the bridging header with
/// no `.m` file, no build-phase change, and no target-membership wiring.
static inline NSException * _Nullable USCCatchException(NS_NOESCAPE void (^ _Nonnull block)(void)) {
    @try {
        block();
        return nil;
    }
    @catch (NSException *exception) {
        return exception;
    }
}

#endif /* ObjCExceptionCatcher_h */

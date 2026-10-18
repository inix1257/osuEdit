// Copyright (c) 2024, the flutter_soloud project authors.
// This file is a workaround for iOS 26.4+ / Xcode 16+ where the
// ma_ios_notification_handler class from miniaudio conflicts with other
// libraries that may also include miniaudio.
//
// The issue manifests as:
//   "Class ma_ios_notification_handler is implemented in both
//    .../flutter_soloud.framework/flutter_soloud and
//    .../Runner.debug.dylib"
//
// This header uses the preprocessor to rename the Objective-C class
// to a unique name for this plugin, avoiding the duplicate symbol conflict.
//
// Include this header BEFORE including miniaudio.h

#ifndef MINIAUDIO_OBJC_PREFIX_H
#define MINIAUDIO_OBJC_PREFIX_H

// Only apply these prefixes when compiling for Apple platforms
// Note: We use __APPLE__ which is defined by the compiler for all Apple platforms
// (iOS, macOS, tvOS, watchOS). The TARGET_OS_* macros require TargetConditionals.h
// which may not be available at this point in compilation.
#ifdef __APPLE__

// Rename the ma_ios_notification_handler class to avoid conflicts.
// This works because miniaudio.h is a single-header library that defines
// the class inline. By renaming it at compile time, we ensure the class
// is registered with a unique name in the Objective-C runtime, preventing
// duplicate symbol errors when other libraries (or Flutter's debug dylib)
// also include miniaudio.
#define ma_ios_notification_handler ma_ios_notification_handler_flutter_soloud

#endif // __APPLE__

#endif // MINIAUDIO_OBJC_PREFIX_H

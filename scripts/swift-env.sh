#!/bin/bash
# Shared SwiftPM env for Portside. Source from other scripts:
#   . "$(dirname "$0")/swift-env.sh"
# Or from a shell in the repo:
#   source scripts/swift-env.sh
#
# Xcode 26/27 Explicitly Built Modules add a large "planning deferred
# tasks" / SDK PCM tax on clean and cold debug builds of this single
# target. Measured on an M4 Max (Xcode 27.2): clean debug ~27s default
# vs ~9s with this off; incremental and release are about the same.
# Override with SWIFT_ENABLE_EXPLICIT_MODULES=YES if you need them.
#
# Only one SwiftPM process may use .build at a time. Parallel
# swift build / swift run / build-app.sh calls wait on a lock and look
# much slower than they are.
export SWIFT_ENABLE_EXPLICIT_MODULES="${SWIFT_ENABLE_EXPLICIT_MODULES:-NO}"

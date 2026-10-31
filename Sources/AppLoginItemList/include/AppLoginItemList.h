#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// True if `path` (POSIX) is in the session Open at Login list.
/// Uses the deprecated LSSharedFileList read API; insert/remove are stubs
/// on current macOS, so writes go through System Events instead.
bool AppLoginItemListContainsPath(const char *path);

#ifdef __cplusplus
}
#endif

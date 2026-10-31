#include "AppLoginItemList.h"

#include <CoreServices/CoreServices.h>
#include <limits.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

bool AppLoginItemListContainsPath(const char *path) {
    if (path == NULL || path[0] == '\0') { return false; }

    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (list == NULL) { return false; }

    UInt32 seed = 0;
    CFArrayRef snap = LSSharedFileListCopySnapshot(list, &seed);
    CFRelease(list);
    if (snap == NULL) { return false; }

    bool found = false;
    CFIndex count = CFArrayGetCount(snap);
    for (CFIndex i = 0; i < count; i++) {
        LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFArrayGetValueAtIndex(snap, i);
        CFErrorRef err = NULL;
        CFURLRef url = LSSharedFileListItemCopyResolvedURL(item, 0, &err);
        if (err) { CFRelease(err); }
        if (url == NULL) { continue; }

        char itemPath[PATH_MAX];
        Boolean ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)itemPath, sizeof(itemPath));
        CFRelease(url);
        if (!ok) { continue; }

        // Match with or without a trailing slash.
        size_t aLen = strlen(path);
        size_t bLen = strlen(itemPath);
        while (aLen > 1 && path[aLen - 1] == '/') { aLen--; }
        while (bLen > 1 && itemPath[bLen - 1] == '/') { bLen--; }
        if (aLen == bLen && strncmp(path, itemPath, aLen) == 0) {
            found = true;
            break;
        }
    }

    CFRelease(snap);
    return found;
}

#pragma clang diagnostic pop

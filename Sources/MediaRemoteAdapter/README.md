# MediaRemoteAdapter (vendored)

Source of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
at commit `14eed9389241d06e29f7326c19e9ebc6ec8a5f36`, BSD 3-Clause (see `LICENSE`).

Since macOS 15.4, MediaRemote returns no Now Playing data to non-Apple
processes. Portside builds this code as `libMediaRemoteAdapter.dylib` and
loads it into `/usr/bin/perl`, an Apple process that MediaRemote still
answers (see `Sources/portside/Widgets/MediaRemoteNowPlaying.swift`).
Portside never links it.

Local changes: dropped `src/adapter/test.m`, the test client, the CMake build
and the upstream `mediaremote-adapter.pl` launcher. The sources are otherwise
unchanged; to update, copy `include/` and `src/{adapter,private,utility}`
from upstream and delete `test.m` again.

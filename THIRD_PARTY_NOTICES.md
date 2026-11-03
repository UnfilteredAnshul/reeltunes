# Third-party notices — ReelTunes

ReelTunes ships an on-device extractor: a Python interpreter, a JavaScript
runtime and the yt-dlp extractor. All of it is packaged inside the APK and none
of it is fetched at runtime. **No GPL-licensed component is shipped.**

Full licence texts live in `LICENSES/`.

## Bundled engine

| Component | Version | Licence | Role |
|---|---|---|---|
| CPython | 3.12 | PSF-2.0 | Python interpreter (`libpython.so`, `libpython3.12.so.1.0`) |
| QuickJS | 2024/2025 build | MIT | JavaScript runtime for yt-dlp (`libqjs.so`) |
| yt-dlp | 2026.10.26 | Unlicense (public domain) | extractor (`libytdlp.so`) |

`libpython.zip.so` is the CPython install tree the interpreter unpacks on first
run. It contains no copyleft code: GNU Readline, GNU History and GNU dbm were
removed along with the three extension modules that link them
(`tools/repack_engine.py` reproduces this).

## Libraries inside the CPython payload

| Library | Licence |
|---|---|
| OpenSSL 3 (`libssl`, `libcrypto`, `engines-3/`, `ossl-modules/`) | Apache-2.0 |
| libxcrypt (`libcrypt`) | LGPL-2.1 |
| ncurses family (`libncursesw`, `libpanelw`, `libformw`, `libmenuw`, `libtinfo`, `libtic`, `libtermcap`) | X11 |
| SQLite (`libsqlite3`) | Public domain |
| zlib (`libz`) | zlib |
| bzip2 (`libbz2`) | bzip2-1.0.6 (BSD-like) |
| XZ / liblzma (`liblzma`) | Public domain |
| expat (`libexpat`) | MIT |
| libffi (`libffi`) | MIT |
| LLVM libc++ (`libc++_shared`) | Apache-2.0 with LLVM exception |
| libandroid-support (Termux) | Apache-2.0, MIT |

**libxcrypt** is shipped unmodified as a separate shared object
(`usr/lib/libcrypt.so`), which keeps it replaceable as LGPL-2.1 §6 requires.
Its source is available from <https://github.com/besser82/libxcrypt>.

## App dependencies

The Flutter and Android dependencies (`just_audio`, `audio_service`,
`file_picker`, `path_provider`, `shared_preferences`, `url_launcher`,
`receive_intent`, `reorderable_grid_view`, `audio_session`, the Flutter engine
and AndroidX) are MIT, BSD-3-Clause or Apache-2.0. Their notices are bundled by
Flutter into `assets/flutter_assets/NOTICES.Z`.

## Provenance

The CPython and QuickJS binaries originate from the Android builds published in
the youtubedl-android artifact `io.github.junkfood02.youtubedl-android:library:0.18.1`,
which repackages Termux packages. They are redistributed here under the PSF and
MIT licences of the underlying projects, with the GPL-licensed libraries
removed.

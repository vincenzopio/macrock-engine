# The runtime for launchers

This document covers what a release contains, how a launcher gets and checks it, what a Wine
prefix needs from it, and the environment variables it reads.

## Release files

A GitHub release, `v<version>`, has these files:

| File | Contents |
| --- | --- |
| `macrock-engine-<version>.aar` | the runtime: a sealed macOS bundle, in an Apple Archive |
| `xodus-service-<version>-arm64.aar` | the account service and its licenses, for the launcher's app bundle |
| `index.json` | size and SHA-256 of both archives, the requirements, the upstream commits |
| `*.aar.sha256` | the checksum of each archive |
| `SOURCES.md` | the upstream commits and the patches the runtime was built from |

A launcher:

1. reads `https://github.com/vincenzopio/macrock-engine/releases/latest/download/index.json`;
2. checks `requires`: the macOS version, Rosetta 2, and the Game Porting Toolkit major version;
3. downloads both archives over HTTPS and checks their size and SHA-256 against the index;
4. extracts them with AppleArchive;
5. checks the bundle with `codesign --verify --strict`, which detects any changed, missing or
   added file.

`tests/bundle/check.sh` does the same checks.

The launcher signs xodus-service again with its own identity when it puts it in its app bundle.

## The bundle

```
macrock-engine-<version>.bundle/Contents/
  Info.plist                      dev.macrock.engine, the version and the build number
  Resources/manifest.json         the SHA-256 of every runtime file, requirements, upstream commits
  Resources/runtime/
    bin/wine, bin/wineserver      Wine, x86_64
    lib/                          Wine, GnuTLS and FreeType,
                                  macrock-engine/x86_64-windows/xgameruntime.dll
    share/macrock-engine/prefix/  what a Wine prefix needs from this runtime
    share/doc/macrock-engine/     licenses and SOURCES.md
  _CodeSignature/                 an ad hoc seal over all of it
```

The runtime can live anywhere: Wine finds its files relative to its own location.

## Prefix setup

`share/macrock-engine/prefix/setup.json` says what a Wine prefix needs from this runtime. The
launcher applies it before each start. `tests/game/prefix-setup.py` does the same for the tests.

| Field | Meaning |
| --- | --- |
| `schema`, `revision` | the format, and the version of the steps |
| `dll_overrides` | the runtime's entries for `WINEDLLOVERRIDES`; the graphics backend adds its own |
| `game_drive` | the drive letter that must map to the game folder, `g:` (registry entries name it) |
| `steps` | what to do, in order; each step has an `id` and one action |

The actions are:

- `copy` a runtime file to a path in the prefix, given by `to`. This installs `xgameruntime.dll`
  in `system32`, where Gaming Services puts it on Windows.
- `reg` imports a registry file with the runtime's `reg.exe`. This registers the Windows App SDK
  classes the game activates, because the SDK's own bootstrapper fails under Wine.

Paths are relative to the runtime, and `to` is relative to the prefix. A step runs again when its
file changes, so a new runtime updates existing prefixes. To know which steps a prefix has, keep
the SHA-256 of each applied step's file: `prefix-setup.py` keeps them in
`PREFIX/.macrock-engine.json`.

Setup that is specific to the game belongs to the launcher: the game drive, GameInput and the
graphics environment.

## Environment variables

These are read by the runtime, in addition to Wine's own:

| Variable | Read by | Effect |
| --- | --- | --- |
| `WINEDLLPATH_PREPEND` | Wine (msync) | DLL directories searched before the runtime's own; this is how D3DMetal or DXMT replace Wine's `d3d*` and `dxgi` |
| `CX_APPLEGPTK_LIBD3DSHARED_PATH` | Wine (msync) | path of D3DMetal's `libd3dshared.dylib` |
| `WINEMSYNC` | Wine (msync) | `1` turns on msync, synchronization based on Mach primitives |
| `CX_ACTIVE_GRAPHICS_BACKEND` | Wine (d3dmetal) | `d3dmetal` selects the D3DMetal window bridge; any other value, DXMT's |
| `MACROCK_FPS_LOG` | Wine (fps-log) | a file that receives one line per second: fps, average and worst frame time, frames over 33.3 ms |
| `MACROCK_WINDOW_TITLE_SUFFIX` | Wine (window-title) | text appended to every non-empty window title, to tell sessions apart |
| `XODUS_SOCKET` | xgameruntime, xodus-service | absolute path of the service's socket, at most 103 bytes; default `/tmp/xodus.sock` |
| `XODUS_KEYCHAIN_SERVICE` | xodus-service | the Keychain service that holds its credentials; default `Xodus Service` |
| `XGAMERUNTIME_LOG_LEVEL` | xgameruntime | `err`, `warn`, `fixme` (the default) or `trace` |
| `XGAMERUNTIME_LOG_FILE` | xgameruntime | a file for its log, instead of standard output |

Run one xodus-service per signed-in account, each with its own socket and Keychain service.
xgameruntime never logs tokens. `trace` is verbose: it writes gigabytes in minutes.

D3DMetal itself reads `D3DM_MTL4`, `1` for its Metal 4 backend and `0` for Metal 3, and
`D3DM_SUPPORT_DXR`.

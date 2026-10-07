# macrock-engine

Run the Windows edition of Minecraft: Bedrock Edition on Apple Silicon Macs.

macrock-engine is the runtime behind macrock, a macOS launcher in development. It combines
[Wine](https://www.winehq.org) with a small set of patches, the Xbox GDK runtime that the game
expects, and a service that keeps the player's Microsoft account. The game draws with
Direct3D 12, which Apple's D3DMetal translates to Metal.

> [!NOTE]
> **Looking to play?** macrock-engine is not an app. The macrock launcher will download it,
> install the game and sign you in. This repository is for building and developing the runtime.

> [!WARNING]
> Experimental. Not affiliated with Mojang, Microsoft or Apple.

## Status

| Feature | State | Notes |
| --- | --- | --- |
| Sign-in | Works | Xbox Live, as on Windows |
| Online play | Works | servers, friends, parties, achievements |
| Skins | Works | import from a file |
| Marketplace | Works | offers with their prices |
| Realms | Partial | the free trial loads; buying a plan fails |
| Graphics | Works | Simple and Fancy need anti-aliasing off ([known issue](docs/known-issues.md#d3dmetal-40b2-metal-4-anti-aliasing-breaks-the-classic-renderer)) |
| Controllers | Not yet | GameInput's service is not set up |

The open problems are in [docs/known-issues.md](docs/known-issues.md).

## How it works

```
Minecraft.Windows.exe                 the game, built for x86_64 Windows
 └─ Wine 11.17 + patches               x86_64, under Rosetta 2
     ├─ Direct3D 12 → D3DMetal → Metal  D3DMetal comes from the user's Game Porting Toolkit
     ├─ xgameruntime.dll               the GDK runtime: Xbox sign-in, Store, …
     │    └─ socket → xodus-service    native arm64: Microsoft account, Xbox Live tokens
     └─ the game's own DLLs            Xbox services, PlayFab, Windows App SDK, …
```

The repository holds no upstream source. Each component is an upstream project pinned to a
commit in `sources.json`, plus our patches in `components/<name>/`:

| Component | Upstream | Our patches |
| --- | --- | --- |
| `wine` | [Wine](https://gitlab.winehq.org/wine/wine) 11.17 | the D3DMetal window bridge, faster synchronization (msync), AF_UNIX sockets, what the game's file picker needs |
| `xgameruntime` | [xodus-gaming/xgameruntime](https://github.com/xodus-gaming/xgameruntime), PR #18 | fixes to its connection to the service; XUser, XStore and the other GDK APIs the game uses |
| `xodus` | [xodus-gaming/xodus](https://github.com/xodus-gaming/xodus) | socket path, Keychain namespace, game license requests |

## Requirements

- An Apple Silicon Mac with macOS 27 and Rosetta 2.
- Apple's Game Porting Toolkit 4, for D3DMetal. Each user imports it and accepts Apple's
  license; it is never part of the runtime.
- A Microsoft account that owns Minecraft for Windows. The game comes from Microsoft, never from
  this project.

## Build

On an Apple Silicon Mac with macOS 27, its Command Line Tools and Homebrew:

```sh
packaging/macos/bootstrap.sh   # install the build prerequisites
packaging/macos/build.sh       # build the runtime into build.noindex/dist/
packaging/macos/package.sh     # make the release files in build.noindex/packages/
tests/bundle/check.sh          # check the release as a launcher receives it
```

[docs/building.md](docs/building.md) covers the build options, releases and the tests.

## Repository

```
components/       one directory per upstream project, with its patch series
packaging/macos/  build, package and release scripts, pinned inputs, license texts
tools/engine      turns a patch series into a git tree and back
tests/            checks for each part, for the game and for a release
docs/             the documents below
```

## Documentation

- [Building](docs/building.md): build options, what gets built, releases, tests.
- [Working on the patches](docs/patches.md): editing a series with `tools/engine`, moving to a
  new upstream version.
- [The runtime for launchers](docs/runtime.md): release files, the bundle, prefix setup,
  environment variables.
- [What Minecraft asks of the runtime](docs/minecraft-gdk-contract.md): the GDK and Windows APIs
  the game uses, and how each one is answered.
- [Known issues](docs/known-issues.md).

## Credits

- [Wine](https://www.winehq.org) and its contributors.
- hsr-wine-d3dmetal: msync and the D3DMetal window bridge, partly derived from CrossOver FOSS.
- [xodus-gaming](https://github.com/xodus-gaming): xgameruntime and xodus.
- WineGDK: the origin of xgameruntime's XGame, XGameRuntimeFeature, XSystem and XNetworking.
- Ally Sommers, Ralf Habacker and Giang Nguyen: AF_UNIX sockets in Wine (merge request !7650).
- [bedrock-mac](https://github.com/1JRobertson/bedrock-mac): the DXMT window-data patch.
- [Gcenx](https://github.com/Gcenx/macOS_Wine_builds): the macOS builds of GnuTLS and FreeType.
- Apple's Game Porting Toolkit provides D3DMetal. It is not distributed here.

## License

Each patch is under the license of the component it changes: LGPL-2.1-or-later for Wine and
xgameruntime, GPL-3.0-only for Xodus. The tools, scripts and tests are GPL-3.0-or-later.
[LICENSE.md](LICENSE.md) has the details, and a release carries the licenses of everything in it.

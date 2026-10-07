# What Minecraft Bedrock asks of the runtime

What the Windows (GDK) edition of Minecraft Bedrock (1.26) uses of the GDK runtime, WinRT and
Windows, and how macrock-engine answers it. Found by tracing game sessions: the menu, online play,
parties, Realms, the Dressing Room and the Marketplace. Open problems are in
[known-issues.md](known-issues.md).

## GDK classes

The game reaches the GDK through `xgameruntime.dll`'s `QueryApiImpl`; the runtime's implementation
is in `components/xgameruntime`, with unit tests run by `tests/xgameruntime/run.sh`.

| Class | What the game uses | macrock-engine |
| --- | --- | --- |
| XThreading | task queues and asynchronous calls | xgameruntime's, with fixes (topics `async-handler`, `winrt-mta`) |
| XGameRuntimeFeature | `XGameRuntimeIsFeatureAvailable`, about 425 times a second | every feature available; no logging on this path |
| XGame | `XGameGetXboxTitleId` | the title id of `MicrosoftGame.config` |
| XSystem, XSystemAnalytics | sandbox id, app-specific device id, analytics info | `RETAIL`; SHA-256 of the prefix's MachineGuid and the title id; a Windows 10 desktop |
| XNetworking | connectivity hint and its changes, security information for URLs, `XNetworkingVerifyServerCertificate` (for every HTTPS server) | a desktop with internet access; TLS 1.2 and 1.3 and no certificate thumbprints, so nothing to pin: WinHTTP validates certificates (`tests/tls/run.sh`) |
| XUser | sign-in, ids, gamertags, age group, privileges, change events, `XUserGetTokenAndSignature` (about a hundred calls a session) | SISU sign-in with the Xodus service's tickets; tokens where the NSAL names a relying party, signed when its policy asks; change events never fire |
| XStore | game license, associated products, Store ID keys, entitled products | the license from xodus-service (a macrock request of the Xodus protocol); products from the Store's public catalog; keys from collections and purchase services; no entitled products (ownership is unknown) |
| XError | the title's callback | `XErrorReport()` calls it |
| XPackage, XUserDevice, XGameInvite, XGameProtocol, XAccessibility, XGameEvent | asked for, then not used when refused | not implemented |

## WinRT classes

| Class | DLL | Use |
| --- | --- | --- |
| Windows.Foundation.Collections.PropertySet, Windows.Foundation.PropertyValue | wintypes | everywhere |
| Windows.Storage.Streams.Buffer | wintypes | the runtime's Xodus IPC |
| Windows.Data.Json.JsonValue | windows.web | the runtime's Xbox Live and Store requests |
| Windows.Foundation.Metadata.ApiInformation | wintypes | `IsMethodPresent` checks |
| Windows.UI.ViewManagement.Core.CoreInputView, Windows.UI.Text.Core.CoreTextServicesManager | windows.ui.core.textinput | text input |
| Windows.System.Profile.AnalyticsInfo | twinapi.appcore | XSystemAnalytics |
| Windows.ApplicationModel.DataTransfer.DataTransferManager, Windows.ApplicationModel.Core.CoreApplication | twinapi.appcore | start-up |
| Windows.UI.ViewManagement.UISettings | windows.ui | start-up |
| Windows.Devices.Enumeration.DeviceInformation | windows.devices.enumeration | start-up |
| Microsoft.Windows.Storage.Pickers.FileOpenPicker, Microsoft.Windows.ApplicationModel.Resources.* | the game's Windows App SDK 1.8 | importing a skin; registered by the runtime's prefix setup |
| Windows.Storage.StorageFile | windows.storage | importing a skin: `GetFileFromPathAsync`, then `Name` and `Path` |

`Windows.Internal.System.Profile.RegionPolicyEvaluator` is asked for once and missing, as on
Windows without it; the Windows App SDK bootstrapper's `PackageManager` fails harmlessly.

## DLLs and system services

- The game ships XSAPI and libHttpClient (`microsoft.xbox.services.gdk.c.thunks`,
  `libhttpclient.gdk`, `xcurl`), PlayFab multiplayer, its UI (`cohtml`, `renoircore`), `v8`,
  `fmod`, its media decoders and the Windows App SDK, self-contained.
- From the prefix: the runtime's `xgameruntime.dll` (copied by the prefix setup) and Microsoft's
  GameInput redistributable. GameInput's service is not registered: controllers do not work yet.
- The skin picker needs, besides the Windows App SDK classes, `bcp47mrm.dll` (`IsWellFormedTag`,
  and `GetDistanceOfClosestLanguageInList` looked up by name) and a COM fix for the picker's return
  to the game's thread (topics `bcp47mrm`, `com-context`).
- HTTPS goes through Wine's WinHTTP with Schannel over GnuTLS; the game asks for HTTP/2, which
  WinHTTP ignores, and for one WebSocket option that is not implemented (logged, no effect seen).

## Observed behaviour

- Sign-in, online play, the friend list, presence and parties (PlayFab lobbies over SignalR) work.
- Skins import from a file. A classic skin imported on another device does not appear: Bedrock
  does not sync imported skins.
- Realms: the landing page and the free trial offer load; choosing a plan says "Couldn't access
  platform store", without a further Store call (see known-issues.md).
- The Marketplace and the Realms offers show prices from the public catalog.

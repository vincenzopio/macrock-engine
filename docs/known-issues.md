# Known issues

Open problems of the runtime and of the game on it. What the game uses and how the runtime
answers it is in [minecraft-gdk-contract.md](minecraft-gdk-contract.md).

## D3DMetal 4.0b2, Metal 4: anti-aliasing breaks the classic renderer

In Simple and Fancy, with the game's anti-aliasing (MSAA, `gfx_msaa` in `options.txt`) at 2 or
4, the interface is tinted violet and translucent, panels let the world through, and skins and
the first-person hand lose their textures. Vibrant Visuals, which does not use MSAA, is fine.
Measured on the main menu's Social button:

| D3DMetal backend | `gfx_msaa` | Button colour | |
| --- | --- | --- | --- |
| Metal 4 (`D3DM_MTL4=1`) | 2 | (103,103,206) | broken |
| Metal 4 | 4 | (103,105,155) | broken |
| Metal 4 | 1 | (205,205,205) | right |
| Metal 3 (`D3DM_MTL4=0`) | 2 | (205,205,205) | right |

Another Wine build on the same D3DMetal shows the same, so the fault is in D3DMetal; its Metal 4
switches (`MPL_*`) do not change it. Until a Game Porting Toolkit fixes it: anti-aliasing off on
Metal 4, or Metal 3 for Simple and Fancy with anti-aliasing. A launcher can choose at start from
`graphics_mode` and `gfx_msaa`; Metal 4 is about 2.3× faster only where the GPU is the limit, as
in Vibrant Visuals.

## Windows App SDK: its bootstrapper fails, so its classes are registered

The game ships Windows App SDK 1.8 self-contained and initializes it with the bootstrapper, which
fails under Wine. Its classes are then not activatable, and importing a skin (the SDK's
`FileOpenPicker`) crashes the game. The runtime's prefix setup registers the classes the game
uses (`packaging/macos/prefix/winappsdk-1.8.reg`: the pickers and the resource manager) with a
`DllPath` in the game folder, which therefore must be drive G:. A game update to another SDK
version, or one using other SDK classes, needs a new registry file.

## Controllers

GameInput comes from the game's own redistributable, but its service (`GameInputRedistService`)
is not registered in the prefix, so the game sees no controller.

## Realms plans cannot be bought

The Realms screen loads and offers a free trial; choosing a plan then says "Couldn't access
platform store" without a further Store call. The Store's public add-on list does not carry the
current Realms subscriptions, and the runtime cannot tell what the user owns (entitled product
queries return nothing): no Store service answers ownership for the user's own tokens.

## Sign-in prompt at the first start of a profile

On a new profile the game shows its sign-in prompt at start; "Maybe later" continues signed in.
Silent sign-in succeeds every time the game asks; likely cause: the game waits for a user change
event, which xgameruntime does not send.

## msync: one xgameruntime task-queue test is unreliable

`XThreadingTests.VerifyTerminationOfCompositeQueue` (xgameruntime's suite, from libHttpClient)
passes 10 runs out of 10 with `WINEMSYNC=0` and 1 to 4 out of 10 with `WINEMSYNC=1`
(`GTEST_FILTER='*VerifyTerminationOfCompositeQueue*' GTEST_REPEAT=10 tests/xgameruntime/run.sh`).
The failing check is the last one: after a composite queue is terminated, a waiter registered on
the main queue must still fire within the test's 500 ms dispatch windows. Plain thread pool waits
behave under msync; the root cause is unknown. It matters because the game always runs with
msync, and its HTTP and Xbox calls complete through task queues.

## xgameruntime: the upstream base is a work in progress

The pinned commit is the head of xodus-gaming/xgameruntime PR #18 (the Xodus IPC over Windows
AF_UNIX sockets), still open. As published it needs the fixes in the `ipc-socket`, `clang-build`,
`async-handler`, `winrt-mta` and `xodus-protocol` topics, which are written so that they can be
proposed upstream.

## Xodus IPC: replies carry no request id

The Xodus protocol frames a message with a magic, a type and a length, and nothing that ties a
reply to its request. xgameruntime therefore sends one request at a time and gives the next reply
to the waiting request; a reply that comes after its request timed out (30 s) would go to the next
request. The fix is a request id in the protocol, which is up to Xodus upstream.

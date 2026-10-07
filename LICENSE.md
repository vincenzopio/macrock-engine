# Licenses

## Patches

Each patch in `components/<name>/patches/` is a modification of that component and is licensed
under the component's license:

| Component | License |
| --- | --- |
| `wine` | LGPL-2.1-or-later (Wine's `COPYING.LIB`) |
| `xgameruntime` | LGPL-2.1-or-later (its `LICENSE`) |
| `xodus` | GPL-3.0-only (its `LICENSE`) |

Every patch has its author in the `From:` header (whoever brought it here when its source does
not record one) and, when the work comes from elsewhere, its origin in the message:

- `hsr-wine-d3dmetal` (LGPL-2.1-or-later, partly derived from CrossOver FOSS): the msync and
  D3DMetal bridge patches;
- `bedrock-mac` (github.com/1JRobertson/bedrock-mac): the DXMT window-data patch, which that
  project publishes under LGPL-2.1-or-later like its other Wine patches;
- Wine merge request !7650 (gitlab.winehq.org/wine/wine): the `afunix` patches, by their Wine
  contributors; each names the MR head it was taken from;
- WineGDK (LGPL-2.1-or-later): XGame, XGameRuntimeFeature, XSystem and XNetworking in
  xgameruntime are ported from it, and XUser was written after its design.

The upstream components themselves are not part of this repository; `sources.json` names where
they come from.

## Tools and scripts

`tools/`, `packaging/` and `tests/` are licensed GPL-3.0-or-later, like macrock. See
<https://www.gnu.org/licenses/gpl-3.0.html>.

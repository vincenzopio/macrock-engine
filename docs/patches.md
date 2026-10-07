# Working on the patches

Each component is an upstream git repository, pinned to a commit in `sources.json`, plus an
ordered series of patches in `components/<name>/`. The patch files are the source of truth.
`tools/engine` generates a git tree from them, and turns the tree's commits back into patch
files. It needs only git and macOS's `/usr/bin/python3`.

## Editing a series

```sh
tools/engine import wine --all     # build.noindex/src/wine: the pinned commit, then one commit per patch
cd build.noindex/src/wine
# edit, then commit with the topic as a trailer:
git commit -a -m "winemac.drv: Do something." --trailer "Topic: d3dmetal"
cd -
tools/engine export wine           # rewrite components/wine from the tree's commits
git diff components/wine           # review, then commit in this repository
```

To change an existing patch, commit a fixup with `git commit --fixup <commit>`, squash it with
`git rebase -i --autosquash engine/base`, then export.

- **Topics.** A topic groups related patches, and names their directory:
  `components/<name>/patches/<topic>/`. Every commit needs exactly one `Topic:` trailer. The
  `series` file keeps the order across topics.
- **Leaving a topic out.** `import --without <topic>` builds without it, for A/B comparisons. A
  topic marked `optional` in `series` is applied only with `--with <topic>` or `--all`. `export`
  needs a tree with every topic, so that nothing is lost.
- **Safety.** `import` refuses to discard commits that are not exported yet, or uncommitted
  changes; `--force` overrides it. When the series and the pin have not changed, it does nothing.
- **Downloads.** The first import downloads only the pinned commit. `--from <clone>` takes it
  from a local repository instead.
- **Status.** `tools/engine status` shows each component's pin and topics, and whether its tree
  matches the series.

## Generated files

Like Wine's own commits, a patch carries the generated files it changes:

- **A new DLL** changes `configure` and the makefiles. `git add` the new files, then run
  `perl tools/make_makefiles`, which also runs autoconf. It also moves `unix/msync.c` in
  `dlls/ntdll/Makefile.in` into alphabetical order: leave that change out of your patch.
- **A wineserver protocol change** changes `include/wine/server_protocol.h` and the
  `server/request_*.h` headers. `perl tools/make_requests` writes them.

## Moving to a new upstream version

```sh
tools/engine rebase wine <ref>     # a Wine tag or commit
```

This fetches the ref and rebases the series onto it.

- Conflicts in generated files are resolved by generating them again, with the `regenerate`
  rules in `sources.json`.
- Other conflicts stop the rebase. Resolve them in the tree, `git add` the files, then run
  `tools/engine rebase wine --continue`, or `--abort`.
- Patches that become empty, usually because upstream merged them, are dropped and listed.

At the end, the new pin is written to `sources.json` and the series is exported.

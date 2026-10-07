"""prefix-setup.py RUNTIME PREFIX: apply a runtime's prefix setup to a Wine prefix.

The runtime describes what a prefix needs from it in share/macrock-engine/prefix/setup.json:

  schema, revision  the format, and the version of the steps
  dll_overrides     WINEDLLOVERRIDES entries the runtime needs (the graphics backend adds its own)
  game_drive        the drive that must map to the game folder (registry entries name it)
  steps             each with an id and one action, paths relative to the runtime:
                      copy: FILE, to: PATH  copy a runtime file to PATH, relative to the prefix
                      reg: FILE             import a registry file with the runtime's reg.exe

A step runs when the prefix has not had it, or had it from a different file: the SHA-256 of
each applied step's file is kept in PREFIX/.macrock-engine.json, so a new runtime brings its
new files. The launcher applies the same steps; this is the test harness's copy. Prints the
steps it applies. Python standard library only; run with python3 -I.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

STATE = ".macrock-engine.json"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_wine(runtime, prefix, *args):
    env = {key: os.environ[key] for key in ("HOME", "USER", "TMPDIR") if key in os.environ}
    env.update(PATH="/usr/bin:/bin", WINEPREFIX=str(prefix), WINEARCH="win64", WINEDEBUG="-all",
               LC_ALL="en_US.UTF-8", WINEDLLOVERRIDES="mscoree,mshtml=")
    subprocess.run([str(runtime / "bin" / "wine"), *args], env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([str(runtime / "bin" / "wineserver"), "-w"], env=env, check=True)


def main():
    runtime, prefix = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    setup = json.loads((runtime / "share" / "macrock-engine" / "prefix" / "setup.json").read_text())
    if setup["schema"] != 1:
        sys.exit("unknown prefix setup schema {}".format(setup["schema"]))
    state_path = prefix / STATE
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    applied = state.get("steps", {})

    for step in setup["steps"]:
        source = runtime / (step.get("copy") or step["reg"])
        digest = sha256(source)
        if applied.get(step["id"]) == digest:
            continue
        if "copy" in step:
            target = prefix / step["to"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        else:
            run_wine(runtime, prefix, "reg", "import", "Z:" + str(source).replace("/", "\\"))
        print("==> prefix: {} ({})".format(step["id"], "copy" if "copy" in step else "reg"))
        applied[step["id"]] = digest
        state_path.write_text(json.dumps({"revision": setup["revision"], "steps": applied}, indent=2) + "\n")


if __name__ == "__main__":
    main()

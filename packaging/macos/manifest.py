"""manifest.py write|verify|index: the manifest of a runtime bundle, and the release index.

  write OPTIONS        write Contents/Resources/manifest.json of a bundle
  verify RESOURCES     check the runtime against the manifest in RESOURCES
  index MANIFEST BUNDLE HELPER OUT
                       write the release index from the manifest and the two archives

The manifest lists the SHA-256 of every regular file and the target of every symlink of the
runtime directory, relative to it. It also records what the runtime was built from (the
macrock-engine commit and, for each component, its pin and what tools/engine applied to its
tree) and what it requires (macOS, Rosetta, the Game Porting Toolkit, the prefix setup).

The index is the file a launcher reads first: the size and SHA-256 of the archives it then
downloads, what the runtime requires, and what it was built from.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tree_contents(root):
    files, links = {}, {}
    for directory, subdirs, names in os.walk(root):
        subdirs.sort()
        for name in sorted(names + [d for d in subdirs if (pathlib.Path(directory) / d).is_symlink()]):
            path = pathlib.Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                links[relative] = os.readlink(path)
            else:
                files[relative] = sha256(path)
    return files, links


def git(tree, *args):
    return subprocess.run(["git", "-C", str(tree), *args], text=True, check=True,
                          stdout=subprocess.PIPE).stdout.strip()


def write(args):
    components = {}
    pins = json.loads((args.engine_root / "sources.json").read_text())["components"]
    for name in args.component:
        pin, tree = pins[name], args.work / "src" / name
        stamp = json.loads((tree / ".git" / "engine-stamp.json").read_text())
        head = git(tree, "rev-parse", "HEAD")
        components[name] = {
            "url": pin["url"],
            "ref": pin["ref"],
            "commit": pin["commit"],
            "tree_head": head,
            "series_digest": stamp["digest"],
            "excluded_topics": stamp["excluded"],
            "unexported_changes": head != stamp["head"] or bool(git(tree, "status", "--porcelain")),
        }
    setup_path = "share/macrock-engine/prefix/setup.json"
    setup = json.loads((args.runtime / setup_path).read_text())
    files, links = tree_contents(args.runtime)
    manifest = {
        "schema": 4,
        "name": "macrock-engine",
        "version": args.version,
        "build": args.build,
        "engine_commit": args.engine_commit,
        "dirty": args.dirty or any(c["unexported_changes"] for c in components.values()),
        "components": components,
        "arch": "x86_64",
        "requires": {"macos": args.target, "rosetta": True, "gptk": args.gptk},
        "prefix_setup": {"path": setup_path, "schema": setup["schema"], "revision": setup["revision"]},
        "runtime": os.path.relpath(args.runtime, args.out.parent),
        "built": now(),
        "files": files,
        "links": links,
    }
    args.out.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print("dirty" if manifest["dirty"] else "clean")


def verify(args):
    manifest = json.loads((args.resources / "manifest.json").read_text())
    files, links = tree_contents(args.resources / manifest["runtime"])
    differences = sorted(set(files.items()) ^ set(manifest["files"].items())) + \
                  sorted(set(links.items()) ^ set(manifest["links"].items()))
    for path, _ in differences[:10]:
        print("differs: " + path, file=sys.stderr)
    sys.exit(1 if differences else 0)


def index(args):
    manifest = json.loads(args.manifest.read_text())

    def describe(archive, **extra):
        return dict({"file": archive.name, "size": archive.stat().st_size, "sha256": sha256(archive)}, **extra)

    version = manifest["version"]
    result = {
        "schema": 1,
        "name": manifest["name"],
        "version": version,
        "build": manifest["build"],
        "published": now(),
        "engine_commit": manifest["engine_commit"],
        "dirty": manifest["dirty"],
        "arch": manifest["arch"],
        "requires": manifest["requires"],
        "prefix_setup": {key: manifest["prefix_setup"][key] for key in ("schema", "revision")},
        "components": {name: {key: c[key] for key in ("url", "ref", "commit")}
                       for name, c in manifest["components"].items()},
        "bundle": describe(args.bundle, sealed=True, path="macrock-engine-{}.bundle".format(version)),
        "helper": describe(args.helper, arch="arm64", path="xodus-service-{}/xodus-service".format(version)),
    }
    args.out.write_text(json.dumps(result, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    w = commands.add_parser("write")
    w.add_argument("--runtime", type=pathlib.Path, required=True)
    w.add_argument("--out", type=pathlib.Path, required=True)
    w.add_argument("--version", required=True)
    w.add_argument("--build", type=int, required=True)
    w.add_argument("--target", required=True)
    w.add_argument("--engine-root", type=pathlib.Path, required=True)
    w.add_argument("--work", type=pathlib.Path, required=True)
    w.add_argument("--engine-commit", required=True)
    w.add_argument("--dirty", action="store_true")
    w.add_argument("--component", action="append", required=True)
    w.add_argument("--gptk", required=True)
    v = commands.add_parser("verify")
    v.add_argument("resources", type=pathlib.Path)
    i = commands.add_parser("index")
    i.add_argument("manifest", type=pathlib.Path)
    i.add_argument("bundle", type=pathlib.Path)
    i.add_argument("helper", type=pathlib.Path)
    i.add_argument("out", type=pathlib.Path)
    args = parser.parse_args()
    {"write": write, "verify": verify, "index": index}[args.command](args)


if __name__ == "__main__":
    main()

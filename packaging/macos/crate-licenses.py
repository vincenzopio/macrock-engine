"""crate-licenses.py TREE PACKAGE TOOLCHAIN COMMON OUT: the licenses of a Rust binary's crates.

Runs `cargo +TOOLCHAIN metadata --locked` in the workspace TREE, follows PACKAGE's normal and
build dependencies for aarch64-apple-darwin, and writes OUT, a Markdown file with every
third-party crate (name, version, license, repository) and the texts of its license files.
Texts that several crates ship identically appear once. A crate without license files gets the
standard text of its license from COMMON (<SPDX id>.txt; Apache-2.0 first for dual licenses) and
its declared authors. The Rust standard library, linked in, is listed with its licenses too.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

LICENSE_NAME = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|COPYRIGHT|UNLICENSE)", re.IGNORECASE)


def main():
    tree, package, toolchain = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    common, out = pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5])
    metadata = json.loads(subprocess.run(
        ["cargo", "+" + toolchain, "metadata", "--format-version", "1", "--locked",
         "--filter-platform", "aarch64-apple-darwin"],
        cwd=str(tree), check=True, text=True, stdout=subprocess.PIPE).stdout)
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}

    root = next(i for i, p in packages.items() if p["name"] == package and not p["source"])
    seen, todo = set(), [root]
    while todo:
        current = todo.pop()
        if current in seen:
            continue
        seen.add(current)
        for dep in nodes[current]["deps"]:
            if any(kind["kind"] in (None, "build") for kind in dep["dep_kinds"]):
                todo.append(dep["pkg"])
    crates = sorted((packages[i] for i in seen if packages[i]["source"]),
                    key=lambda p: (p["name"], p["version"]))

    texts, sections = {}, []

    def text_id(content):
        key = hashlib.sha256(content.encode()).hexdigest()[:12]
        texts.setdefault(key, content)
        return key

    def common_text(crate, expression):
        ids = re.findall(r"[A-Za-z0-9.\-]+", expression or "")
        for spdx in sorted(ids, key=lambda i: i != "Apache-2.0"):
            path = common / (spdx + ".txt")
            if path.exists():
                return spdx, text_id(path.read_text())
        sys.exit("{}: no license file and no standard text for {!r}".format(crate, expression))

    for crate in crates:
        directory = pathlib.Path(crate["manifest_path"]).parent
        files = sorted(f for f in directory.iterdir() if f.is_file() and LICENSE_NAME.match(f.name))
        lines = ["### {} {}".format(crate["name"], crate["version"]), "",
                 "License: {}".format(crate["license"] or "see its license file")]
        if crate.get("repository"):
            lines.append("Repository: {}".format(crate["repository"]))
        if files:
            for f in files:
                key = text_id(f.read_text(errors="replace"))
                lines.append("- {}: [text {}](#text-{})".format(f.name, key, key))
        else:
            spdx, key = common_text(crate["name"], crate["license"])
            authors = ", ".join(crate["authors"]) or "the authors named in its repository"
            lines.append("- No license file in the crate; {} as published by SPDX: [text {}](#text-{}). "
                         "Copyright: {}.".format(spdx, key, key, authors))
        sections.append("\n".join(lines))

    apache = common_text("the Rust standard library", "Apache-2.0")[1]
    mit = common_text("the Rust standard library", "MIT")[1]
    header = [
        "# Third-party licenses of {}".format(package), "",
        "{} is built from the crates below (the {} workspace's Cargo.lock), each under its own "
        "license, and statically linked with the Rust standard library (MIT OR Apache-2.0: "
        "[text {}](#text-{}), [text {}](#text-{})).".format(package, tree.name, apache, apache, mit, mit),
        ""]
    body = ["## Crates", ""] + [s + "\n" for s in sections] + ["## License texts", ""]
    for key, content in texts.items():
        body += ['<a id="text-{}"></a>'.format(key), "### Text {}".format(key), "", "```", content.rstrip(), "```", ""]
    out.write_text("\n".join(header + body) + "\n")


if __name__ == "__main__":
    main()

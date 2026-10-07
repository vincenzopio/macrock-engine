"""Tests for tools/engine, on small throwaway upstream repositories (no network).

Run with: /usr/bin/python3 -m unittest discover -s tools/tests
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ENGINE = pathlib.Path(__file__).resolve().parents[1] / "engine"
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Test Author",
    "GIT_AUTHOR_EMAIL": "author@example.com",
    "GIT_COMMITTER_NAME": "Test Committer",
    "GIT_COMMITTER_EMAIL": "committer@example.com",
    "LC_ALL": "C",
    # The submodule test uses a local repository; git refuses file:// submodules by default.
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "protocol.file.allow",
    "GIT_CONFIG_VALUE_0": "always",
}
# The generated file is one line built from the whole definition file, so any two changes to
# the definitions conflict in it even when the definitions themselves merge cleanly.
REGEN = 'printf "version %s: %s\\n" "$(wc -l < protocol.def | tr -d " ")" ' \
        '"$(tr "\\n" " " < protocol.def)" > gen.h\n'


class EngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="engine-test."))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.upstream = self.tmp / "upstream"
        self.upstream.mkdir()
        self.git(self.upstream, "init", "--quiet", "-b", "main")
        self.write(self.upstream / "a.txt", "".join("line {}\n".format(n) for n in range(1, 21)))
        self.write(self.upstream / "b.txt", "b\n")
        self.write(self.upstream / "protocol.def", "alpha\nbeta\ngamma\ndelta\nepsilon\n")
        self.write(self.upstream / "tools" / "regen", REGEN)
        self.regen(self.upstream)
        self.v1 = self.commit(self.upstream, "Release 1.", tag="v1")

        self.root = self.tmp / "root"
        (self.root / "components").mkdir(parents=True)
        self.set_pin("v1", self.v1)
        self.tree = self.root / "build.noindex" / "src" / "demo"
        self.component = self.root / "components" / "demo"

    # --- helpers ------------------------------------------------------------------------------

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, repo, *args):
        env = dict(os.environ, **GIT_ENV)
        proc = subprocess.run(["git", "-C", str(repo), *args], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def regen(self, repo):
        subprocess.run(["sh", "tools/regen"], cwd=str(repo), check=True)

    def commit(self, repo, subject, topic=None, tag=None):
        self.git(repo, "add", "--all")
        args = ["commit", "--quiet", "-m", subject]
        if topic:
            args += ["--trailer", "Topic: " + topic]
        self.git(repo, *args)
        if tag:
            self.git(repo, "tag", tag)
        return self.git(repo, "rev-parse", "HEAD")

    def set_pin(self, ref, commit, url=None, regenerate=None):
        sources = {"schema": 1, "components": {"demo": {
            "url": url or str(self.upstream), "ref": ref, "commit": commit,
            "regenerate": regenerate or [{"command": ["sh", "tools/regen"], "files": ["gen.h"]}]}}}
        (self.root / "sources.json").write_text(json.dumps(sources, indent=2) + "\n")

    def pin(self):
        return json.loads((self.root / "sources.json").read_text())["components"]["demo"]

    def engine(self, *args, ok=True):
        env = dict(os.environ, ENGINE_ROOT=str(self.root), GIT_CONFIG_COUNT="1",
                   GIT_CONFIG_KEY_0="protocol.file.allow", GIT_CONFIG_VALUE_0="always")
        env.pop("ENGINE_WORK", None)
        proc = subprocess.run([sys.executable, str(ENGINE), *args], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        else:
            self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc.stdout + proc.stderr

    def snapshot(self):
        return {path.relative_to(self.component).as_posix(): path.read_bytes()
                for path in sorted(self.component.rglob("*")) if path.is_file()}

    def series(self):
        lines = (self.component / "series").read_text().splitlines()
        return [line for line in lines if line and not line.startswith("#")]

    def two_topics(self):
        """Import, then export three commits in two topics."""
        self.engine("import", "demo")
        self.write(self.tree / "b.txt", "b\none\n")
        self.commit(self.tree, "b: first change.", "one")
        self.write(self.tree / "a.txt", (self.tree / "a.txt").read_text().replace("line 1\n", "line one\n"))
        self.commit(self.tree, "a: change line 1.", "two")
        self.write(self.tree / "b.txt", "b\none\nagain\n")
        self.commit(self.tree, "b: second change.", "one")
        self.engine("export", "demo")

    # --- import / export ----------------------------------------------------------------------

    def test_import_checks_out_the_pin(self):
        self.engine("import", "demo")
        self.assertEqual(self.git(self.tree, "rev-parse", "HEAD"), self.v1)
        self.assertEqual(self.git(self.tree, "rev-parse", "engine/base"), self.v1)
        self.assertEqual(self.git(self.tree, "symbolic-ref", "--short", "HEAD"), "engine")
        self.assertIn("matches the series", self.engine("status"))

    def test_export_round_trip_is_stable_and_deterministic(self):
        self.two_topics()
        self.assertEqual([line.split("-")[0] for line in self.series()], ["one/0001", "two/0001", "one/0002"])
        first = self.snapshot()
        self.assertIn(b"Topic: one", first["patches/one/0001-b-first-change.patch"])
        self.assertIn(b"From: Test Author <author@example.com>", first["patches/one/0001-b-first-change.patch"])

        self.engine("export", "demo")
        self.assertEqual(self.snapshot(), first)

        shutil.rmtree(self.tree)
        self.engine("import", "demo")
        head = self.git(self.tree, "rev-parse", "HEAD")
        self.assertEqual((self.tree / "b.txt").read_text(), "b\none\nagain\n")
        self.engine("export", "demo")
        self.assertEqual(self.snapshot(), first)

        shutil.rmtree(self.tree)
        self.engine("import", "demo")
        self.assertEqual(self.git(self.tree, "rev-parse", "HEAD"), head)

    def test_export_requires_a_topic_trailer(self):
        self.engine("import", "demo")
        self.write(self.tree / "b.txt", "b\nx\n")
        self.commit(self.tree, "b: no topic.")
        self.assertIn("Topic", self.engine("export", "demo", ok=False))
        self.assertFalse((self.component / "series").exists())

    def test_import_refuses_to_discard_work(self):
        self.engine("import", "demo")
        self.write(self.tree / "b.txt", "b\nwork\n")
        self.assertIn("uncommitted changes", self.engine("status"))
        self.assertIn("uncommitted changes", self.engine("import", "demo", ok=False))
        self.commit(self.tree, "b: work.", "one")
        self.assertIn("not exported", self.engine("import", "demo", ok=False))
        self.assertIn("not exported", self.engine("status"))
        self.engine("import", "demo", "--force")
        self.assertEqual(self.git(self.tree, "rev-parse", "HEAD"), self.v1)

    def test_unchanged_series_leaves_the_tree_alone(self):
        self.two_topics()
        self.engine("import", "demo")
        os.utime(self.tree / "b.txt", (1000000000, 1000000000))
        self.assertIn("unchanged", self.engine("import", "demo"))
        self.assertEqual((self.tree / "b.txt").stat().st_mtime, 1000000000)

    def test_topic_selection(self):
        self.two_topics()
        series = (self.component / "series").read_text()
        (self.component / "series").write_text(series.replace("-a-change-line-1.patch",
                                                              "-a-change-line-1.patch optional"))
        self.engine("import", "demo")
        self.assertIn("line 1\n", (self.tree / "a.txt").read_text())
        self.assertIn("imported without two", self.engine("status"))
        self.assertIn("exporting would drop", self.engine("export", "demo", ok=False))

        self.engine("import", "demo", "--with", "two")
        self.assertIn("line one\n", (self.tree / "a.txt").read_text())
        self.engine("import", "demo", "--without", "one")
        self.assertEqual((self.tree / "b.txt").read_text(), "b\n")
        self.engine("import", "demo", "--all")
        self.engine("export", "demo")
        self.assertIn("two/0001-a-change-line-1.patch optional", self.series())
        self.assertIn("unknown topic", self.engine("import", "demo", "--without", "three", ok=False))

    def test_import_takes_the_pinned_commit_when_the_ref_moved(self):
        self.write(self.upstream / "b.txt", "b\nupstream\n")
        self.commit(self.upstream, "Release 2.")  # main moved on
        self.set_pin("main", self.v1)
        self.engine("import", "demo")
        self.assertEqual(self.git(self.tree, "rev-parse", "HEAD"), self.v1)

    def test_import_fails_when_the_pinned_commit_is_gone(self):
        self.set_pin("v1", "0123456789abcdef0123456789abcdef01234567")
        self.assertIn("cannot be fetched", self.engine("import", "demo", ok=False))

    def test_import_from_a_local_clone(self):
        self.set_pin("v1", self.v1, url="https://invalid.invalid/demo.git")
        relative = os.path.relpath(self.upstream)  # resolved against the caller's directory
        self.engine("import", "demo", "--from", relative)
        self.assertEqual(self.git(self.tree, "rev-parse", "HEAD"), self.v1)

    def test_import_checks_out_submodules(self):
        library = self.tmp / "library"
        library.mkdir()
        self.git(library, "init", "--quiet", "-b", "main")
        self.write(library / "lib.c", "int lib;\n")
        self.commit(library, "Library 1.")
        self.git(self.upstream, "submodule", "add", "--quiet", str(library), "external/library")
        v2 = self.commit(self.upstream, "Release 2.", tag="v2")
        self.set_pin("v2", v2)
        sources = json.loads((self.root / "sources.json").read_text())
        sources["components"]["demo"]["submodules"] = True
        (self.root / "sources.json").write_text(json.dumps(sources, indent=2) + "\n")

        self.engine("import", "demo")
        self.assertEqual((self.tree / "external" / "library" / "lib.c").read_text(), "int lib;\n")
        self.assertIn("matches the series", self.engine("status"))
        self.assertIn("unchanged", self.engine("import", "demo"))

    # --- rebase -------------------------------------------------------------------------------

    def test_rebase_drops_patches_that_are_upstream(self):
        self.two_topics()
        self.write(self.upstream / "b.txt", "b\none\n")  # upstream took the first patch
        self.write(self.upstream / "a.txt", (self.upstream / "a.txt").read_text().replace("line 20\n", "line 20!\n"))
        v2 = self.commit(self.upstream, "Release 2.", tag="v2")

        output = self.engine("rebase", "demo", "v2")
        self.assertIn("dropped: b: first change.", output)
        self.assertEqual(self.pin()["ref"], "v2")
        self.assertEqual(self.pin()["commit"], v2)
        self.assertEqual(self.series(), ["two/0001-a-change-line-1.patch", "one/0001-b-second-change.patch"])
        text = (self.tree / "a.txt").read_text()
        self.assertIn("line one\n", text)
        self.assertIn("line 20!\n", text)
        self.assertEqual((self.tree / "b.txt").read_text(), "b\none\nagain\n")
        self.assertIn("matches the series", self.engine("status"))

    def test_rebase_regenerates_conflicting_generated_files(self):
        self.engine("import", "demo")
        self.write(self.tree / "protocol.def", "alpha\nbeta\ngamma\ndelta\nepsilon\nomega\n")
        self.regen(self.tree)
        self.commit(self.tree, "protocol: add omega.", "proto")
        self.engine("export", "demo")

        self.write(self.upstream / "protocol.def", "zero\nalpha\nbeta\ngamma\ndelta\nepsilon\n")
        self.regen(self.upstream)
        self.commit(self.upstream, "Release 2.", tag="v2")

        self.assertIn("Regenerating gen.h", self.engine("rebase", "demo", "v2"))
        self.assertEqual((self.tree / "gen.h").read_text(),
                         "version 7: zero alpha beta gamma delta epsilon omega \n")
        patch = (self.component / "patches" / "proto" / "0001-protocol-add-omega.patch").read_text()
        self.assertIn("+version 7: zero alpha beta gamma delta epsilon omega", patch)

    def test_rebase_regenerates_with_the_matching_rule(self):
        # Several rules (Wine: make_requests for the server headers, autoconf for configure):
        # only the one whose files conflict runs; the other would fail.
        self.set_pin("v1", self.v1, regenerate=[
            {"command": ["sh", "-c", "exit 1"], "files": ["configure"]},
            {"command": ["sh", "tools/regen"], "files": ["gen.h"]}])
        self.engine("import", "demo")
        self.write(self.tree / "protocol.def", "alpha\nbeta\ngamma\ndelta\nepsilon\nomega\n")
        self.regen(self.tree)
        self.commit(self.tree, "protocol: add omega.", "proto")
        self.engine("export", "demo")

        self.write(self.upstream / "protocol.def", "zero\nalpha\nbeta\ngamma\ndelta\nepsilon\n")
        self.regen(self.upstream)
        self.commit(self.upstream, "Release 2.", tag="v2")

        output = self.engine("rebase", "demo", "v2")
        self.assertIn("Regenerating gen.h with sh tools/regen", output)
        self.assertNotIn("exit 1", output)
        self.assertEqual((self.tree / "gen.h").read_text(),
                         "version 7: zero alpha beta gamma delta epsilon omega \n")

    def test_rebase_stops_on_conflicts_and_continues(self):
        self.engine("import", "demo")
        self.write(self.tree / "b.txt", "ours\n")
        self.commit(self.tree, "b: ours.", "one")
        self.engine("export", "demo")
        self.write(self.upstream / "b.txt", "theirs\n")
        v2 = self.commit(self.upstream, "Release 2.", tag="v2")

        output = self.engine("rebase", "demo", "v2", ok=False)
        self.assertIn("b.txt", output)
        self.assertIn("--continue", output)
        self.assertIn("already in progress", self.engine("rebase", "demo", "v2", ok=False))

        self.write(self.tree / "b.txt", "both\n")
        self.git(self.tree, "add", "b.txt")
        self.engine("rebase", "demo", "--continue")
        self.assertEqual(self.pin()["commit"], v2)
        patch = (self.component / "patches" / "one" / "0001-b-ours.patch").read_text()
        self.assertIn("+both", patch)

    def test_rebase_abort_restores_the_tree(self):
        self.engine("import", "demo")
        self.write(self.tree / "b.txt", "ours\n")
        head = self.commit(self.tree, "b: ours.", "one")
        self.engine("export", "demo")
        self.write(self.upstream / "b.txt", "theirs\n")
        self.commit(self.upstream, "Release 2.", tag="v2")

        self.engine("rebase", "demo", "v2", ok=False)
        self.engine("rebase", "demo", "--abort")
        self.assertEqual(self.git(self.tree, "rev-parse", "HEAD"), head)
        self.assertEqual(self.pin()["commit"], self.v1)
        self.assertIn("matches the series", self.engine("status"))

    def test_rebase_needs_exported_work(self):
        self.two_topics()
        self.write(self.tree / "b.txt", "b\nmore\n")
        self.commit(self.tree, "b: more.", "one")
        self.assertIn("not exported", self.engine("rebase", "demo", "v1", ok=False))


if __name__ == "__main__":
    unittest.main()

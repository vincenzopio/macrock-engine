"""extract-deps.py ARCHIVE DEST: copy the x86_64 GnuTLS/FreeType dylib closure.

Wine dlopens GnuTLS and FreeType at runtime. Only those two libraries and the dylibs they
load are taken from the pinned Gcenx archive; anything outside the archive besides the
system libraries is an error.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

PREFIX = "Wine Devel.app/Contents/Resources/wine/lib/"
ROOTS = ["libgnutls.30.dylib", "libfreetype.6.dylib", "libgnutls.dylib", "libfreetype.dylib"]


def main():
    archive, destination = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        staging = pathlib.Path(temp)
        with tarfile.open(archive, "r|xz") as tf:
            for member in tf:
                name = member.name
                if os.path.dirname(name) + "/" != PREFIX or not name.endswith(".dylib"):
                    continue
                output = staging / pathlib.Path(name).name
                if member.issym():
                    if pathlib.Path(member.linkname).name != member.linkname:
                        raise SystemExit("unsafe symlink in dependency archive: " + name)
                    output.symlink_to(member.linkname)
                elif member.isfile():
                    output.write_bytes(tf.extractfile(member).read())
                    output.chmod(0o755)
        needed, pending = set(), list(ROOTS)
        while pending:
            name = pending.pop()
            if name in needed:
                continue
            needed.add(name)
            library = staging / name
            if library.is_symlink():
                pending.append(library.readlink().name)
            for line in subprocess.check_output(["otool", "-L", str(library)], text=True).splitlines()[2:]:
                dependency = line.strip().split(" (")[0]
                if dependency.startswith(("@loader_path/", "@rpath/")):
                    pending.append(pathlib.Path(dependency).name)
                elif not dependency.startswith(("/System/", "/usr/lib/")):
                    raise SystemExit("unexpected dependency: " + dependency)
        for name in sorted(needed):
            source, target = staging / name, destination / name
            if source.is_symlink():
                target.symlink_to(source.readlink())
            else:
                shutil.copy2(source, target)


if __name__ == "__main__":
    main()

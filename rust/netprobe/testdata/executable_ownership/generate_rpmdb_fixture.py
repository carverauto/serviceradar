#!/usr/bin/env python3
"""Writes rpmdb.sqlite, a synthetic rpm sqlite-backend database for the netprobe
executable-ownership tests.

Every package, path and version here is invented. The file is produced by SQLite itself
(Python's sqlite3), so the test reads a file written by the real library, not one shaped
by the reader under test. The rpm headers follow the rpm header format: a big-endian
index count and data length, 16-byte index entries, then the data store.

The database exercises:
  * a package whose header overflows one 4 KiB page (example-tools, 600 files);
  * enough rows that the table b-tree has an interior root page;
  * FILEMODES filtering (configuration and documentation files are not executable);
  * a package with no files (gpg-pubkey).

It also writes rpmdb_wal.sqlite and rpmdb_wal.sqlite-wal: a WAL-mode database copied
while its last transaction (example-late) was committed only to the write-ahead log, so
the reader must apply WAL frames to see it. exampled was checkpointed into the main file
before that.

Regenerate with: python3 generate_rpmdb_fixture.py (from this directory).
"""

import os
import shutil
import sqlite3
import struct

TAG_NAME, TAG_VERSION, TAG_RELEASE, TAG_ARCH = 1000, 1001, 1002, 1022
TAG_FILEMODES, TAG_DIRINDEXES, TAG_BASENAMES, TAG_DIRNAMES = 1030, 1116, 1117, 1118
TYPE_INT16, TYPE_INT32, TYPE_STRING, TYPE_STRING_ARRAY = 3, 4, 6, 8
ALIGN = {TYPE_INT16: 2, TYPE_INT32: 4}

EXEC = 0o100755
DATA = 0o100644


def header(name, version, release, arch, files):
    dirnames = []
    basenames, dirindexes, modes = [], [], []
    for path, mode in files:
        directory, base = path.rsplit("/", 1)
        directory += "/"
        if directory not in dirnames:
            dirnames.append(directory)
        basenames.append(base)
        dirindexes.append(dirnames.index(directory))
        modes.append(mode)

    entries = [
        (TAG_NAME, TYPE_STRING, name.encode() + b"\0", 1),
        (TAG_VERSION, TYPE_STRING, version.encode() + b"\0", 1),
        (TAG_RELEASE, TYPE_STRING, release.encode() + b"\0", 1),
        (TAG_ARCH, TYPE_STRING, arch.encode() + b"\0", 1),
    ]
    if files:
        entries += [
            (TAG_FILEMODES, TYPE_INT16, b"".join(struct.pack(">H", m) for m in modes), len(modes)),
            (TAG_DIRINDEXES, TYPE_INT32, b"".join(struct.pack(">I", i) for i in dirindexes), len(dirindexes)),
            (TAG_BASENAMES, TYPE_STRING_ARRAY, b"".join(b.encode() + b"\0" for b in basenames), len(basenames)),
            (TAG_DIRNAMES, TYPE_STRING_ARRAY, b"".join(d.encode() + b"\0" for d in dirnames), len(dirnames)),
        ]

    index, store = b"", b""
    for tag, kind, data, count in entries:
        align = ALIGN.get(kind, 1)
        store += b"\0" * ((-len(store)) % align)
        index += struct.pack(">IIII", tag, kind, len(store), count)
        store += data
    return struct.pack(">II", len(entries), len(store)) + index + store


def packages():
    yield header("gpg-pubkey", "0a1b2c3d", "5f000000", "(none)", [])
    yield header(
        "exampled",
        "2.4.1",
        "3.el9",
        "x86_64",
        [
            ("/usr/sbin/exampled", EXEC),
            ("/etc/exampled/exampled.conf", DATA),
            ("/usr/share/doc/exampled/README", DATA),
        ],
    )
    tools = [(f"/usr/libexec/example-tools/tool-{n:03d}", EXEC) for n in range(600)]
    yield header("example-tools", "1.0.0", "1.el9", "x86_64", tools)
    for n in range(60):
        yield header(
            f"example-filler-{n:02d}",
            "0.1",
            "1.el9",
            "noarch",
            [(f"/usr/share/example-filler-{n:02d}/data.txt", DATA)],
        )


CREATE = "CREATE TABLE 'Packages' (hnum INTEGER PRIMARY KEY AUTOINCREMENT,blob BLOB NOT NULL)"


def write_wal_pair(directory):
    scratch = os.path.join(directory, "rpmdb_wal.scratch.sqlite")
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(scratch + suffix):
            os.remove(scratch + suffix)
    db = sqlite3.connect(scratch)
    db.execute("PRAGMA page_size = 4096")
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA wal_autocheckpoint = 0")
    db.execute(CREATE)
    db.execute(
        "INSERT INTO Packages (blob) VALUES (?)",
        (header("exampled", "2.4.1", "3.el9", "x86_64", [("/usr/sbin/exampled", EXEC)]),),
    )
    db.commit()
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.execute(
        "INSERT INTO Packages (blob) VALUES (?)",
        (header("example-late", "3.0.0", "1.el9", "x86_64", [("/usr/bin/examplelate", EXEC)]),),
    )
    db.commit()
    # Copy while the connection is open: closing would checkpoint and delete the log.
    shutil.copyfile(scratch, os.path.join(directory, "rpmdb_wal.sqlite"))
    shutil.copyfile(scratch + "-wal", os.path.join(directory, "rpmdb_wal.sqlite-wal"))
    db.close()
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(scratch + suffix):
            os.remove(scratch + suffix)


def main():
    directory = os.path.dirname(os.path.abspath(__file__))
    write_wal_pair(directory)
    out = os.path.join(directory, "rpmdb.sqlite")
    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.execute("PRAGMA page_size = 4096")
    db.execute(CREATE)
    db.executemany("INSERT INTO Packages (blob) VALUES (?)", ((blob,) for blob in packages()))
    db.commit()
    db.execute("VACUUM")
    db.close()


if __name__ == "__main__":
    main()

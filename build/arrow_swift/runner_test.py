import io
from pathlib import Path
import tarfile
import tempfile
import unittest

from build.arrow_swift.swift_regression_test import extract_source


class SourceArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "source.tar.gz"
        self.destination = self.root / "extracted"

    def write_archive(self, entries):
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, kind in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                if kind == tarfile.REGTYPE:
                    data = b"synthetic package source\n"
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
                else:
                    member.linkname = "../outside"
                    archive.addfile(member)

    def test_regular_files_are_staged(self):
        self.write_archive([("source", tarfile.DIRTYPE), ("source/Package.swift", tarfile.REGTYPE)])
        extract_source(self.archive, self.destination, "source", ("Package.swift", "link", "pipe"))
        self.assertEqual((self.destination / "Package.swift").read_bytes(), b"synthetic package source\n")

    def test_unselected_language_trees_are_not_extracted(self):
        self.write_archive([("source/Package.swift", tarfile.REGTYPE),
                            ("source/java/link", tarfile.SYMTYPE)])
        extract_source(self.archive, self.destination, "source", ("Package.swift",))
        self.assertTrue((self.destination / "Package.swift").is_file())
        self.assertFalse((self.destination / "java").exists())

    def test_unsafe_archives_fail_before_writing(self):
        cases = [("source/../outside", tarfile.REGTYPE), ("/outside", tarfile.REGTYPE),
                 ("other/file", tarfile.REGTYPE), ("source/link", tarfile.SYMTYPE),
                 ("source/link", tarfile.LNKTYPE), ("source/pipe", tarfile.FIFOTYPE),
                 ("source\\file", tarfile.REGTYPE), ("source/Package.swift", tarfile.REGTYPE)]
        for entry in cases:
            with self.subTest(entry=entry):
                self.write_archive([("source/Package.swift", tarfile.REGTYPE), entry])
                with self.assertRaises(ValueError):
                    extract_source(self.archive, self.destination, "source", ("Package.swift", "link", "pipe"))
                self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()

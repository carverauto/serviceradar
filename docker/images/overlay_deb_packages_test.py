"""Exercise the Ubuntu zstd package payload through the real overlay CLI."""

import io
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest

ZSTD = sys.argv.pop(1)


class OverlayDebPackagesTest(unittest.TestCase):
    def test_zstd_package_extracts_executable_and_relative_symlink(self):
        content = b"synthetic runtime executable\n"
        tar_bytes = io.BytesIO()
        with tarfile.open(fileobj=tar_bytes, mode="w") as archive:
            member = tarfile.TarInfo("usr/bin/example-tool")
            member.size = len(content)
            member.mode = 0o755
            archive.addfile(member, io.BytesIO(content))
            link = tarfile.TarInfo("usr/bin/example-tool-alias")
            link.type = tarfile.SYMTYPE
            link.linkname = "example-tool"
            archive.addfile(link)
        compressed = subprocess.run(
            [ZSTD, "--stdout"], input=tar_bytes.getvalue(), capture_output=True, check=True
        ).stdout

        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            package = root / "example.deb"
            with package.open("wb") as output:
                output.write(b"!<arch>\n")
                for name, data in [("debian-binary", b"2.0\n"), ("data.tar.zst", compressed)]:
                    header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
                    output.write(header.encode("ascii"))
                    output.write(data)
                    if len(data) % 2:
                        output.write(b"\n")
            subprocess.run(
                [
                    sys.executable,
                    str(pathlib.Path(__file__).with_name("overlay_deb_packages.py")),
                    "--zstd",
                    ZSTD,
                    str(root),
                    str(package),
                ],
                check=True,
            )
            binary = root / "usr/bin/example-tool"
            self.assertEqual(binary.read_bytes(), content)
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
            alias = binary.with_name("example-tool-alias")
            self.assertTrue(alias.is_symlink())
            self.assertEqual(alias.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()

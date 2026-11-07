# Vendored third-party source tarballs

This directory is a Bazel `--distdir` (wired in `//.bazelrc`). Before Bazel downloads an
`http_archive`, it looks here for a file whose basename matches the URL's basename. It uses
the file only if the file's sha256 equals the archive's pinned `sha256`. A file that does not
match is ignored, so nothing here can change what is built.

Only tarballs whose upstream cannot be reached reliably from CI belong here.

| File | Pinned by | Upstream | Why vendored |
| --- | --- | --- | --- |
| `apache-age-1.7.0-src.tar.gz` | `age_src` in `MODULE.bazel` | `archive.apache.org/dist/age/PG18/1.7.0/` | `downloads.apache.org` keeps only the current release, and `archive.apache.org` refuses connections from the build cluster. This broke the v1.5.0 release publish. |

When a pinned version changes, replace the file with the new upstream tarball, check that its
sha256 matches the new pin, and update this table. Delete the file when nothing pins it any more,
for example once the AGE image is retired.

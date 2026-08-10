load(
    "//private:mix_archive_build.bzl",
    _mix_archive_build = "mix_archive_build",
)

def mix_archive_build(**kwargs):
    return _mix_archive_build(**kwargs)

load(
    "//private:escript_archive.bzl",
    _escript_archive = "escript_archive",
)
load(
    "//private:escript_flat.bzl",
    _escript_flat = "escript_flat",
)

def escript_archive(**kwargs):
    _escript_archive(**kwargs)

def escript_flat(**kwargs):
    _escript_flat(**kwargs)

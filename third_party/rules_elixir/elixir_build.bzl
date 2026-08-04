load(
    "//private:elixir_build.bzl",
    _elixir_build = "elixir_build",
    _elixir_external = "elixir_external",
)

def elixir_build(**kwargs):
    return _elixir_build(**kwargs)

def elixir_external(**kwargs):
    return _elixir_external(**kwargs)

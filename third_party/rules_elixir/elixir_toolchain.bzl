load(
    "//private:elixir_toolchain.bzl",
    _elixir_toolchain = "elixir_toolchain",
)

def elixir_toolchain(**kwargs):
    return _elixir_toolchain(**kwargs)

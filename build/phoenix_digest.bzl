"""phoenix_digest with this repository's Phoenix on the code path.

The rule is @rules_elixir//:phoenix_digest.bzl. It calls Phoenix.Digester.compile/3, so the
phoenix application has to be staged for it -- but the hub repository name is the consumer's
choice, fixed when it calls hex_packages_extension, so the ruleset cannot default it.
"""

load("@rules_elixir//:phoenix_digest.bzl", _phoenix_digest = "phoenix_digest")

def phoenix_digest(**kwargs):
    if "deps" not in kwargs:
        kwargs["deps"] = ["@hexpm//:phoenix"]
    return _phoenix_digest(**kwargs)

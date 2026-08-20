"""elixir_release, plus the ERTS this repository ships.

The rule is @rules_elixir//:elixir_release.bzl. The two constants below cannot live there:
they select on this repository's config_setting and resolve to this repository's OTP archive.

They exist because `mix release` takes the ERTS to ship and the OTP applications to copy from
one place -- Mix derives the second from :code.root_dir() of the first -- so a release
assembled by an amd64 executor ships amd64 ERTS unless it is told otherwise. `include_erts:`
as a path is the only seam Mix offers, and it splits them exactly. On amd64 both resolve to
None and the rule falls back to `include_erts: true`, which is what the build has always done.
"""

load("@rules_elixir//:elixir_release.bzl", _elixir_release = "elixir_release")

SHIPPED_ERTS_OTP_ROOT = select({
    Label("//build/platforms:target_linux_arm64"): "@otp_28_1_linux_arm64//:otp_root",
    "//conditions:default": None,
})

SHIPPED_ERTS_ROOT_MARKER = select({
    Label("//build/platforms:target_linux_arm64"): "@otp_28_1_linux_arm64//:root_marker",
    "//conditions:default": None,
})

def elixir_release(**kwargs):
    return _elixir_release(**kwargs)

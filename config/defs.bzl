"""Build rules for the ServiceRadar environment configuration system.

The committed `.textproto` instance is the authored ground truth; this macro compiles it to
a binary message that every language loads. That split exists because NO implementation can
parse text format: only Go reads textproto natively, `prost` does not, and Elixir's
`:protobuf` has no parser at any version (0.17.0 added `Protobuf.Text`, encode-only).
Performing the parse once in a declared, cached build action removes the requirement from
all three implementations at once.

See openspec/changes/add-unified-config-and-secret-managers/design.md, Decision 2.
"""

_MESSAGE = "serviceradar.config.v1.EnvironmentConfig"

# The sections a component can declare on its own. Decision 6: a target that declares
# `//config/environments:ci_database` PHYSICALLY CANNOT SEE the NATS configuration, because it
# is not in that target's runfiles. Least privilege enforced by the sandbox rather than by
# discipline, and readable at the target definition instead of inferred from a global union.
_SECTIONS = [
    "database",
    "nats",
    "core",
    "dgraph",
]

_EXTRACT_SECTION = Label("//config/tools/rust:extract_section")

def environment_config(name, src, visibility = None):
    """Compiles a committed .textproto environment instance to a binary message.

    Args:
      name: base name; produces `<name>_binpb` and the file `<name>.binpb`.
      src: the committed `.textproto` instance.
      visibility: visibility for the generated target.

    protoc exits non-zero on an unknown field or a type mismatch, so a malformed instance
    fails the BUILD rather than reaching a loader. That is the first of the three checks on
    an instance; the rule set (semantic constraints) and the round-trip test are the others.
    """
    native.genrule(
        name = name + "_binpb",
        srcs = [src, "//config/proto:config_proto_src"],
        outs = [name + ".binpb"],
        cmd = ("$(execpath @bazel_tools//tools/proto:protoc) -I. " +
               "--encode=" + _MESSAGE + " " +
               "$(execpath //config/proto:config_proto_src) " +
               "< $(execpath " + src + ") > $@"),
        tools = ["@bazel_tools//tools/proto:protoc"],
        visibility = visibility,
    )

    # The binary decoded back to text. Two checks read it and neither can be done against the
    # committed source: the round-trip test compares what the artifact actually contains against
    # what was authored, and the credential-shape check needs every field that is PRESENT, with
    # no comments -- scanning the source would let a credential hide in a field the scanner did
    # not know to look at, and would flag the word "password" in a comment warning against them.
    for section in _SECTIONS:
        native.genrule(
            name = name + "_" + section,
            srcs = [name + ".binpb"],
            outs = [name + "." + section + ".binpb"],
            cmd = ("$(execpath " + str(_EXTRACT_SECTION) + ") " + section +
                   " $(execpath " + name + ".binpb) $@"),
            tools = [_EXTRACT_SECTION],
            visibility = visibility,
        )

    native.genrule(
        name = name + "_canonical",
        srcs = [name + ".binpb", "//config/proto:config_proto_src"],
        outs = [name + ".canonical.textproto"],
        cmd = ("$(execpath @bazel_tools//tools/proto:protoc) -I. " +
               "--decode=" + _MESSAGE + " " +
               "$(execpath //config/proto:config_proto_src) " +
               "< $(execpath " + name + ".binpb) > $@"),
        tools = ["@bazel_tools//tools/proto:protoc"],
        visibility = visibility,
    )

_RULESET_MESSAGE = "serviceradar.config.v1.RuleSet"

def rule_set(name, src, visibility = None):
    """Compiles the committed rule set .textproto to a binary message.

    Same mechanism and same reason as environment_config: no implementation parses text
    format, so protoc does it once in a declared, cached action. An unknown predicate, a
    misspelled field or a malformed parameter fails the BUILD.
    """
    native.genrule(
        name = name + "_binpb",
        srcs = [src, "//config/proto:config_proto_src", "//config/proto:rules_proto_src"],
        outs = [name + ".binpb"],
        cmd = ("$(execpath @bazel_tools//tools/proto:protoc) -I. " +
               "--encode=" + _RULESET_MESSAGE + " " +
               "$(execpath //config/proto:rules_proto_src) " +
               "< $(execpath " + src + ") > $@"),
        tools = ["@bazel_tools//tools/proto:protoc"],
        visibility = visibility,
    )

_FIXTURES_MESSAGE = "serviceradar.config.v1.FixtureSet"

def fixture_set(name, src, visibility = None):
    """Compiles committed conformance fixtures to a binary message."""
    native.genrule(
        name = name + "_binpb",
        srcs = [src, "//config/proto:config_proto_src", "//config/proto:rules_proto_src"],
        outs = [name + ".binpb"],
        cmd = ("$(execpath @bazel_tools//tools/proto:protoc) -I. " +
               "--encode=" + _FIXTURES_MESSAGE + " " +
               "$(execpath //config/proto:rules_proto_src) " +
               "< $(execpath " + src + ") > $@"),
        tools = ["@bazel_tools//tools/proto:protoc"],
        visibility = visibility,
    )

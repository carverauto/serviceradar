# generated file - DO NOT EDIT

load("@rules_ocaml//toolchain:profiles.bzl",
     "toolchain_profile_selector",
     "ocaml_toolchain_profile")

COMPILE_WARNINGS = []
COMPILE_OPTIONS  = [
    # "-keep-locs",
    # "-short-paths",
    # "-strict-formats",
    # "-strict-sequence"
    # "-noassert",
]

LINK_WARNINGS    = [] ## "-w", "A-4-42-41-48-70"] # dune
LINK_OPTIONS  = [
    # "-bin-annot",               # dune
    # "-annot",                   # dune
    # "-no-alias-deps",           # dune
    # "-noassert",
    # "-short-paths",
    # "-strict-formats",
    # "-strict-sequence"          # dune
]
# dune exe native:
# -bin-annot -annot -strict-sequence -keep-locs -no-alias-deps -w A-4-42-41-48-70 -g
# dune exe vm:
# -bin-annot -annot -strict-sequence -keep-locs -no-alias-deps -w A-4-42-41-48-70 -g

ocaml_toolchain_profile(
    name         = "vm_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS,
    link_opts    = LINK_OPTIONS + LINK_WARNINGS
)

ocaml_toolchain_profile(
    name         = "vm_dev_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS,
    link_opts    = LINK_OPTIONS + LINK_WARNINGS,
)

ocaml_toolchain_profile(
    name         = "vm_dbg_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS,
    link_opts    = LINK_OPTIONS + LINK_WARNINGS
)

ocaml_toolchain_profile(
    name         = "vm_opt_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS + [],
    link_opts    = LINK_OPTIONS + LINK_WARNINGS + []
)

ocaml_toolchain_profile(
    name         = "sys_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS,
    link_opts    = LINK_OPTIONS + LINK_WARNINGS
)

ocaml_toolchain_profile(
    name         = "sys_dev_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS,
    link_opts    = LINK_OPTIONS + LINK_WARNINGS
)

ocaml_toolchain_profile(
    name         = "sys_dbg_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS,
    link_opts    = LINK_OPTIONS + LINK_WARNINGS,
)

ocaml_toolchain_profile(
    name         = "sys_opt_profile",
    compile_opts = COMPILE_OPTIONS + COMPILE_WARNINGS + [],
    link_opts    = LINK_OPTIONS + LINK_WARNINGS + []
)

##########
toolchain_profile_selector(
    name                    = "sys-dev",
    profile                 = ":sys_dev_profile",
    target_host_constraints = ["@rules_ocaml//platform/executor:sys"],
    constraints             = [":fastbuild_mode"],
)

##########
toolchain_profile_selector(
    name                    = "sys-dbg",
    profile                 = ":sys_dbg_profile",
    target_host_constraints = ["@rules_ocaml//platform/executor:sys"],
    constraints             = [":dbg_mode"],
)

##########
toolchain_profile_selector(
    name                    = "sys-opt",
    profile                 = ":sys_opt_profile",
    target_host_constraints = ["@rules_ocaml//platform/executor:sys"],
    constraints             = [":opt_mode"],
)

##########
toolchain_profile_selector(
    name                    = "vm-dev",
    profile                 = ":vm_dev_profile",
    target_host_constraints = ["@rules_ocaml//platform/executor:vm"],
    constraints             = [":fastbuild_mode"],
)

##########
toolchain_profile_selector(
    name                    = "vm-dbg",
    profile                 = ":vm_dbg_profile",
    target_host_constraints = ["@rules_ocaml//platform/executor:vm"],
    constraints             = [":dbg_mode"],
)

##########
toolchain_profile_selector(
    name                    = "vm-opt",
    profile                 = ":vm_opt_profile",
    target_host_constraints = ["@rules_ocaml//platform/executor:vm"],
    constraints             = [":opt_mode"],
)

##########
toolchain_profile_selector(
    name                        = "default-dev",
    profile                     = ":sys_dev_profile",
    constraints                 = [":fastbuild_mode"],
)

##########
toolchain_profile_selector(
    name                        = "default-dbg",
    profile                     = ":sys_dbg_profile",
    constraints                 = [":dbg_mode"],
)

##########
toolchain_profile_selector(
    name                        = "default-opt",
    profile                     = ":sys_opt_profile",
    constraints                 = [":opt_mode"],
)

################################################################
config_setting(
    name = "dbg_mode",
    values = {"compilation_mode": "dbg"},
)

config_setting(
    name = "fastbuild_mode",
    values = {"compilation_mode": "fastbuild"},
)

config_setting(
    name = "opt_mode",
    values = {"compilation_mode": "opt"},
)


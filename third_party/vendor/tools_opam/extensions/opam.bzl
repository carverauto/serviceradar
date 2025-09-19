load("@bazel_skylib//lib:collections.bzl", "collections")
load("//extensions/opam:opam_toolchain_xdg.bzl", "config_xdg_toolchain")
load("//extensions/opam:opam_toolchain_local.bzl", "config_local_toolchain")
load("//extensions/opam:opam_toolchain_global.bzl", "config_global_toolchain")
load("//extensions/opam:opam_toolchain_opam.bzl", "config_opam_toolchain")
load("//extensions/opam:opam_dep.bzl", "opam_dep", "OBAZL_PKGS")
load("//extensions/opam:opam_repo.bzl", "opam_repo",
     "utop_get_paths")
load("//extensions/dbg:dbg_repo.bzl", "dbg_repo")
load("//extensions/ocaml:ocaml_repo.bzl", "ocaml_repo")
load("//extensions/utop:utop_repo.bzl", "utop_repo")
load("//extensions/opam:opam_ops.bzl",
     "opam_install_pkg",
     "print_cwd", "print_tree")

## RELEASE CHECKLIST
## - set version ids of bazel_deps in _build_config_tool
## - remove dev registry from bazel build cmd

################################################################
def _build_config_tool(mctx, toolchain, debug, verbosity):
    if debug > 1: print("_build_config_tool")
    bazel = mctx.which("bazel")
    # print("BAZEL: %s" % bazel)
    # print("CWD: %s" % print_cwd(mctx))

    # cmd = ["pwd"]
    # res = mctx.execute(cmd, quiet = False)
    # stdout = res.stdout.strip()
    # print("\nPWD:\n%s" % stdout)
    # cmd = ["tree", ".", "-a", "-L", "2"]
    # mctx.execute(cmd, quiet = False)

    # we have to turn this into a bazel repo
    # in order to run bazel in it:
    mctx.file("REPO.bazel", content = "")

    # cmd = ["tree", "-aL", "1", "../../external"]
    # mctx.execute(cmd, quiet = False)

    mctx.file("MODULE.bazel",

              content = """
module(
    name = "config_tool",
    version = "0.0.0",
 )

bazel_dep(name = "tools_opam",  version="1.0.0.beta.1")
bazel_dep(name = "rules_ocaml", version = "3.0.0.beta.1")
               """
              )

    HOME = mctx.getenv("HOME")

    # only for opam install
    if toolchain == "opam":
        cmd = [bazel,
               "--ignore_all_rc_files",
               # WARNING: a different output base than the
               # one set by the opam build cmd will cause
               # a new bazel server to run
               # "--output_base=../.config_base",
               # "--output_user_root=../.config_user",
               "build",
               "--symlink_prefix=config-",
               "--lockfile_mode=off",
               "--ignore_dev_dependency",
               ## testing:
               # "--registry=file://{}/obazl/registry".format(HOME),
               "--registry=https://raw.githubusercontent.com/obazl/registry/main/",
               "--registry=https://bcr.bazel.build",
               "--subcommands=pretty_print",
               "--compilation_mode", "fastbuild",
               "@tools_opam//extensions/config"]
    else:
        cmd = ["bazel",
               # "--output_base=../.config_base",
               # "--output_user_root=../.config_user",
               "build",
               # "--symlink_prefix=config-",
               # testing:
               # "--registry=file://{}/obazl/registry".format(HOME),
               "--registry=https://raw.githubusercontent.com/obazl/registry/main/",
               "--registry=https://bcr.bazel.build",
               "--lockfile_mode=off",
               "--ignore_dev_dependency",
               "--compilation_mode", "fastbuild",
               "@tools_opam//extensions/config"]
    if verbosity > 1:
        cmd.append("--subcommands=pretty_print")

    mctx.report_progress("Building @tools_opam//extensions/config")
    # print("\nRunning cfg tool build:\n%s" % cmd)
    res = mctx.execute(cmd,
                       environment = {
                           "HOME": "../.cache",
                           "XDG_CACHE_HOME": "../.cache"},
                       quiet = (verbosity < 1))
    if res.return_code == 0:
        # stdout = res.stdout.strip()
        # print("\nSTDOUT:\n%s" % stdout)
        # stderr = res.stderr.strip()
        # print("\nSTDERR:\n%s" % stderr)
        # print("\nEND\n")
        pass
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

    # cmd = ["pwd"]
    # mctx.execute(cmd, quiet = False)
    # stdout = res.stderr.strip()
    # print("\nPWD:\n%s" % stderr)
    # cmd = ["tree", "..", "-a", "-L", "2"]
    # mctx.execute(cmd, quiet = False)

    ## FIXME: run bazel cquery to get this?
    p1 = "bazel-bin/external/tools_opam+/extensions/config/config"

    config_pkg_tool = mctx.path(p1)
    # this is the path on modextwd, we need the real path
    config_pkg_tool = config_pkg_tool.realpath
    # print("CONFIG TOOL %s" % config_pkg_tool)

    return config_pkg_tool

##################################
def _throw_cmd_error(cmd, r):
    print("cmd: %s" % cmd)
    print("stdout: {stdout}".format(stdout= r.stdout))
    print("stderr: {stderr}".format(stderr= r.stderr))
    fail("cmd failure.")

# Set to false to see debug messages

##################################
# def _ocamlfind_deps(mctx, ocamlfind, switch, pkg, version, debug, verbosity):
#     if debug > 0: print("_ocamlfind_deps: %s" % pkg)

#     cmd = [
#         ocamlfind,
#         "query",
#         "-predicates",
#         "ppx_driver",
#         "-p-format",
#         "-recursive",
#         pkg
#     ]
#     res = mctx.execute(cmd, quiet = (verbosity < 1))

#     if res.return_code == 0:
#         deps = res.stdout.strip()
#         deps = deps.splitlines()
#         # print("ocamlfind query ok, deps: %s" % deps)
#     elif res.return_code == 2:
#         print("findlib pkg not found: " + pkg)
#         return None
#     else:
#         print("cmd: %s" % cmd)
#         print("rc: %s" % res.return_code)
#         print("stdout: %s" % res.stdout)
#         print("stderr: %s" % res.stderr)
#         fail("cmd failure")

#     return deps

################################################################
## extension
##  use:
##   bazel_dep(name = "tools_opam", version = "...")
##   opam = use_extension("@tools_opam//extensions:opam.bzl")
##   opam.dep(name = "ounit2", version = "...")
##   use_repo(opam, "opam.ounit2")
##
## here 'opam.dep' is a "tag function" that calls a repo
## rule to create repo @opam.ounit2

#### EXTENSION IMPL ####
def _opam_ext_impl(mctx):
    # print("OPAM EXTENSION running")

    # get globals (version id etc). from root module
    opam_version  = "2.3.0"
    ocaml_version = "5.3.0"
    obazl_pfx     = "opam."
    toolchain     = "xdg"
    debug         = 0
    opam_verbosity = 0
    verbosity     = 0
    root_module   = None
    config_file   = "obazl.opamrc"
    direct_deps   = []
    dev_deps      = []
    opamtgt       = None
    utop          = None
    dbg           = None
    ocaml         = None
    ocamlinit     = None

    for m in mctx.modules:
        if m.is_root:
            # print("ROOT mod: %s" % m.name)
            root_module = m.name

            ## FIXME:
            ## always config opam, opam.ocamlsdk, opam.stublibs
            ## even if root module does not use opam.deps

            if m.tags.dbg:
                if mctx.is_dev_dependency(m.tags.dbg[0]):
                    dbg = True
                else:
                    fail("@dbg only available as a dev dependency")
            if m.tags.ocaml:
                if mctx.is_dev_dependency(m.tags.ocaml[0]):
                    ocaml = True
                else:
                    fail("@ocaml only available as a dev dependency")
            if m.tags.opam:
                if mctx.is_dev_dependency(m.tags.opam[0]):
                    opamtgt = True
                else:
                    fail("@opam only available as a dev dependency")
            if m.tags.utop:
                utop = m.tags.utop[0].version
                ocamlinit    = m.tags.utop[0].ocamlinit
                if mctx.is_dev_dependency(m.tags.utop[0]):
                    dev_deps.extend(
                        {"utop": utop})
            for cfg in m.tags.deps:
                config_file = cfg._opam_config_file
                if mctx.is_dev_dependency(cfg):
                    dev_deps.extend(cfg.pkgs)
                else:
                    # env var overrides toolchain param
                    ltc = mctx.getenv("OBAZL_USE_LOCAL_TC")
                    if debug > 1: print("OBAZL LTC: %s" % ltc)
                    if ltc:
                        toolchain = ltc
                        print("toolchain override: %s" % toolchain)
                    else:
                        toolchain = cfg.toolchain
                    opam_version = cfg.opam_version
                    ocaml_version = cfg.ocaml_version
                    # if mctx.is_dev_dependency(cfg):
                    #     dev_deps.extend(cfg.pkgs)
                    # else:
                    if "utop" in cfg.pkgs.keys():
                        fail("""

'utop' is a dev dependency. To use it put this in your MODULE.bazel file:

opam_dev = use_extension("@tools_opam//extensions:opam.bzl",
                         "opam", dev_dependency = True)
opam_dev.utop(version = "2.15.0-1",
              ocamlinit = ".config/ocamlinit") # ocamlinit is optional
use_repo(opam_dev, utop="opam.utop")
                        """)
                    direct_deps.extend(cfg.pkgs)
                    # subdeps.extend(cfg.indirect_deps)
                    debug      = cfg.debug
                    opam_verbosity = cfg.opam_verbosity
                    verbosity = cfg.verbosity
        else:
            # non-root modules
            for cfg in m.tags.deps:
                if mctx.is_dev_dependency(cfg):
                    dev_deps.extend(cfg.pkgs)
                else:
                    if "utop" in cfg.pkgs.keys():
                        fail("""
'utop' is a dev dependency. To use it:
opam_dev = use_extension("@tools_opam//extensions:opam.bzl",
                         "opam", dev_dependency = True)
opam_dev.utop(version = "2.15.0-1",
              ocamlinit = ".config/ocamlinit")
use_repo(opam_dev, utop="opam.utop")

                        """)
                    direct_deps.extend(cfg.pkgs)
        #         subdeps.extend(cfg.indirect_deps)
        #         if debug > 0:
        #             print("MOD: %s" % config.name)
        #             print("DEPS: %s" % config.direct_deps)
        #             print("SUBDEPS: %s" % config.indirect_deps)

    ## detect whether or not we are in an opam install env.
    if mctx.getenv("OBAZL_OPAM_ENV"):
        toolchain = "opam"

    config_pkg_tool = _build_config_tool(mctx, toolchain,
                                         debug, verbosity)
    if debug > 0: print("CONFIG TOOL: %s" % config_pkg_tool)

    if "opam" in direct_deps:
        fail("""

'opam' is a dev-dependency but you have listed it as a direct
opam package dependency.  To enable 'bazel run @opam', do this:

opam_dev = use_extension("@tools_opam//extensions:opam.bzl",
                         "opam", dev_dependency = True)
opam_dev.ocaml()
use_repo(opam_dev, "ocaml")

        """)

    if "ocamldebug" in direct_deps:
        fail("""

'ocamldebug' is a dev-dependency but you have listed it as a direct
opam package dependency.  To enable 'bazel run @dbg', do this:

opam_dev = use_extension("@tools_opam//extensions:opam.bzl",
                         "opam", dev_dependency = True)
opam_dev.dbg()
use_repo(opam_dev, "dbg")

        """)

    # stublibs is special. it's always configured,
    # but only as an indirect dep unless user explicitly
    # lists it in pkgs. In that case it will be listed as
    # a direct dep and the user must also import it
    # with use_repo.
    if "stublibs" in direct_deps:
        stublibs_direct   = True
        stublibs_indirect = False
    elif "stublibs" in dev_deps:
        stublibs_indirect = True
        stublibs_direct   = False
    else:
        stublibs_indirect = False
        stublibs_direct   = False
    # print("DEPS %s" % direct_deps)
    for pkg in OBAZL_PKGS: # e.g. dynlink, str, unix
        if pkg in direct_deps:
            direct_deps.remove(pkg)
        if pkg in dev_deps:
            dev_deps.remove(pkg)
    # print("NEWDEPS %s" % direct_deps)
    # print_tree(mctx)
    # x = mctx.read("MODULE.bazel")
    # print(x)
    # fail("xxxxxxxxxxxxxxxxa")

    switch = None
    deps = None # will be set by config fn
    if toolchain == "local":
        (opam, opamroot, sdklib, switch,
         ocaml_version, deps) = config_local_toolchain(
             mctx,
             ocaml_version,
             direct_deps + dev_deps,
             debug, opam_verbosity, verbosity)
        if debug > 0: print("SDKLIB: %s" % sdklib)
    elif toolchain == "global":
        if debug > 0: print("TC GLOBAL")
        (opam, opamroot, sdklib, switch,
         ocaml_version, deps) = config_global_toolchain(
             mctx,
             ocaml_version,
             direct_deps,
             dev_deps,
             debug, opam_verbosity,
             verbosity)
        if debug > 0: print("SDKLIB: %s" % sdklib)
    elif toolchain == "xdg":
        if debug > 0: print("TC XDG")
        (opam, opamroot, sdklib, switch,
         ocaml_version, deps) = config_xdg_toolchain(
             mctx,
             opam_version,
             ocaml_version,
             direct_deps + dev_deps,
             debug,
             opam_verbosity,
             verbosity)
    elif  toolchain == "opam":
        (opam, opamroot, sdklib, switch,
         ocaml_version, deps) = config_opam_toolchain(
             mctx,
             ocaml_version,
             direct_deps,
             debug, opam_verbosity, verbosity)
    else:
        fail("unrecognized toolchain: %s" % toolchain)
    # if debug > 0: print(print_cwd(mctx))

    opampath = str(opam)
    rootpath = str(opamroot)
    sdklib = str(sdklib)

    # always configure opam, ocamlsdk & stublibs
    opam_dep(name="{}ocamlsdk".format(obazl_pfx),
             opam = opampath,
             switch = switch,
             root   = rootpath,
             sdklib = sdklib,
             ocaml_version = ocaml_version,
             obazl_pfx = obazl_pfx,
             config_tool = str(config_pkg_tool),
             debug = debug,
             verbosity = verbosity)
    opam_dep(name="{}stublibs".format(obazl_pfx),
             opam = opampath,
             switch = switch,
             root   = rootpath,
             sdklib = sdklib,
             ocaml_version = ocaml_version,
             obazl_pfx = obazl_pfx,
             config_tool = str(config_pkg_tool),
             debug = debug,
             verbosity = verbosity)

    ## @opam gets a special repo
    if opamtgt:
        opam_repo(name = "opam",
                  # toolchain     = toolchain,
                  root_module   = root_module,
                  opam_bin      = opampath,
                  opam_version  = opam_version,
                  opam_root     = rootpath,
                  config_file   = config_file,
                  switch_id     = switch,
                  # ocaml_version = ocaml_version,
                  # pkgs          = deps,
                  debug         = debug,
                  verbosity     = verbosity,
                  opam_verbosity= opam_verbosity)

    # sdk tool: ocamldebug
    if dbg:
        dbg_repo(name = "dbg",
                 root_module   = root_module,
                 opam_bin      = opampath,
                 opam_root     = rootpath,
                 switch_id     = switch,
                 dbg_version   = ocaml_version,
                 # ini_file      = ini_file,
                 # ld_lib_path   = ld_lib_path,
                 debug         = debug,
                 verbosity     = verbosity,
                 opam_verbosity= opam_verbosity)

    # sdk tool: ocaml repl
    if ocaml:
        ocaml_repo(name = "ocaml",
                   root_module   = root_module,
                   opam_bin      = opampath,
                   opam_root     = rootpath,
                   switch_id     = switch,
                   ocaml_version   = ocaml_version,
                   # ini_file      = ini_file,
                   # ld_lib_path   = ld_lib_path,
                   debug         = debug,
                   verbosity     = verbosity,
                   opam_verbosity= opam_verbosity)

    if utop:
        # @utop gets a special repo
        deps.remove("utop")
        utop_bin, stublibs, ocaml_stublibs = utop_get_paths(
            mctx, opampath, rootpath, switch,
            debug, verbosity, opam_verbosity)
        ld_lib_path = stublibs + ":" + ocaml_stublibs
        utop_repo(name = "{}utop".format(obazl_pfx),
                  # toolchain     = toolchain,
                  root_module   = root_module,
                  utop_bin      = utop_bin,
                  ocamlinit     = ocamlinit,
                  ld_lib_path   = ld_lib_path,
                  utop_version  = utop,
                  opam_bin      = opampath,
                  opam_root     = rootpath,
                  switch_id     = switch,
                  # ocaml_version = ocaml_version,
                  # pkgs          = deps,
                  debug         = debug,
                  verbosity     = verbosity)
    ## configure all deps
    # for now, ignore versions
    # if verbosity > 0: print("\n\tRegistering repos for opam pkgs")

    tot = len(deps)
    for i, pkg in enumerate(deps):
        ## FIXME: for ocaml >= 5, dynlink etc. not toplevel pkgs?
        if pkg in OBAZL_PKGS: # e.g. dynlink, str, unix
            # pkg = pkg
            continue # not installable (part of SDK)
        elif pkg == "stublibs":
            ## already installed
            continue
        else:
            pkg = "{pfx}{pkg}".format(pfx=obazl_pfx, pkg=pkg)
        if verbosity > 1: print(
            "\n  Registering repo {n} of {tot}: {p}".format(
                n=i+1, tot=tot, p=pkg))
        opam_dep(name=pkg,
                 install = False,
                 opam = opampath,
                 switch = switch,
                 root   = rootpath,
                 sdklib = sdklib,
                 ocaml_version = ocaml_version,
                 obazl_pfx = obazl_pfx,
                 config_tool = str(config_pkg_tool),
                 debug = debug,
                 verbosity = verbosity
                 )
        # if debug > 1: print("done")

    rmdirects = ["opam.ocamlsdk"]
    # if stublibs_direct:
    #     rmdirects.append("opam.stublibs")
    for dep in direct_deps:
        rmdirects.append("{}{}".format(obazl_pfx, dep))

    devdeps = []
    if stublibs_indirect:
        devdeps.append("opam.stublibs")
    if dbg:
        devdeps.append("dbg")
    if ocaml:
        devdeps.append("ocaml")
    if opamtgt:
        devdeps.append("opam")

    for dep in dev_deps:
        if dep == "utop":
            devdeps.append("{}utop".format(obazl_pfx))
        else:
            devdeps.append("{}{}".format(obazl_pfx, dep))
    return mctx.extension_metadata(
        root_module_direct_deps = rmdirects,
        root_module_direct_dev_deps = devdeps
    )

##############################
opam = module_extension(
    doc = """
This module extension enables seamless integration of opam dependencies into the Bazel environment.
    """,
    implementation = _opam_ext_impl,
    tag_classes = {
        "dbg": tag_class(
            doc = """The `dbg` method (tag class) configures ocamldebug.""",
            attrs = {
                "version": attr.string(),
            }
        ),
        "ocaml": tag_class(
            doc = """The `ocaml` method (tag class) configures the ocaml repl.""",
            attrs = {
                "version": attr.string(),
            }
        ),
        "opam": tag_class(
            doc = """The `opam` method (tag class) configures the @opam run target.""",
            attrs = {
                "version": attr.string(),
            }
        ),
        "utop": tag_class(
            doc = """The `utop` method (tag class) configures utop.""",
            attrs = {
                "version": attr.string(),
                "ocamlinit": attr.label(),
            }
        ),

        "deps": tag_class(
            doc = """
The `deps` method (tag class) runs code that

1. ensures the selected opam switch is properly configured, and
2. generates a Bazel repository for each opam package listed in the `pkgs` attribute

The Bazel repository for package `pkg` will be named `opam.pkg`, so in
your `BUILD.bazel` files you refer to it as `@opam.pkg//lib`.

The Bazel repositories are lazily evaluated. The method will
__configure__ a repository for every package in the complete
dependency graph - that is, generate Bazel files for it and register
it with Bazel. But repositories are not ``materialized'' (evaluated)
until needed. So your project might have many opam dependencies, but
if you build a target that only depends on one, then only that one
repository will actually be constructed and used.

.Usage example
[%collapsible]
====
[source="starlark",title="MODULE.bazel"]
----
bazel_dep(name = "tools_opam", version = "1.0.0")
opam = use_extension("@tools_opam//extensions:opam.bzl", "opam")
opam.deps(pkgs = {"ounit2": "2.2.7"})
use_repo(opam, "opam.ounit2")
use_repo(opam, "opam", "opam.ocamlsdk")                               <1>
register_toolchains("@opam.ocamlsdk//toolchain/selectors/local:all")  <2>
register_toolchains("@opam.ocamlsdk//toolchain/profiles:all")         <2>
----
<1> Modules `opam` and `opam.ocamlsdk` are always implicitly configured.
<2> The toolchains defined by module `opam.ocamlsdk` must always be registered.

[source="starlark",title="BUILD.bazel"]
----
ocaml_module(name="A", struct="a.ml", deps=["@opam.ounit2//lib"],...)
----
====

            """,
            attrs = {
                "toolchain": attr.string(
                    doc = "opam toolchain: xdg, local, or global",
                    mandatory = False,
                    default = "xdg",
                    values  = ["local", "global", "xdg",
                               # future: "xdg_local"
                             ]
                ),
                "opam_version": attr.string(
                    doc = "Version of opam to use for xdg toolchain",
                    mandatory = False,
                    default = "2.3.0"
                ),
                "ocaml_version": attr.string(
                    doc = "Version of OCaml",
                    mandatory = False,
                    default = "5.3.0"
                ),
                "pkgs": attr.string_dict(
                    doc = "List of opam pkg Ids",
                    # mandatory = True,
                  allow_empty = False
                ),
                "_opam_config_file": attr.label(
                    default = "obazl.opamrc"
                ),
                "debug"     : attr.int(
                    doc = "Debug level",
                    default = 0
                ),
                "verbosity" : attr.int(
                    doc = "Verbosity level",
                    default = 0),
                "opam_verbosity": attr.int(
                    doc = "Verbosity level for opam commands",
                    default = 0
                ),
            }
        )
    }
)

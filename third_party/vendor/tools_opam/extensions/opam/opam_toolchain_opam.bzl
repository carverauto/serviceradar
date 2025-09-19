load("opam_ops.bzl",
     "file_exists",
     "is_pkg_installed",
     "opam_install_pkg",
     "run_cmd")
load("opam_utils.bzl", "get_sdk_root")

load("//extensions:colors.bzl",
     "CCRED", "CCYEL", "CCYELBGH", "CCRESET")

DEFAULT_PATH = "/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin"

################
def _opam_path(switch_pfx):
    return "{}:{}".format(switch_pfx, DEFAULT_PATH)

################################
def config_opam_toolchain(mctx,
                          ocaml_version,
                          direct_deps,
                          debug, opam_verbosity, verbosity):
    if verbosity > 0: print("\n  Configuring opam toolchain")

    opambin = mctx.getenv("OPAMBIN")
    if not opambin:
        opambin = mctx.which("opam")
    if debug > 0: print("opambin: %s" % opambin)
    if verbosity > 0:
        cmd = [opambin, "--version"]
        res = mctx.execute(cmd)
        if res.return_code == 0:
            print("\n  Opam version: %s" % res.stdout.strip())
        else:
            fail("Unable to run opam")

    OPAMROOT = mctx.getenv("OPAMROOT")
    # cmd = [opambin, "var", "root"]
    # res = mctx.execute(cmd)
    # if res.return_code == 0:
    #     OPAMROOT = res.stdout.strip()
    # else:
    #     print("cmd: %s" % cmd)
    #     print("stdout: {stdout}".format(stdout= res.stdout))
    #     print("stderr: {stderr}".format(stderr= res.stderr))
    #     fail("cmd failure.")
    if debug > 0: print("OPAMROOT: %s" % OPAMROOT)

    switch_id = mctx.getenv("OPAMSWITCH")
    # cmd = [opambin, "var", "switch"]
    # res = mctx.execute(cmd)
    # if res.return_code == 0:
    #     switch_id = res.stdout.strip()
    # else:
    #     print("cmd: %s" % cmd)
    #     print("stdout: {stdout}".format(stdout= res.stdout))
    #     print("stderr: {stderr}".format(stderr= res.stderr))
    #     fail("cmd failure.")
    if verbosity > 0: print("\n  Switch id: %s" % switch_id)

    ocaml_version = None
    ## check effective ocaml version vs. requested version
    cmd = [opambin, "var", "ocaml:version"]
    res = mctx.execute(cmd)
    if res.return_code == 0:
        ocaml_version = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if debug > 0: print("effective ocaml version: %s" % ocaml_version)

#     if ocaml_version:
#         if effective_ocaml_version != ocaml_version:
#             print("""\n\n
# {c}WARNING{reset}: You have requested the global switch with OCaml version {v1},
# but the current switch (Id: '{id}') uses OCaml version {v2}.

# For now I will proceed with the build using the current switch.

# To eliminate this warning, either

# \ta) remove the 'ocaml_version' attribute,
# \tb) set the 'ocaml_version' attribute to {v2}, or
# \tc) use 'opam switch' to change the current switch to one that uses OCaml version {v1}.
#             \n\n""".format(
#                 c=CCYELBGH, reset=CCRESET,
#                 v1=ocaml_version, id=switch_id,
#                 v2=effective_ocaml_version
#             ))
#         # else:
#         #     effective == requested
#     else:  # ocaml_version omitted
#         ocaml_version = effective_ocaml_version

    switch_pfx = mctx.getenv("OPAM_SWITCH_PREFIX")
    # cmd = [opambin, "var", "prefix"]
    # res = mctx.execute(cmd)
    # if res.return_code == 0:
    #     switch_pfx = res.stdout.strip()
    # else:
    #     print("cmd: %s" % cmd)
    #     print("stdout: {stdout}".format(stdout= res.stdout))
    #     print("stderr: {stderr}".format(stderr= res.stderr))
    #     fail("cmd failure.")
    if debug > 0: print("switch_pfx: %s" % switch_pfx)

    SDKROOT = get_sdk_root(mctx, opambin, switch_pfx, debug)
    SDKLIB = SDKROOT + "/lib"
    if debug > 0: print("SDKLIB: %s" % SDKLIB)
    SDKBIN = SDKROOT + "/bin"
    # SDKBIN = SDKLIB.removesuffix("/lib") + "/bin"
    if debug > 0: print("SDKBIN: %s" % SDKBIN)

    cmd = [opambin, "var", "lib"] # , "--switch", switch]
    res = mctx.execute(cmd)
    if res.return_code == 0:
        switch_lib = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if debug > 0: print("switch_lib: %s" % switch_lib)

    ## in an opam install env, we depend on opam to have
    ## already installed all dependencies.

    # get all installed pkgs
    cmd = ["ls", "-1", "{}".format(switch_lib)]
    deps = run_cmd(mctx, cmd) ## , verbosity=0)
    deps = deps.splitlines()
    torem = []
    for dep in deps:
        if dep.endswith(".conf"):
            torem.append(dep)
    for x in torem:
        deps.remove(x)

    return (opambin, OPAMROOT, SDKLIB,
            str(switch_id),
            ocaml_version,
            deps)


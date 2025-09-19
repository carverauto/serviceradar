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
def config_global_toolchain(mctx,
                            ocaml_version,
                            direct_deps,
                            dev_deps,
                            debug, opam_verbosity, verbosity):
    if verbosity > 0: print("\n  Configuring global toolchain")

    opambin = mctx.which("opam")
    if verbosity > 0:
        cmd = [opambin, "--version"]
        res = mctx.execute(cmd)
        if res.return_code == 0:
            print("\n  Opam version: %s" % res.stdout.strip())
        else:
            fail("Unable to run opam")

    cmd = [opambin, "var", "root"]
    res = mctx.execute(cmd)
    if res.return_code == 0:
        OPAMROOT = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if debug > 0: print("OPAMROOT: %s" % OPAMROOT)

    cmd = [opambin, "var", "switch"]
    res = mctx.execute(cmd)
    if res.return_code == 0:
        switch_id = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if verbosity > 0: print("\n  Switch id: %s" % switch_id)

    effective_ocaml_version = None
    ## check effective ocaml version vs. requested version
    cmd = [opambin, "var", "ocaml:version"]
    res = mctx.execute(cmd)
    if res.return_code == 0:
        effective_ocaml_version = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if debug > 0: print("effective ocaml version: %s" % effective_ocaml_version)

    if ocaml_version:
        if effective_ocaml_version != ocaml_version:
            print("""\n\n
{c}WARNING{reset}: You have requested the global switch with OCaml version {v1},
but the current switch (Id: '{id}') uses OCaml version {v2}.

For now I will proceed with the build using the current switch.

To eliminate this warning, either

\ta) remove the 'ocaml_version' attribute,
\tb) set the 'ocaml_version' attribute to {v2}, or
\tc) use 'opam switch' to change the current switch to one that uses OCaml version {v1}.
            \n\n""".format(
                c=CCYELBGH, reset=CCRESET,
                v1=ocaml_version, id=switch_id,
                v2=effective_ocaml_version
            ))
        # else:
        #     effective == requested
    else:  # ocaml_version omitted
        ocaml_version = effective_ocaml_version

    cmd = [opambin, "var", "prefix"]
    res = mctx.execute(cmd)
    if res.return_code == 0:
        switch_pfx = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
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

    tot = len(direct_deps)
    for i, pkg in enumerate(direct_deps):
        pkg_path = "{}/{}".format(switch_lib, pkg)
        if not file_exists(mctx, pkg_path):
            force = mctx.getenv("OBAZL_FORCE_INSTALL")
            if force:
                if verbosity > 1: print("Installing pkg '{}'".format(pkg))

                opam_install_pkg(mctx,
                                 opambin,
                                 pkg,
                                 switch_id,
                                 switch_pfx,
                                 SDKBIN,
                                 OPAMROOT,
                                 i, tot,
                                 debug, opam_verbosity,
                                 verbosity)
            else:
                print("""

{c}ERROR{reset}: A required package, {exc}{pkg}{reset}, is not installed in the current switch (Id: {exc}{id}{reset}).
The build cannot proceed until missing packages are installed.
To remedy this tragic situation, you have two equally heartbreaking options:

a) Install all missing packages manually, and then rerun the build; or

b) Tell me to install all missing packages by setting the env variable OBAZL_FORCE_INSTALL; for example:

    {exc}$  OBAZL_FORCE_INSTALL=1 bazel build //pkg:target{reset}

                """.format(c=CCRED, reset=CCRESET, pkg=pkg,
                           id = switch_id,
                           exc=CCYEL))
                fail("Missing package: %s" % pkg)

    tot = len(dev_deps)
    for i, pkg in enumerate(dev_deps):
        pkg_path = "{}/{}".format(switch_lib, pkg)
        if not file_exists(mctx, pkg_path):
            force = mctx.getenv("OBAZL_FORCE_INSTALL")
            if force:
                if verbosity > 1: print("Installing dev pkg '{}'".format(pkg))

                opam_install_pkg(mctx,
                                 opambin,
                                 pkg,
                                 switch_id,
                                 switch_pfx,
                                 SDKBIN,
                                 OPAMROOT,
                                 i, tot,
                                 debug, opam_verbosity,
                                 verbosity)
            else:
                print("""

{c}ERROR{reset}: Package {exc}{pkg}{reset} is required in a dev environment, but is not installed in the current switch (Id: {exc}{id}{reset}).
The build cannot proceed until missing packages are installed.
To remedy this tragic situation, you have three equally heartbreaking options:

a) Run the build with --ignore_dev_dependency;

b) Install all missing packages manually, and then rerun the build; or

c) Tell me to install all missing packages by setting the env variable OBAZL_FORCE_INSTALL; for example:

    {exc}$  OBAZL_FORCE_INSTALL=1 bazel build //pkg:target{reset}

                """.format(c=CCRED, reset=CCRESET, pkg=pkg,
                           id = switch_id,
                           exc=CCYEL))
                fail("Missing package: %s" % pkg)

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


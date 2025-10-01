load("opam_ops.bzl",
     "opam_install_pkg",
     "is_pkg_installed",
     "file_exists", "run_cmd", "print_cwd", "print_tree")
load("//extensions/opam:opam_checksums.bzl", "sha256")
load("//extensions:colors.bzl",
     "CCRED", "CCYEL", "CCYELBGH", "CCRESET")

arch_map = {
    "x86": "i686",
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64_be": "arm64",
    "aarch64": "arm64",

    #ppcle|ppc64le) ARCH="ppc64le";;
    #s390x) ARCH="s390x";;
    # armv5*|armv6*|earmv6*|armv7*|earmv7*| "armhf"
    "armv8b": "armhf",
    "armv8l": "armhf"
}

os_map = {
    "mac os x": "macos",
    "linux": "linux"
}

################
def _install_override_repository(mctx, opambin, opam_root, verbosity, opam_verbosity):
    overrides_rel = "extensions/opam/overrides_repo"
    overrides_path = mctx.path(overrides_rel)
    if not overrides_path.exists:
        return

    repo_parent = opam_root + "/srql_repos"
    repo_dir = repo_parent + "/overrides_repo"

    run_cmd(mctx, ["mkdir", "-p", repo_parent], verbosity=verbosity)
    run_cmd(mctx, ["rm", "-rf", repo_dir], verbosity=verbosity)
    run_cmd(mctx, ["cp", "-R", str(overrides_path), repo_parent], verbosity=verbosity)

    repo_url = "file://" + repo_dir
    env = {"OBAZL_NO_BWRAP": "1"}

    add_cmd = [
        opambin,
        "repository",
        "add",
        "srql-overrides",
        repo_url,
        "--root",
        opam_root,
        "--dont-select",
        "--priority=0",
    ]
    res = mctx.execute(add_cmd, environment = env, quiet = (opam_verbosity < 1))
    if res.return_code != 0:
        if "already registered" in res.stderr or "already exists" in res.stderr:
            set_cmd = [
                opambin,
                "repository",
                "set-url",
                "srql-overrides",
                repo_url,
                "--root",
                opam_root,
            ]
            res2 = mctx.execute(set_cmd, environment = env, quiet = (opam_verbosity < 1))
            if res2.return_code != 0:
                print("cmd: %s" % set_cmd)
                print("rc: %s" % res2.return_code)
                print("stdout: %s" % res2.stdout)
                print("stderr: %s" % res2.stderr)
                fail("cmd failure")
        else:
            print("cmd: %s" % add_cmd)
            print("rc: %s" % res.return_code)
            print("stdout: %s" % res.stdout)
            print("stderr: %s" % res.stderr)
            fail("cmd failure")

    update_cmd = [
        opambin,
        "update",
        "srql-overrides",
        "--root",
        opam_root,
    ]
    res = mctx.execute(update_cmd, environment = env, quiet = (opam_verbosity < 1))
    if res.return_code != 0:
        print("cmd: %s" % update_cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

################
def _get_xdg_ctx(ctx, debug, verbosity):

    xdg = ctx.getenv("XDG_DATA_HOME")
    if xdg:
        return xdg + "/obazl/opam"
    else:
        home = ctx.getenv("HOME")
        return home + "/.local/share/obazl/opam"

################
def _install_opam(mctx, XDG_OPAM_BINDIR, opam_version, verbosity):
    if verbosity > 0: print("\n  mkdir %s" % XDG_OPAM_BINDIR)
    cmd = ["mkdir", "-vp", XDG_OPAM_BINDIR]
    run_cmd(mctx, cmd)

    #### download opam
    OPAM_BIN_URL_BASE='https://github.com/ocaml/opam/releases/download'
    # tag = "2.3.0"
    arch = arch_map[mctx.os.arch]
    os   = os_map[mctx.os.name]

    OPAM_BIN="opam-{TAG}-{ARCH}-{OS}".format(
        TAG=opam_version,
        ARCH=arch,
        OS=os
    )
    OPAM_BIN_URL="{BASE}/{TAG}/{BIN}".format(
        BASE=OPAM_BIN_URL_BASE,
        TAG=opam_version,
        BIN=OPAM_BIN
    )

    SHA256 = sha256[OPAM_BIN]

    if verbosity > 0: print("\n  Downloading %s" % OPAM_BIN_URL)
    mctx.report_progress("Downloading: %s" % OPAM_BIN_URL)
    mctx.download(
        url = OPAM_BIN_URL,
        output = "./bin/opam", # .format(OPAM_BIN),
        executable = True,
        sha256 = SHA256
    )

    cmd = ["cp", "-v", "./bin/opam", XDG_OPAM_BINDIR]
    run_cmd(mctx, cmd)

    opambin = mctx.path("{}/opam".format(XDG_OPAM_BINDIR))
    if not opambin.exists:
        print_tree(mctx, dir=XDG_OPAM_BINDIR)
        fail("Cannot find Opam executable in XDG: %s" % opambin)
    else:
        return opambin

################
def _init_opam(mctx, opambin, opam_version, OPAMROOT,
               verbosity, opam_verbosity):

    cmd = ["mkdir", "-vp", OPAMROOT]

    # print("OPAM ROOT PATH: %s" % OPAMROOT)

    cmd = [opambin,
           "init",
           "--root={}".format(OPAMROOT),
           "--bare",
           "--no-setup", # don't update shell stuff
           "--no-opamrc",
           # "--no" # use OPAMNO instead
           ]

    if verbosity > 0: print("\n  Initializing Opam:\n\t%s" % cmd)
    mctx.report_progress("""
{c}INFO{reset}: Initializing OPAM {v} root at {r}
    """.format(c = CCYEL, reset = CCRESET,
               v = opam_version, r = OPAMROOT)
                         )
    env = {"OBAZL_NO_BWRAP": "1", "OPAMNO": "true"}
    res = mctx.execute(cmd,
                       environment = env,
                       quiet = (opam_verbosity < 1))
    if res.return_code != 0:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

    _install_override_repository(
        mctx = mctx,
        opambin = opambin,
        opam_root = OPAMROOT,
        verbosity = verbosity,
        opam_verbosity = opam_verbosity,
    )

################
def _create_switch(mctx, opambin, opam_version,
                   OPAMROOT, switch_id,
                   opam_verbosity, verbosity):

    base_cmd = [opambin,
                "switch",
                "create",
                str(switch_id),
                str(switch_id), ## compiler version
                "--root={}".format(OPAMROOT)]

    verbosity_flag = []
    if opam_verbosity > 1:
        s = "-"
        for i in range(1, opam_verbosity):
            s = s + "v"
        verbosity_flag = [s]

    cmd_disable = base_cmd + ["--disable-sandboxing"] + verbosity_flag
    cmd_enable = base_cmd + verbosity_flag

    if verbosity > 0: print("\n  Creating XDG switch:\n\t%s" % cmd_disable)

    mctx.report_progress("""
{c}INFO{reset}: Creating opam switch {s} with OCaml version {v}
      in opam {o} root: {r}""".format(c = CCYEL, reset = CCRESET,
               s = switch_id, v = switch_id,
               o = opam_version, r = OPAMROOT))
    env = {
        "OBAZL_NO_BWRAP": "1",
        "PATH": "/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin",
    }
    res = mctx.execute(cmd_disable,
                       environment = env,
                       quiet = (opam_verbosity < 1))
    if res.return_code != 0 and "unknown option '--disable-sandboxing'" in res.stderr:
        if verbosity > 0 or opam_verbosity:
            print("  Retrying switch creation without '--disable-sandboxing'; flag unsupported by this opam version.")
            print("\t%s" % cmd_enable)
        res = mctx.execute(cmd_enable,
                           environment = env,
                           quiet = (opam_verbosity < 1))
        cmd_used = cmd_enable
    else:
        cmd_used = cmd_disable

    if res.return_code != 0:
        if res.return_code != 2: # already installed
            fail("opam switch create failed; cmd=%s rc=%s\nstdout:%s\nstderr:%s" % (
                cmd_used,
                res.return_code,
                res.stdout,
                res.stderr,
            ))

    ocaml_version = None

    return switch_id, ocaml_version

################
def config_xdg_toolchain(mctx,
                         opam_version,
                         ocaml_version,
                         pkgs,
                         debug,
                         opam_verbosity, verbosity):

    XDG_OPAM_CTX = _get_xdg_ctx(mctx, debug, verbosity)
    if verbosity > 0:
        print("\n  Configuring XDG toolchain in %s" % XDG_OPAM_CTX)

    #### make Bazel aware that this dir is to be preserved?
    mctx.file("REPO.bazel", content = "")

    XDG_OPAM_BINDIR = "{}/{}/bin".format(
        XDG_OPAM_CTX, opam_version
    )
    opambin = XDG_OPAM_BINDIR + "/opam"

    # cmd = ["file", "-E", "-b", "xxx{}".format(opambin)]
    # check = run_cmd(mctx, cmd) #, verbosity=1)
    # print("check opam binary: '%s'" % check)

    if not file_exists(mctx, opambin):
        opambin = _install_opam(mctx, XDG_OPAM_BINDIR,
                                opam_version, verbosity)

    if verbosity > 0:
        cmd = [opambin, "--version"]
        res = mctx.execute(cmd, environment = {"OBAZL_NO_BWRAP": "1"})
        if res.return_code == 0:
            print("\n  Opam version: %s" % res.stdout.strip())
        else:
            print("cmd: %s" % cmd)
            print("stdout: {stdout}".format(stdout= res.stdout))
            print("stderr: {stderr}".format(stderr= res.stderr))
            fail("Opam cmd failure.")

    OPAMROOT = "{}/{}/root".format(
        XDG_OPAM_CTX, opam_version
    )
    # cmd = ["file", "-b", "{}".format(OPAMROOT)]
    # check = run_cmd(mctx, cmd) #, verbosity=1)
    # print("check root: '%s'" % check)
    # if check != "directory":

    if not file_exists(mctx, OPAMROOT):
        _init_opam(mctx, opambin, opam_version, OPAMROOT,
                   verbosity, opam_verbosity)

    if ocaml_version:
        switch_id = ocaml_version
        if not file_exists(mctx, "{}/{}".format(OPAMROOT, switch_id)):
            (switch_id,
             ocaml_version) = _create_switch(mctx, opambin,
                                             opam_version,
                                             OPAMROOT,
                                             ocaml_version, # switch_id,
                                             opam_verbosity,
                                             verbosity)
        # else:
            # found switch in xdg env
    else:
        if debug > 0: print("\nNo ocaml_version specified")
        # no ocaml_version specified, use default
        cmd = ["opam", "var", "sys-ocaml-version",
               "--root", OPAMROOT]
        res = mctx.execute(cmd, environment = {"OBAZL_NO_BWRAP": "1"})
                           # environment = {
                           #     "PATH": "/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin"
                           # },
                           # quiet = (opam_verbosity < 1))
        if res.return_code == 0:
            ocaml_version = res.stdout.strip()
            switch_id = ocaml_version
            if debug > 0: print("\nsys-ocaml-version: %s" % ocaml_version)
        else:
            print("cmd: %s" % cmd)
            print("stdout: {stdout}".format(stdout= res.stdout))
            print("stderr: {stderr}".format(stderr= res.stderr))
            fail("opam cmd failure.")

        if not file_exists(mctx, "{}/{}".format(OPAMROOT, ocaml_version)):
            (switch_id,
             ocaml_version) = _create_switch(mctx, opambin,
                                             opam_version, OPAMROOT,
                                             ocaml_version,
                                             opam_verbosity,
                                             verbosity)

    cmd = [opambin, "var", "prefix", "--root", OPAMROOT,
           "--switch", switch_id]
    res = mctx.execute(cmd, environment = {"OBAZL_NO_BWRAP": "1"})
    if res.return_code == 0:
        switch_pfx = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if verbosity > 0: print("\n  Switch prefix: %s" % switch_pfx)

    cmd = [opambin, "var", "bin", "--root", OPAMROOT,
           "--switch", switch_id]
    res = mctx.execute(cmd, environment = {"OBAZL_NO_BWRAP": "1"})
    if res.return_code == 0:
        switch_bin = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("stdout: {stdout}".format(stdout= res.stdout))
        print("stderr: {stderr}".format(stderr= res.stderr))
        fail("cmd failure.")
    if debug > 0: print("\nswitch bin: %s" % switch_bin)

    SDKBIN = switch_bin

    tot = len(pkgs)
    for i,pkg in enumerate(pkgs):
        if not is_pkg_installed(mctx, opambin, pkg,
                                OPAMROOT, ocaml_version):
            if verbosity > 1: print("\nInstalling pkg '{}'".format(pkg))
            opam_install_pkg(mctx,
                             opambin,
                             pkg,
                             switch_id,
                             switch_pfx,
                             SDKBIN,
                             OPAMROOT,
                             i+1, tot,
                             debug, opam_verbosity, verbosity)

    # get all installed pkgs
    cmd = [opambin,
           "var", "lib",
           "--switch", str(ocaml_version),
           "--root", "{}".format(str(OPAMROOT)),
          "--yes"]
    switch_lib = None
    res = mctx.execute(cmd,
                       environment = {"OBAZL_NO_BWRAP": "1"}) # , quiet = (verbosity < 1))
    if res.return_code == 0:
        switch_lib = res.stdout.strip()
    else:
            print("cmd: %s" % cmd)
            print("rc: %s" % res.return_code)
            print("stdout: %s" % res.stdout)
            print("stderr: %s" % res.stderr)
            fail("cmd failure")

    if debug > 1: print("\nswitch_lib: %s" % switch_lib)
    cmd = ["ls", "-1", "{}/{}/lib".format(OPAMROOT, switch_id)]
    deps = run_cmd(mctx, cmd) ## , verbosity=0)
    deps = deps.splitlines()
    torem = []
    for dep in deps:
        if dep.endswith(".conf"):
            torem.append(dep)
    for x in torem:
        deps.remove(x)

    return (str(opambin), str(OPAMROOT),
            switch_lib, # sdklib
            switch_id,
            ocaml_version, deps)

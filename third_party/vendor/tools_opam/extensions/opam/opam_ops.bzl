DEFAULT_PATH = "/bin:/usr/bin:usr/sbin"

#####################
def print_cwd(ctx):
    cmd = ["pwd"]
    res = ctx.execute(cmd, quiet = False)
    if res.return_code == 0:
        res = res.stdout.strip()
        return res
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

###############@######
def print_tree(ctx, dir=".", depth=1):
    cmd = ["tree"]
    res = ctx.execute(cmd, quiet = False)
    if res.return_code == 0:
        res = res.stdout.strip()
        return res
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

#####################
def file_exists(ctx, f, debug=0, verbosity=0):
    cmd = ["file", "-E", "-b", "{}".format(f)]
    res = ctx.execute(cmd, quiet = (verbosity < 1))
    if res.return_code == 0:
        return True
    elif res.return_code == 1:
        return False
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

#####################
def run_cmd(ctx, cmd, debug=0, verbosity=0):
    #print("RUNCMD: %s" % cmd)
    res = ctx.execute(cmd, quiet = (verbosity < 1))
    if res.return_code == 0:
        res = res.stdout.strip()
        return res
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

################
def is_pkg_installed(mctx, opambin, pkg,
                      OPAMROOT, ocaml_version):
    pkg_path = "{}/{}/lib/{}".format(
        OPAMROOT, ocaml_version, pkg)
    # print("pkg-path: %s" % pkg_path)

    if file_exists(mctx, pkg_path):
        return True
    else:
        return False

###########################
def opam_install_pkg(rctx,
                     opam_path,
                     pkg,
                     switch,
                     switch_pfx,
                     sdk_bin,
                     root,
                     n, tot,
                     debug, opam_verbosity, verbosity):

    the_path = "{}:{}/bin:{}".format(
        sdk_bin, switch_pfx, DEFAULT_PATH)
    if debug > 0: print("\nPATH: %s" % the_path)

    # cmd = ["which", "ocaml"]
    # res = rctx.execute(cmd,
    #                    environment = {
    #                        "PATH":  the_path,
    #                        "OPAM_USER_PATH_RO": the_path
    #                    },
    #                    quiet = (verbosity < 1))
    # if res.return_code == 0:
    #     print("which ocaml: %s" % res.stdout.strip())
    # else:
    #     print("cmd: %s" % cmd)
    #     print("rc: %s" % res.return_code)
    #     print("stdout: %s" % res.stdout)
    #     print("stderr: %s" % res.stderr)
    #     fail("cmd failure")

    cmd = [opam_path,
           "install",
           pkg,
           "--switch", switch,
           "--root", "{}".format(root),
           "--yes"]
    if opam_verbosity > 1:
        s = "-"
        for i in range(1, opam_verbosity):
            s = s + "v"
        cmd.extend([s])

    if (verbosity > 1
        or opam_verbosity):
        print("\nInstalling pkg:\n\t%s" % cmd)
    rctx.report_progress("Installing pkg {p} ({i} of {tot})".format(p=pkg, i=n, tot=tot))

    res = rctx.execute(cmd,
                       # environment = {
                       #     "PATH":  the_path
                       # },
                       quiet = (opam_verbosity < 1))
    if res.return_code == 0:
        if debug > 0: print("pkg installed: '%s'" % pkg)
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")


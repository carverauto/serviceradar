def get_sdk_root(ctx, opambin, switch_pfx, debug):
    if debug > 0: print("\nSWITCH PFX: %s" % switch_pfx)
    syscfgpath = str(switch_pfx) + "/.opam-switch/config/ocaml-system.config"
    # print("\nCFGPATH %s" % cfgpath)
    sysconfig = ctx.path(syscfgpath)
    if sysconfig.exists:
        if debug > 0: print("\nFOUND %s" % sysconfig)
        config = ctx.read(sysconfig)
        # print(config)
        lines = config.splitlines()
        for line in lines:
            line = line.strip(" ")
            if line.startswith("path:"):
                #e.g.  path: "/opt/homebrew/bin"
                line = line.removeprefix("path:").strip(" \"")
                SDKROOT = str(line).removesuffix("/bin")
    else:
        if debug > 0: print("\nNOT FOUND ocaml-system.config")
        SDKROOT = str(switch_pfx)

    if debug > 0: print("\nSDKROOT: %s" % SDKROOT)
    return SDKROOT

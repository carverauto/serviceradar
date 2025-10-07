load("@rules_cc//cc:find_cc_toolchain.bzl",
     "find_cpp_toolchain", "use_cc_toolchain")

load("@rules_ocaml//build:providers.bzl",
     "OCamlArchiveProvider",
     "OCamlDepsProvider",
     "OCamlModuleProvider",
     "OCamlSignatureProvider")

def _ocamlcmt_aspect_impl(target, ctx):
    print("ocamlcmt_aspect")

    tc = ctx.toolchains["@rules_ocaml//toolchain/type:std"]

    if ctx.attr._t == "cmt":
        if OCamlModuleProvider in target:
            cmt = target[OutputGroupInfo].cmt.to_list()[0]
            inputs = [cmt]
            inpath = cmt.path
            outfile = ctx.actions.declare_file(cmt.basename + ".info")
        else:
            return []
    elif ctx.attr._t == "cmti":
        if OCamlModuleProvider in target:
            if target[OutputGroupInfo].cmti:
                cmti = target[OutputGroupInfo].cmti.to_list()[0]
                inputs = [cmti]
                inpath = cmti.path
                outfile = ctx.actions.declare_file(cmti.basename + ".info")
            else:
                return []
        elif OCamlSignatureProvider in target:
            inputs = [target[OCamlSignatureProvider].cmti]
            inpath = target[OCamlSignatureProvider].cmti.path
            x = target[OutputGroupInfo].cmti.to_list()[0]
            outfile = ctx.actions.declare_file(x.basename + ".info")

    ctx.actions.run_shell(
        tools      = [
            ctx.executable._ocamlcmt
            # ctx.executable._cmt
        ],
        arguments  = [
            # ocamlcmt args:
            # "-annot",
            # "-save-cmt-info",
            # "-src",
            # "-o", objinfo.path,
            inpath
        ],
        inputs = inputs,
        outputs    = [outfile],
        command    = " ".join([
            "echo;",
            "{}".format(ctx.executable._ocamlcmt.path),
            "$@",
            "| tee %s" % outfile.path,
            "echo; echo;",
        ])
    )
    ## "aspect implementations may never return DefaultInfo."
    cmtInfo = depset(direct=[outfile])
    return [OutputGroupInfo(cmtinfo = cmtInfo)]

cmt_info_aspect = aspect(
    implementation = _ocamlcmt_aspect_impl,
    attrs = {
        "_t": attr.string(default = "cmt"),
        "_ocamlcmt": attr.label(
            allow_single_file = True,
            #broken: default = "@opam.ocamlsdk//bin:ocamlcmt",
            default = "@@tools_opam++opam+opam.ocamlsdk//bin:ocamlcmt",
            executable = True,
            cfg = "exec"),
    },
    required_providers = [
        [OCamlModuleProvider],
        [OCamlSignatureProvider],
    ],
    toolchains     = ["@rules_ocaml//toolchain/type:std",
                      "@rules_ocaml//toolchain/type:profile"
                      ] + use_cc_toolchain()
)

cmti_info_aspect = aspect(
    implementation = _ocamlcmt_aspect_impl,
    attrs = {
        "_t": attr.string(default = "cmti"),
        "_ocamlcmt": attr.label(
            allow_single_file = True,
            default = "@@tools_opam++opam+opam.ocamlsdk//bin:ocamlcmt",
            executable = True,
            cfg = "exec"),
    },
    required_providers = [
        [OCamlModuleProvider],
        [OCamlSignatureProvider],
    ],
    toolchains     = ["@rules_ocaml//toolchain/type:std",
                      "@rules_ocaml//toolchain/type:profile"
                      ] + use_cc_toolchain()
)

cmt  = cmt_info_aspect
cmti = cmti_info_aspect

load("@rules_cc//cc:find_cc_toolchain.bzl",
     "find_cpp_toolchain", "use_cc_toolchain")

load("@rules_ocaml//build:providers.bzl",
     "OCamlArchiveProvider",
     "OCamlDepsProvider",
     "OCamlModuleProvider",
     "OCamlSignatureProvider")

def _ocamlobjinfo_aspect_impl(target, ctx):
    print("ocamlobjinfo_aspect")

    tc = ctx.toolchains["@rules_ocaml//toolchain/type:std"]

    if ctx.attr._t == "modinfo":
        if OCamlModuleProvider in target:
            inputs = [target[OCamlModuleProvider].struct]
            inpath = target[OCamlModuleProvider].struct.path
            x = target[OutputGroupInfo].struct.to_list()[0]
            outfile = ctx.actions.declare_file(x.basename + ".objinfo")
        else:
            pass # ?
    elif ctx.attr._t == "siginfo":
        if OCamlModuleProvider in target:
            inputs = [target[OCamlModuleProvider].cmi]
            inpath = target[OCamlModuleProvider].cmi.path
            x = target[OutputGroupInfo].sig.to_list()[0]
            outfile = ctx.actions.declare_file(x.basename + ".objinfo")
        elif OCamlSignatureProvider in target:
            inputs = [target[OCamlSignatureProvider].cmi]
            inpath = target[OCamlSignatureProvider].cmi.path
            x = target[OutputGroupInfo].cmi.to_list()[0]
            outfile = ctx.actions.declare_file(x.basename + ".objinfo")
        else:
            pass # ?
    elif ctx.attr._t == "archinfo":
        if OCamlArchiveProvider in target:
            arch = target[OCamlArchiveProvider].archive
            inputs = [arch]
            inpath = arch.path
            outfile = ctx.actions.declare_file(arch.basename + ".objinfo")

    ctx.actions.run_shell(
        tools      = [
            ctx.executable._ocamlobjinfo
            # ctx.executable._cmt
        ],
        arguments  = [
            # "-quiet",
            # "-no-approx",
            # "-no-code",
            # "-shape",
            # "-index",
            # "-decls",
            # "-null-crc",
            inpath

            # ocamlcmt args:
            # "-annot",
            # "-save-cmt-info",
            # "-src",
            # "-o", objinfo.path,
            # target[OutputGroupInfo].cmt.to_list()[0].path,
        ],
        inputs = inputs,
        outputs    = [outfile],
        command    = " ".join([
            "echo;",
            "{}".format(ctx.executable._ocamlobjinfo.path),
            "$@",
            "| tee %s" % outfile.path,
            "echo; echo;",
        ])
    )
    ## "aspect implementations may never return DefaultInfo."
    objInfo = depset(direct=[outfile])
    return [OutputGroupInfo(objinfo = objInfo)]

modinfo_aspect = aspect(
    implementation = _ocamlobjinfo_aspect_impl,
    attrs = {
        "_t": attr.string(default = "modinfo"),
        "_ocamlobjinfo": attr.label(
            allow_single_file = True,
            ## NB: apparent name errors out: "unknown repo
            ## opam.ocamlsdk could not be resolved"
            # default = "@opam.ocamlsdk//bin:ocamlobjinfo",
            default = "@@tools_opam++opam+opam.ocamlsdk//bin:ocamlobjinfo",
            executable = True,
            cfg = "exec"),
    },
    required_providers = [
        [OCamlModuleProvider],
    ],
    toolchains     = ["@rules_ocaml//toolchain/type:std",
                      "@rules_ocaml//toolchain/type:profile"
                      ] + use_cc_toolchain()
)

siginfo_aspect = aspect(
    implementation = _ocamlobjinfo_aspect_impl,
    attrs = {
        "_t": attr.string(default = "siginfo"),
        "_ocamlobjinfo": attr.label(
            allow_single_file = True,
            ## NB: apparent name errors out: "unknown repo
            ## opam.ocamlsdk could not be resolved"
            # default = "@opam.ocamlsdk//bin:ocamlobjinfo",
            default = "@@tools_opam++opam+opam.ocamlsdk//bin:ocamlobjinfo",
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

archinfo_aspect = aspect(
    implementation = _ocamlobjinfo_aspect_impl,
    attrs = {
        "_t": attr.string(default = "archinfo"),
        "_ocamlobjinfo": attr.label(
            allow_single_file = True,
            default = "@@tools_opam++opam+opam.ocamlsdk//bin:ocamlobjinfo",
            executable = True,
            cfg = "exec"),
    },
    required_providers = [
        [OCamlArchiveProvider],
    ],
    toolchains     = ["@rules_ocaml//toolchain/type:std",
                      "@rules_ocaml//toolchain/type:profile"
                      ] + use_cc_toolchain()
)

modinfo  = modinfo_aspect
siginfo  = siginfo_aspect
archinfo = archinfo_aspect


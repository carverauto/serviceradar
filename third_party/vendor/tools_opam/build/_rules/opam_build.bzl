load("@bazel_skylib//lib:paths.bzl", "paths")

load("@rules_ocaml//build:providers.bzl",
     "OcamlArchiveMarker",
     "OCamlDepsProvider",
     "OcamlExecutableMarker",
     "OCamlImportProvider",
     "OCamlLibraryProvider",
     "OCamlNsResolverProvider",
     "OCamlModuleProvider",
     "OcamlNsMarker",
     "OcamlNsSubmoduleMarker",
     "OCamlSignatureProvider",
)
# load("//build:providers.bzl",
#      "PpxExecutableMarker",
# )
################################################
def _in_transition_impl(settings, attr):

    if attr.tc == "ocamlopt":
        host = "@rules_ocaml//platform:ocamlopt.opt"
        tgt  = "@rules_ocaml//platform:sys>any"
    elif attr.tc == "ocamlc":
        host = "@rules_ocaml//platform:ocamlc.opt"
        tgt  = "@rules_ocaml//platform:vm>any"
    else:
        fail("Illegal tc: {}; options are ocamlopt, ocamlc".format(attr.tc))

    return {
        # attr.tc overrides any --tc= cmd line option
        "@rules_ocaml//toolchain": attr.tc,
        "//command_line_option:host_platform": host,
        "//command_line_option:platforms": tgt,
        "@rules_ocaml//cfg/library/linkage": attr.linkage
    }

################
_in_transition = transition(
    implementation = _in_transition_impl,
    inputs = [
        "@rules_ocaml//toolchain",
    ],
    outputs = [
        "@rules_ocaml//toolchain",
        "//command_line_option:host_platform",
        "//command_line_option:platforms",
        "@rules_ocaml//cfg/library/linkage"
    ]
)

###############
def _libs(ctx):
    libs = set()
    for dep in ctx.attr.lib:
        provider = dep[OCamlDepsProvider]
        for item in provider.archives.to_list():
            libs.add('"{}"'.format(item.path))
        for item in provider.srcs.to_list():
            libs.add('"{}"'.format(item.path))
        for item in provider.cmts.to_list():
            libs.add('"{}"'.format(item.path))
        for item in provider.cmtis.to_list():
            libs.add('"{}"'.format(item.path))

        if ctx.attr.tc == "ocamlopt":
            for item in provider.sigs.to_list():
                libs.add('"{}"'.format(item.path))
            for item in provider.structs.to_list():
                libs.add('"{}"'.format(item.path))
            for item in provider.astructs.to_list():
                libs.add('"{}"'.format(item.path))
            for item in provider.afiles.to_list():
                libs.add('"{}"'.format(item.path))
            # ofiles are contained in afiles, so no need
            # for item in provider.ofiles.to_list():
            #     libs.add('"{}"'.format(item.path))

    libs = sorted(libs)
    text = ""
    for lib in libs:
        text = text + "  " + lib + "\n"
    return text

################
def _gather_subitems(ctx, sublibs, dep, sublib):
    pkg = dep.label.package
    sublibs[sublib] = []
    provider = dep[OCamlDepsProvider]

    for item in provider.archives.to_list():
        if item.short_path.startswith(pkg):
            sublibs[sublib].append('"{}"'.format(item.path))
    for item in provider.cmts.to_list():
        if item.short_path.startswith(pkg):
            sublibs[sublib].append('"{}"'.format(item.path))
    for item in provider.cmtis.to_list():
        if item.short_path.startswith(pkg):
            sublibs[sublib].append('"{}"'.format(item.path))
    for item in provider.srcs.to_list():
        if item.short_path.startswith(pkg):
            sublibs[sublib].append('"{}"'.format(item.path))

    if ctx.attr.tc == "ocamlopt":
        for item in provider.sigs.to_list():
            if item.short_path.startswith(pkg):
                sublibs[sublib].append('"{}"'.format(item.path))
        for item in provider.structs.to_list():
            if item.short_path.startswith(pkg):
                sublibs[sublib].append('"{}"'.format(item.path))
        for item in provider.astructs.to_list():
            if item.short_path.startswith(pkg):
                sublibs[sublib].append('"{}"'.format(item.path))
        for item in provider.afiles.to_list():
            if item.short_path.startswith(pkg):
                sublibs[sublib].append('"{}"'.format(item.path))
        # ofiles are contained in afiles, so no need
        # for item in provider.ofiles.to_list():
        #     if item.short_path.startswith(pkg):
        #         sublibs[sublib].append('"{}"'.format(item.path))

##################
def _sublibs(ctx):
    sublibs = dict()
    for dep, sublib in ctx.attr.sublibs.items():
        _gather_subitems(ctx, sublibs, dep, sublib)
    # fail("SUBLIBS %s" % sublibs)

    text = ""
    for (pkg, files) in sublibs.items():
        # print("\n{}: {}\n".format(pkg, files))
        for f in files:
            text = text + "  " + f + " {{ \"{}/{} }}\n".format(
                pkg, paths.basename(f))
    return text

###############
# def _gather(ctx, libs, provider):
#     for item in provider.archives.to_list():
#         libs.add('"{}"'.format(item.path))
#     for item in provider.archives.to_list():
#         libs.add('"{}"'.format(item.path))
#     for item in provider.sigs.to_list():
#         libs.add('"{}"'.format(item.path))
#     if ctx.attr.tc == "ocamlopt":
#         for item in provider.structs.to_list():
#             libs.add('"{}"'.format(item.path))
#     for item in provider.astructs.to_list():
#         libs.add('"{}"'.format(item.path))
#     for item in provider.afiles.to_list():
#         libs.add('"{}"'.format(item.path))
#     for item in provider.srcs.to_list():
#         libs.add('"{}"'.format(item.path))
#     for item in provider.cmts.to_list():
#         libs.add('"{}"'.format(item.path))
#     for item in provider.cmtis.to_list():
#         libs.add('"{}"'.format(item.path))

###############
def _libexec(ctx):
    libs = set()
    for dep in ctx.attr.libexec:
        provider = dep[OCamlDepsProvider]
        for item in provider.cmxs.to_list():
            libs.add('"{}"'.format(item.path))
        # _gather(ctx, libs, provider)

    libs = sorted(libs)
    text = ""
    for lib in libs:
        text = text + "  " + lib + "\n"
    return text

###############
def _sublibexecs(ctx):
    sublibs = dict()
    for dep, sublib in ctx.attr.sublibexecs.items():
        pkg = dep.label.package
        sublibs[sublib] = []
        provider = dep[OCamlDepsProvider]
        for item in provider.cmxs.to_list():
            if item.short_path.startswith(pkg):
                sublibs[sublib].append('"{}"'.format(item.path))
        # _gather_subitems(ctx, sublibs, dep, sublib)

    text = ""
    for (pkg, files) in sublibs.items():
        # print("\n{}: {}\n".format(pkg, files))
        for f in files:
            text = text + "  " + f + " {{ \"{}/{} }}\n".format(
                pkg, paths.basename(f))
    return text

############################
def _opam_build_impl(ctx):

    # print("opam_build rule: %s" % ctx.label)
    tc = ctx.toolchains["@rules_ocaml//toolchain/type:std"]

    lib_files = _libs(ctx)
    sublib_files = _sublibs(ctx)

    libexec_files = _libexec(ctx)
    sublibexec_files = _sublibexecs(ctx)

    text = "\n" + lib_files + sublib_files + libexec_files + sublibexec_files
    # text = libexec_files + sublibexec_files

    inputs = ctx.files.lib + ctx.files.sublibs + ctx.files.libexec + ctx.files.sublibexecs

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ctx.outputs.out],
        progress_message = "Generating %s" % ctx.outputs.out.short_path,
        command = "echo '{}' > '{}'".format(
            text, ctx.outputs.out.path)
    )

    return DefaultInfo(files = depset([ctx.outputs.out]))

##########################
opam_build = rule(
    implementation = _opam_build_impl,
    doc = """Rule for build to OPAM.""",
    executable = False,
    attrs = dict(
        out = attr.output(
            mandatory = True
        ),
        tc  = attr.string(
            values = ["ocamlopt", "ocamlc"],
            default = "ocamlopt"
        ),
        pkg = attr.string(mandatory=True),
        bin = attr.label_list(
            providers = [OCamlDepsProvider]
        ),
        lib = attr.label_list(
            providers = [OCamlDepsProvider],
        ),
        sublibs = attr.label_keyed_string_dict(
            providers = [OCamlDepsProvider],
        ),
        libexec = attr.label_list(
            providers = [OCamlDepsProvider],
        ),
        sublibexecs = attr.label_keyed_string_dict(
            providers = [OCamlDepsProvider],
        ),
        linkage = attr.string(
            values = ["static", "shared", "none"],
            default = "none"
        ),
        # _allowlist_function_transition = attr.label(
        #     default = "@bazel_tools//tools/allowlists/function_transition_allowlist"
        # )
    ),
    cfg = _in_transition,
    toolchains = ["@rules_ocaml//toolchain/type:std"],
)

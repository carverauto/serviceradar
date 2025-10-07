load("@rules_ocaml//build/_lib:ccdeps.bzl",
     "link_ccdeps", "dump_CcInfo")

####################################
def _ccinfo_aspect_impl(target, ctx):
    print("ccinfo aspect for rule: {}".format(ctx.label))

    if CcInfo in target:
        dump_CcInfo(ctx, target[CcInfo])

        # report = report + "CC DEPS:"
        # for cc in target[CcInfo].libs:
        #     report = report + str(cc)

    return []

ccinfo = aspect(
    implementation = _ccinfo_aspect_impl,
    attr_aspects = ["deps", "ppx_codeps", "modules", "submodules"],
)

####################################
def _providers_impl(target, ctx):
    print("TARGET: %s" % target)
    for dep in target[DefaultInfo].files.to_list():
        print(dep)

    report = "REPORT "
    if CcInfo in target:
        report = report + "CC DEPS:"
        for cc in target[CcInfo].libs:
            report = report + str(cc)

    report_file = ctx.actions.declare_file("providers.txt")
    print("WRITING file: %s" % report_file.path)
    print("CONTENT: %s" % report)

    ctx.actions.write(
        report_file,
        report
    )

    return [
        OutputGroupInfo(
            providers = depset([report_file])
        )
    ]

providers = aspect(
    implementation = _providers_impl,
    attr_aspects = [],
)

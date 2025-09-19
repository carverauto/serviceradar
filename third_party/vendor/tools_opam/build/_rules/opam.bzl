def quot(s):
    return "\"" + s + "\""

def _buildfld(ctx):
    cmds = ctx.attr.build.items()
    buildcmds = []
    for (k, v) in cmds:
        cmd = []
        cmdfilter = None
        for fld in v:
            if fld.startswith("$${"):
                cmdfilter = (fld.lstrip("$$"))
                continue
            if fld.startswith("$"):
                cmd.append(fld.lstrip("$"))
            elif fld.startswith("{"):
                cmd.append(fld)
            else:
                cmd.append(quot(fld))
        if cmdfilter:
            buildcmds.append(
                {"cmd": cmd, "filter": cmdfilter}
            )
        else:
            buildcmds.append({"cmd": cmd})
    return buildcmds

def _depextsfld(ctx):
    # depexts = string_list_dict
    depexts = ctx.attr.depexts.items()
    builddepexts = []
    print(depexts)
    for (k, v) in depexts:
        depext = []
        depextfilter = None
        for fld in v:
            if fld.startswith("{"):
                depextfilter = fld
                continue
            if fld.startswith("$"):
                depext.append(fld.lstrip("$"))
            else:
                depext.append(quot(fld))
        if depextfilter:
            builddepexts.append(
                {"depext": depext, "filter": depextfilter}
            )
        else:
            builddepexts.append({"depext": depext})
    return builddepexts

def _opam_pkg_impl(ctx):

    ## generate a json file from attrs,
    ## then run mustachios to generate opam file
    opam_map = {}
    opam_map["opam_version"] = quot(ctx.attr.opam_version)
    opam_map["name"] = quot(ctx.attr.name)
    opam_map["version"] = quot(ctx.attr.version)
    opam_map["description"] = quot(quot(quot(ctx.attr.description)))
    opam_map["maintainer"] = ctx.attr.maintainer
    opam_map["authors"] = ctx.attr.authors
    #...

    # convert "[a b c] {dev}" to {"spec": [[a b c] "{dev}"]}
    opam_map["build"] = _buildfld(ctx)
    opam_map["depexts"] = _depextsfld(ctx)

    depstbl = {quot(k): v for k, v in ctx.attr.depends.items()}
    opam_map["deps"] = depstbl
    # depends: [
    #   "dune" {>= "2.7"}
    #   "ocaml" {>= "4.04.1" & < "5.1.0"}


    #...

    data_json = ctx.actions.declare_file("data.json")

    opam_map_json = json.encode_indent(opam_map)
    ctx.actions.write(
        output = data_json,
        content = opam_map_json
    )

    args = ctx.actions.args()
    args.add_all(["-t", ctx.file._template.path])
    args.add_all(["-d", data_json.path])
    args.add_all(["-o", ctx.outputs.out.path])

    ctx.actions.run(
        mnemonic = "Mustache",
        executable = ctx.file._tool,
        arguments = [args],
        inputs = depset(
            [ctx.file._template, data_json],
        ),
        outputs = [ctx.outputs.out],
    )

    return [
        DefaultInfo(files = depset([ctx.outputs.out]))
    ]


####################
opam_pkg = rule(
    implementation = _opam_pkg_impl,
    attrs = dict(
        out = attr.output(mandatory=True),
        version = attr.string(),
        opam_version = attr.string(mandatory = True),
        maintainer = attr.string_list(mandatory = True),
        authors = attr.string_list(),
        license = attr.string_list(),
        homepage = attr.string_list(),
        doc      = attr.string_list(),
        bug_reports = attr.string_list(),
        dev_repo = attr.string(),
        opam_tags = attr.string_list(),
        patches = attr.string_list(),
        substs = attr.string_list(),
        build    = attr.string_list_dict(
            # [ [ <term> { <filter> } ... ] { <filter> } ... ]
            # [
            #     ["./configure" "--prefix=%{prefix}%"]
            #     [make]
            # ]
            # or
            # [["dune" "subst"] {dev}
            # ["dune"
            #  "build"
            #  "-p"
            #  name
            #  "-j"
            #  jobs
            #  "@install"
            #  "@runtest" {with-test}
            #  "@doc" {with-doc}
            #  ]]
        ),
        install = attr.string_list_dict(
            # [ [ <term> { <filter> } ... ] { <filter> } ... ]
            # install: [
            #     ["bazel"
            #      "--bazelrc=.config/opam.bazelrc"
            #      "--nosystem_rc"
            #      "--nohome_rc"
            #      "--noworkspace_rc"
            #      "run" "opam:install"
            #      ]
            # ]
            # install: [
            #     [make "install" "LIBDIR=%{_:lib}%" "DOCDIR=%{_:doc}%"]
            #     [make "install-doc" "LIBDIR=%{_:lib}%" "DOCDIR=%{_:doc}%"]
            # ]

        ),
        build_doc = attr.string_list_dict(), # deprecated
        build_test = attr.string_list_dict(), # deprecated
        run_test = attr.string_list_dict(), # deprecated
        depends  = attr.string_dict(
            # [ <filtered-package-formula> ... ]
            # e.g.
            # depends: [
            #     "dune" {>= "2.7"}
            #     "ocaml" {>= "4.04.1" & < "5.1.0"}
            #     ...]
        ),
        depopts = attr.string_list_dict(
            # [<pkgname> { <filtered-package-formula> } ... ]:
            # e.g. depopts: ["lwt" "lwt_ppx"]
        ),
        conflicts = attr.string_list(
            # [ <filtered-package-formula> ... ]
        ),
        conflict_class = attr.string_list(
            # [ <pkgname> ... ]
        ),
        depexts = attr.string_list_dict(
            # [ [ <string> ... ] { <filter> } ... ]
            # depexts: [
            #     ["clang" "libncurses5-dev"] {os-distribution = "ubuntu"}
            #     ["clang"] {os-distribution = "debian"}
            #     ["clang" "libxml2-dev"] {os-distribution = "alpine"}
            #     ["clang"] {os-distribution = "fedora"}
            # ]
        ),
        messages = attr.string_list(
            # [ <string> { <filter> } ... ]:
        ),
        post_messages = attr.string_list(
            # [ <string> { <filter> } ... ]
        ),
        available = attr.string_list(
            # [ <filter> ]:
        ),
        flags = attr.string_list(
            # [ <ident> ... ]
        ),
        opam_features = attr.string_list_dict(
            # EXPERIMENTAL
            # [ <ident> { <pkgname> { <filtered-package-formula> } ... } { <string> } ... ]
        ),
        synopsis = attr.string(),
        description = attr.string(),
        url = attr.string_dict(
            # "{" <url-file> "}"
            # url {
            #  src: "/Users/gar/obazl-repository/ppx_assert"
            #  archive: "https://github.com/.../dev.zip"
            # }
        ),
        setenv = attr.string_dict(
            # [ <environment-update> ... ]
        ),
        build_env = attr.string_dict(
            # [ <environment-update> ... ]
        ),
        extra_files = attr.string_list(
            # [ [ <string> <checksum> ] ... ]
        ),
        pin_depends = attr.string_list(
            # [ [ <package> <URL> ] ... ]
        ),
        x_env_path_rewrite = attr.string_list(
            # [ <environment-update-rewrite> ... ]
        ),
        x_ = attr.string_dict(
            # <value>
            ## e.g. {"x-foo": "bar"}
        ),
        ## hidden
        _tool = attr.label(
            default = "@mustachios//app:mustachios",
            allow_single_file = True
        ),
        _template = attr.label(
            default = ":opam.mustache",
            allow_single_file = True
        ),
    ),
)

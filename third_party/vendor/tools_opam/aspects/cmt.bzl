load("@rules_ocaml//build:providers.bzl",
     "OCamlDepsProvider",
     "OCamlModuleProvider",
     "OCamlSignatureProvider")

def _cmt_aspect_impl(target, ctx):
    # Make sure the rule has a srcs attribute.
    if hasattr(ctx.rule.attr, 'deps'):
        # Iterate through the files that make up the sources and
        # print their paths.
        for dep in ctx.rule.attr.deps:
            for f in dep.files.to_list():
                print(f.path)
    if hasattr(ctx.rule.attr, 'struct'):
        for f in ctx.rule.attr.struct.files.to_list():
            print(f.path)

    print(target[OutputGroupInfo].cmts)

    return []

cmt_aspect = aspect(
    implementation = _cmt_aspect_impl,
    attr_aspects = ['struct', 'sig', 'src', 'deps'],
    required_providers = [
        [OCamlModuleProvider],
        [OCamlSignatureProvider]
    ],
)

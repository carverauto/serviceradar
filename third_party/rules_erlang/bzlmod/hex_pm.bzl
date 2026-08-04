load(
    ":semver.bzl",
    "Version",
    "eq",
    "gte",
    "lt",
    "version_from_string",
)

def hex_package_info(ctx, name):
    curl = ctx.which("curl")
    endpoint = "https://hex.pm/api/packages/{}".format(name)
    response = ctx.execute(
        [curl, "--silent", endpoint],
        timeout = 30,
    )
    if response.return_code != 0:
        fail("hex.pm api returned {} for {}".format(response.return_code, endpoint))
    return json.decode(response.stdout)

def hex_release_info(ctx, name, version):
    curl = ctx.which("curl")
    endpoint = "https://hex.pm/api/packages/{}/releases/{}".format(name, version)
    response = ctx.execute(
        [curl, "--silent", endpoint],
        timeout = 30,
    )
    if response.return_code != 0:
        fail("hex.pm api returned {} for {}".format(response.return_code, endpoint))
    return json.decode(response.stdout)

def satisfies(version, requirement):
    v = version_from_string(version)
    if v == None:
        # print("Ignoring version", version)
        return False
    if requirement.startswith("~>"):
        min = version_from_string(requirement.removeprefix("~>").lstrip())
        if min == None:
            print("Ignoring requirement", requirement)
            return False
        max = Version(major = min.major, minor = min.minor + 1, patch = 0)
        return gte(v, min) and lt(v, max)
    elif version_from_string(requirement) != None:
        return eq(v, version_from_string(requirement))
    else:
        fail(requirement)

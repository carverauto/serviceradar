BEGINS_WITH_FUN = """beginswith() { case $2 in "$1"*) true;; *) false;; esac; }"""
QUERY_ERL_VERSION = """erl -eval '{ok, Version} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:fwrite(Version), halt().' -noshell"""

_DRIVE_LETTERS = ["c", "d", "e"]

def path_join(*components):
    nec = []
    for c in components:
        if c != "":
            nec.append(c)
    return "/".join(nec)

def windows_path(path):
    for letter in _DRIVE_LETTERS:
        prefix = "/%s/" % letter
        if path.startswith(prefix):
            return "%s:\\" % letter.upper() + path.removeprefix(
                prefix,
            ).replace("/", "\\")
    return path.replace("/", "\\")

def msys2_path(path):
    for letter in _DRIVE_LETTERS:
        for prefix in ["%s:" % letter.upper(), "%s:" % letter]:
            if path.startswith(prefix):
                return "/%s" % letter + path.removeprefix(
                    prefix,
                ).replace("\\", "/")
    return path.replace("\\", "/")

def without(item, elements):
    c = list(elements)
    c.remove(item)
    return c

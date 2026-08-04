Version = provider(fields = ["major", "minor", "patch"])

def version_from_string(version):
    parts = version.split(".", 2)
    if len(parts) != 3:
        return None
    [major, minor, patch] = parts
    if not major.isdigit():
        return None
    if not minor.isdigit():
        return None
    if not patch.isdigit():
        return None
    return Version(
        major = int(major),
        minor = int(minor),
        patch = int(patch),
    )

def gte(a, b):
    if a.major > b.major:
        return True
    elif a.major == b.major:
        if a.minor > b.minor:
            return True
        elif a.minor == b.minor:
            return a.patch >= b.patch
        else:
            return False
    else:
        return False

def lt(a, b):
    if a.major < b.major:
        return True
    elif a.major == b.major:
        if a.minor < b.minor:
            return True
        elif a.minor == b.minor:
            return a.patch < b.patch
        else:
            return False
    else:
        return False

def eq(a, b):
    return a.major == b.major and a.minor == b.minor and a.patch == b.patch

def compatible(a, b):
    return a.major == b.major

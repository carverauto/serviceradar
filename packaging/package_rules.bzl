"""Shared helpers for ServiceRadar packaging targets."""

load("@rules_pkg//pkg:pkg.bzl", "pkg_deb", "pkg_tar")
load("@rules_pkg//pkg:rpm.bzl", "pkg_rpm")
load(
    "@rules_pkg//pkg:mappings.bzl",
    "pkg_attributes",
    "pkg_files",
    "pkg_mkdirs",
)

_DEFAULT_HOMEPAGE = "https://github.com/carverauto/serviceradar"
_DEFAULT_LICENSE = "Proprietary"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _split_dest(dest):
    if not dest:
        fail("Destination path must be provided")
    if not dest.startswith("/"):
        fail("Destination path must be absolute: %s" % dest)
    if dest == "/":
        return "/", ""
    prefix, basename = dest.rsplit("/", 1)
    if prefix == "":
        prefix = "/"
    return prefix, basename


def _attrs_from(entry):
    attrs = {}
    for key, attr_key in [("mode", "mode"), ("owner", "user"), ("group", "group"), ("rpm_filetag", "rpm_filetag")]:
        value = entry.get(key)
        if value:
            if attr_key == "rpm_filetag":
                if type(value) in (type(()), type([])):
                    # rules_pkg expects a single string; allow tuple/list inputs for convenience.
                    value = " ".join(value)
                if not value.startswith("%"):
                    value = "%" + value
            attrs[attr_key] = value
    return pkg_attributes(**attrs) if attrs else None


def _normalize_file_entry(entry):
    src = entry.get("src") or entry.get("target")
    dest = entry.get("dest")
    strip_prefix = entry.get("strip_prefix")
    if src == None or dest == None:
        fail("File entry must include src and dest: %s" % entry)
    prefix, basename = _split_dest(dest)
    attributes = entry.get("attributes") or _attrs_from(entry)
    return {
        "src": src,
        "prefix": prefix,
        "basename": basename,
        "attributes": attributes,
        "strip_prefix": strip_prefix,
    }


def _emit_pkg_files(name, suffix, entries):
    targets = []
    for idx, entry in enumerate(entries):
        kwargs = {
            "name": "{}_{}{}".format(name, suffix, idx),
            "srcs": [entry["src"]],
            "prefix": entry["prefix"],
            "attributes": entry["attributes"],
        }

        if entry.get("strip_prefix"):
            kwargs["strip_prefix"] = entry["strip_prefix"]

        basename = entry["basename"]
        if basename and not entry.get("strip_prefix"):
            kwargs["renames"] = {entry["src"]: basename}

        pkg_files(**kwargs)
        targets.append(":{}_{}{}".format(name, suffix, idx))
    return targets


def _emit_pkg_tree(name, suffix, tree):
    patterns = tree.get("patterns")
    if not patterns:
        fail("Tree entries require 'patterns': %s" % tree)
    prefix = tree.get("dest")
    if not prefix or not prefix.startswith("/"):
        fail("Tree entries require absolute 'dest' path: %s" % tree)
    attributes = tree.get("attributes") or _attrs_from(tree)
    pkg_files(
        name = "{}_{}".format(name, suffix),
        srcs = native.glob(patterns, allow_empty = tree.get("allow_empty", False)),
        prefix = prefix,
        strip_prefix = tree.get("strip_prefix"),
        attributes = attributes,
    )
    return ":{}_{}".format(name, suffix)

# ---------------------------------------------------------------------------
# Public macro
# ---------------------------------------------------------------------------

def serviceradar_package(
        name,
        package_name,
        description,
        maintainer,
        architecture,
        section,
        priority,
        deb_depends,
        rpm_requires,
        binary = None,
        files = [],
        trees = [],
        directories = [],
        conffiles = [],
        systemd = None,
        postinst = None,
        prerm = None,
        homepage = _DEFAULT_HOMEPAGE,
        license = _DEFAULT_LICENSE,
        rpm_release = "1",
        summary = None,
        version_file = "//:VERSION",
        rpm_tags = ["no-remote-exec"],
        rpm_disable_remote = False,
    ):
    """Define .deb and .rpm packaging targets for a component."""

    data_targets = []

    # Directories -------------------------------------------------------------
    for idx, directory in enumerate(directories or []):
        attrs = directory.get("attributes") or _attrs_from(directory)
        pkg_mkdirs(
            name = "{}_mkdir_{}".format(name, idx),
            dirs = [directory["path"]],
            attributes = attrs,
        )
        data_targets.append(":{}_mkdir_{}".format(name, idx))

    # Files -------------------------------------------------------------------
    normalized_files = []

    if binary:
        normalized_files.append(_normalize_file_entry({
            "src": binary["target"],
            "dest": binary["dest"],
            "mode": binary.get("mode", "0755"),
        }))

    if systemd:
        normalized_files.append(_normalize_file_entry({
            "src": systemd["src"],
            "dest": systemd["dest"],
            "mode": systemd.get("mode", "0644"),
        }))

    for entry in files or []:
        normalized_files.append(_normalize_file_entry(entry))

    data_targets.extend(_emit_pkg_files(name, "file", normalized_files))

    # Trees -------------------------------------------------------------------
    for idx, tree in enumerate(trees or []):
        data_targets.append(_emit_pkg_tree(name, "tree_%d" % idx, tree))

    # Aggregate tar -----------------------------------------------------------
    pkg_tar(
        name = "{}_data".format(name),
        srcs = data_targets,
        package_dir = "/",
        extension = "tar",
    )

    # Helper filegroups for scripts ------------------------------------------
    deb_kwargs = {}
    rpm_kwargs = {}

    if postinst:
        native.filegroup(name = "{}_postinst".format(name), srcs = [postinst])
        deb_kwargs["postinst"] = ":{}_postinst".format(name)
        rpm_kwargs["post_scriptlet_file"] = ":{}_postinst".format(name)
    if prerm:
        native.filegroup(name = "{}_prerm".format(name), srcs = [prerm])
        deb_kwargs["prerm"] = ":{}_prerm".format(name)
        rpm_kwargs["preun_scriptlet_file"] = ":{}_prerm".format(name)

    # pkg_deb -----------------------------------------------------------------
    pkg_deb(
        name = "{}_deb".format(name),
        package = package_name,
        architecture = architecture,
        maintainer = maintainer,
        version_file = version_file,
        description = description,
        homepage = homepage,
        license = license,
        depends = deb_depends,
        section = section,
        priority = priority,
        conffiles = conffiles,
        data = ":{}_data".format(name),
        **deb_kwargs
    )

    # pkg_rpm -----------------------------------------------------------------
    compatible = ["@platforms//os:linux"]
    if rpm_disable_remote:
        target_compat = {
            "//packaging:remote_executor": ["@platforms//:incompatible"],
            "//conditions:default": compatible,
        }
    else:
        target_compat = {"//conditions:default": compatible}

    rpm_version_output = "{}_rpm_version.txt".format(name)
    rpm_release_output = "{}_rpm_release.txt".format(name)

    native.genrule(
        name = "{}_rpm_version".format(name),
        srcs = [version_file],
        outs = [rpm_version_output],
        cmd = """
set -eo pipefail
python3 - <<'PY' "$<" "$@"
import re
import sys

src, dst = sys.argv[1:3]
version_raw = open(src, 'r', encoding='utf-8').read().strip()
if not version_raw:
    raise SystemExit("VERSION file is empty")

base_part = version_raw.split('-', 1)[0]
sanitized_base = re.sub(r"[^A-Za-z0-9._+]", ".", base_part).strip('.')
if not sanitized_base:
    raise SystemExit("sanitized RPM version is empty")

with open(dst, 'w', encoding='utf-8') as out:
    out.write(sanitized_base + "\n")
PY
""",
    )

    fallback_release = rpm_release or "1"
    fallback_escaped = fallback_release.replace("'", "'\\''")
    native.genrule(
        name = "{}_rpm_release".format(name),
        srcs = [version_file],
        outs = [rpm_release_output],
        cmd = """
set -eo pipefail
python3 - <<'PY' "$<" "$@" '%s'
import re
import sys

src, dst, fallback = sys.argv[1:4]
version_raw = open(src, 'r', encoding='utf-8').read().strip()

release_part = ''
if '-' in version_raw:
    release_part = version_raw.split('-', 1)[1]

sanitized_release = re.sub(r"[^A-Za-z0-9._+]", ".", release_part).strip('.') if release_part else ''
if not sanitized_release:
    sanitized_release = re.sub(r"[^A-Za-z0-9._+]", ".", fallback).strip('.')
if not sanitized_release:
    sanitized_release = '1'

with open(dst, 'w', encoding='utf-8') as out:
    out.write(sanitized_release + "\n")
PY
""" % fallback_escaped,
    )

    pkg_rpm(
        name = "{}_rpm".format(name),
        package_name = package_name,
        version_file = ":{}".format(rpm_version_output),
        release_file = ":{}".format(rpm_release_output),
        architecture = "x86_64" if architecture == "amd64" else architecture,
        summary = summary or description,
        description = description,
        license = license,
        url = homepage,
        requires = rpm_requires,
        srcs = data_targets,
        target_compatible_with = select(target_compat),
        tags = rpm_tags,
        **rpm_kwargs
    )

    # Bundle ------------------------------------------------------------------
    native.filegroup(
        name = name,
        srcs = [
            ":{}_deb".format(name),
            ":{}_rpm".format(name),
        ],
    )


def serviceradar_package_from_config(name, config):
    serviceradar_package(name = name, **config)

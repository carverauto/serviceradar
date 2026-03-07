"""Shared helpers for straightforward service OCI images."""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")
load("@rules_pkg//pkg:pkg.bzl", "pkg_tar")

_DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin"

def _service_env(extra_env):
    env = {
        "PATH": _DEFAULT_PATH,
    }
    env.update(extra_env)
    return env

def service_layer(
        name,
        files = None,
        modes = None,
        empty_dirs = None,
        symlinks = None,
        target_compatible_with = None,
        visibility = None):
    """Create a rootfs layer for a service image."""

    if files == None:
        files = {}
    if modes == None:
        modes = {}
    if empty_dirs == None:
        empty_dirs = []
    if symlinks == None:
        symlinks = {}
    if target_compatible_with == None:
        target_compatible_with = []

    pkg_tar(
        name = name,
        files = files,
        modes = modes,
        empty_dirs = empty_dirs,
        symlinks = symlinks,
        package_dir = "/",
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

def declare_postgresql_client_symlink_layer(
        name = "postgresql_client_symlinks",
        libexec_dir = "postgresql18",
        visibility = None):
    """Create a compatibility layer exposing PostgreSQL client tools under /usr/bin."""

    prefix = "/usr/libexec/{}".format(libexec_dir)

    service_layer(
        name = name,
        symlinks = {
            "usr/bin/clusterdb": "{}/clusterdb".format(prefix),
            "usr/bin/createdb": "{}/createdb".format(prefix),
            "usr/bin/createuser": "{}/createuser".format(prefix),
            "usr/bin/dropdb": "{}/dropdb".format(prefix),
            "usr/bin/dropuser": "{}/dropuser".format(prefix),
            "usr/bin/pg_amcheck": "{}/pg_amcheck".format(prefix),
            "usr/bin/pg_basebackup": "{}/pg_basebackup".format(prefix),
            "usr/bin/pg_dump": "{}/pg_dump".format(prefix),
            "usr/bin/pg_dumpall": "{}/pg_dumpall".format(prefix),
            "usr/bin/pg_isready": "{}/pg_isready".format(prefix),
            "usr/bin/pg_recvlogical": "{}/pg_recvlogical".format(prefix),
            "usr/bin/pg_receivewal": "{}/pg_receivewal".format(prefix),
            "usr/bin/pg_restore": "{}/pg_restore".format(prefix),
            "usr/bin/pg_verifybackup": "{}/pg_verifybackup".format(prefix),
            "usr/bin/pgbench": "{}/pgbench".format(prefix),
            "usr/bin/psql": "{}/psql".format(prefix),
            "usr/bin/reindexdb": "{}/reindexdb".format(prefix),
            "usr/bin/vacuumdb": "{}/vacuumdb".format(prefix),
        },
        visibility = visibility,
    )

def declare_common_tools_layer(
        name = "common_tools_amd64",
        visibility = None,
        target_compatible_with = None):
    """Create the shared debugging/tooling layer used by service images."""

    if target_compatible_with == None:
        target_compatible_with = []

    service_layer(
        name = name,
        files = {
            "@jq_linux_amd64//file": "usr/local/bin/jq",
            "@curl_linux_amd64//file": "usr/local/bin/curl",
            "@grpcurl_linux_amd64//:grpcurl": "usr/local/bin/grpcurl",
            "//go/cmd/tools/waitforport:wait-for-port": "usr/local/bin/wait-for-port",
        },
        modes = {
            "usr/local/bin/jq": "0755",
            "usr/local/bin/curl": "0755",
            "usr/local/bin/grpcurl": "0755",
            "usr/local/bin/wait-for-port": "0755",
        },
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

def service_image_amd64(
        name,
        base,
        tars,
        image_title,
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = None,
        exposed_ports = None,
        target_compatible_with = None,
        visibility = None):
    """Create an amd64 OCI image for a straightforward service."""

    if entrypoint == None:
        entrypoint = []
    if cmd == None:
        cmd = []
    if env == None:
        env = {}
    if workdir == None:
        workdir = ""
    if exposed_ports == None:
        exposed_ports = []
    if target_compatible_with == None:
        target_compatible_with = []

    oci_image(
        name = name,
        base = base,
        tars = tars,
        entrypoint = entrypoint,
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        target_compatible_with = target_compatible_with,
        labels = {
            "org.opencontainers.image.title": image_title,
        },
        visibility = visibility,
    )

def service_image_tar(name, image, repo_tags, visibility = None):
    """Create an oci_load target for local image testing."""

    oci_load(
        name = name,
        image = image,
        repo_tags = repo_tags,
        visibility = visibility,
    )

def declare_loaded_oci_image_amd64(
        name,
        base,
        image_title,
        repo_tags,
        tars = None,
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = "",
        exposed_ports = None,
        target_compatible_with = None,
        visibility = None):
    """Declare an arbitrary OCI image plus its local oci_load target."""

    if tars == None:
        tars = []
    if env == None:
        env = {}

    service_image_amd64(
        name = name,
        base = base,
        tars = tars,
        image_title = image_title,
        entrypoint = entrypoint,
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

    service_image_tar(
        name = "{}_tar".format(name),
        image = ":{}".format(name),
        repo_tags = repo_tags,
        visibility = visibility,
    )

def alpine_service_image_amd64(
        name,
        layer,
        image_title,
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = "/var/lib/serviceradar",
        exposed_ports = None,
        extra_tars = None,
        target_compatible_with = None,
        visibility = None):
    """Create an Alpine-based service image with common tools."""

    if env == None:
        env = {}
    if extra_tars == None:
        extra_tars = []

    service_image_amd64(
        name = name,
        base = "@alpine_3_20_linux_amd64//:alpine_3_20_linux_amd64",
        tars = [":common_tools_amd64"] + extra_tars + [layer],
        entrypoint = entrypoint,
        cmd = cmd,
        env = _service_env(env),
        workdir = workdir,
        exposed_ports = exposed_ports,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        image_title = image_title,
    )

def alpine_netutils_service_image_amd64(
        name,
        layer,
        image_title,
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = "/var/lib/serviceradar",
        exposed_ports = None,
        extra_tars = None,
        target_compatible_with = None,
        visibility = None):
    """Create an Alpine-based service image with netutils and common tools."""

    if env == None:
        env = {}
    if extra_tars == None:
        extra_tars = []

    service_image_amd64(
        name = name,
        base = "@alpine_3_20_linux_amd64//:alpine_3_20_linux_amd64",
        tars = [":alpine_netutils_rootfs_amd64", ":common_tools_amd64"] + extra_tars + [layer],
        entrypoint = entrypoint,
        cmd = cmd,
        env = _service_env(env),
        workdir = workdir,
        exposed_ports = exposed_ports,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        image_title = image_title,
    )

def ubuntu_service_image_amd64(
        name,
        layer,
        image_title,
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = "/var/lib/serviceradar",
        exposed_ports = None,
        extra_tars = None,
        target_compatible_with = None,
        visibility = None):
    """Create an Ubuntu-based service image with common tools."""

    if env == None:
        env = {}
    if extra_tars == None:
        extra_tars = []

    service_image_amd64(
        name = name,
        base = "@ubuntu_noble_linux_amd64//:ubuntu_noble_linux_amd64",
        tars = [":common_tools_amd64"] + extra_tars + [layer],
        entrypoint = entrypoint,
        cmd = cmd,
        env = _service_env(env),
        workdir = workdir,
        exposed_ports = exposed_ports,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        image_title = image_title,
    )

def declare_service_container_amd64(
        name,
        image_title,
        files = None,
        modes = None,
        empty_dirs = None,
        symlinks = None,
        runtime = "ubuntu",
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = "/var/lib/serviceradar",
        exposed_ports = None,
        extra_tars = None,
        target_compatible_with = None,
        visibility = None,
        repo_tags = None):
    """Declare a straightforward service layer, image, and local tar target."""

    if files == None:
        files = {}
    if modes == None:
        modes = {}
    if empty_dirs == None:
        empty_dirs = []
    if symlinks == None:
        symlinks = {}
    if env == None:
        env = {}
    if extra_tars == None:
        extra_tars = []
    if target_compatible_with == None:
        target_compatible_with = []
    if repo_tags == None:
        repo_tags = []

    if name.endswith("_image_amd64"):
        layer_name = name[:-len("_image_amd64")] + "_layer_amd64"
        tar_name = name + "_tar"
    else:
        layer_name = name + "_layer"
        tar_name = name + "_tar"

    service_layer(
        name = layer_name,
        files = files,
        modes = modes,
        empty_dirs = empty_dirs,
        symlinks = symlinks,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

    layer_label = ":{}".format(layer_name)

    if runtime == "alpine":
        alpine_service_image_amd64(
            name = name,
            layer = layer_label,
            image_title = image_title,
            entrypoint = entrypoint,
            cmd = cmd,
            env = env,
            workdir = workdir,
            exposed_ports = exposed_ports,
            extra_tars = extra_tars,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
        )
    elif runtime == "alpine_netutils":
        alpine_netutils_service_image_amd64(
            name = name,
            layer = layer_label,
            image_title = image_title,
            entrypoint = entrypoint,
            cmd = cmd,
            env = env,
            workdir = workdir,
            exposed_ports = exposed_ports,
            extra_tars = extra_tars,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
        )
    elif runtime == "ubuntu":
        ubuntu_service_image_amd64(
            name = name,
            layer = layer_label,
            image_title = image_title,
            entrypoint = entrypoint,
            cmd = cmd,
            env = env,
            workdir = workdir,
            exposed_ports = exposed_ports,
            extra_tars = extra_tars,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
        )
    else:
        fail("unsupported runtime '{}'".format(runtime))

    service_image_tar(
        name = tar_name,
        image = ":{}".format(name),
        repo_tags = repo_tags,
        visibility = visibility,
    )

def declare_custom_base_service_container_amd64(
        name,
        base,
        image_title,
        repo_tags,
        files = None,
        modes = None,
        empty_dirs = None,
        symlinks = None,
        entrypoint = None,
        cmd = None,
        env = None,
        workdir = "",
        exposed_ports = None,
        extra_tars = None,
        target_compatible_with = None,
        visibility = None):
    """Declare a service layer packaged onto an arbitrary base image."""

    if files == None:
        files = {}
    if modes == None:
        modes = {}
    if empty_dirs == None:
        empty_dirs = []
    if symlinks == None:
        symlinks = {}
    if env == None:
        env = {}
    if extra_tars == None:
        extra_tars = []
    if target_compatible_with == None:
        target_compatible_with = []

    if name.endswith("_image_amd64"):
        layer_name = name[:-len("_image_amd64")] + "_layer_amd64"
    else:
        layer_name = name + "_layer"

    service_layer(
        name = layer_name,
        files = files,
        modes = modes,
        empty_dirs = empty_dirs,
        symlinks = symlinks,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

    declare_loaded_oci_image_amd64(
        name = name,
        base = base,
        image_title = image_title,
        repo_tags = repo_tags,
        tars = extra_tars + [":{}".format(layer_name)],
        entrypoint = entrypoint,
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
    )

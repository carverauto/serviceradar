"""Component packaging metadata.

`PACKAGES` is the full inventory of buildable deb/rpm components. Local
`bazel build //build/packaging/<name>:<name>_deb` still works for any entry.

`RELEASE_PACKAGES` is the subset published to Forgejo on every tagged release.
Control-plane services (core-elx, web-ng, agent-gateway, datasvc, faker, etc.)
are container/Helm only — edge installers that still need packages are the
agent, NATS, CLI helper, collectors, and rperf (client checker + server).
"""

# Packages uploaded by //build/release:publish_packages / the release workflow.
# Keep this list small: each fat release historically cost ~2.7 GiB of Forgejo
# attachment storage (deb+rpm for every component).
RELEASE_PACKAGES = [
    "agent",
    "nats",
    "cli",  # dependency of flow-collector / bmp-collector packages
    "log-collector",
    "flow-collector",
    "bmp-collector",
    "trapd",
    "rperf",  # edge bandwidth reflector (server)
    "rperf-checker",  # edge bandwidth client installed on monitored systems
]

PACKAGES = {
    "web-ng": {
        "package_name": "serviceradar-web-ng",
        "description": "ServiceRadar Phoenix web UI (web-ng)",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "rpm_tags": [],
        "files": [
            {
                "src": "//elixir/web-ng:release_tar",
                "dest": "/usr/local/share/serviceradar-web-ng/serviceradar-web-ng.tar.gz",
                "mode": "0644",
            },
            {
                "src": "config/web-ng.env",
                "dest": "/etc/serviceradar/web-ng.env",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-web-ng.service",
            "dest": "/lib/systemd/system/serviceradar-web-ng.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/web-ng.env",
        ],
    },
    "agent": {
        "package_name": "serviceradar-agent",
        "description": "ServiceRadar Agent Service",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd", "libcap2-bin"],
        "rpm_requires": ["systemd", "libcap"],
        # libpcap was netprobe's runtime dependency; it moved out with the netprobe
        # carve (migrate-netprobe-to-native-addon §1.4). The netprobe add-on (or its
        # os-package fallback) carries its own libpcap requirement now.
        "binary": {
            "target": "//go/cmd/agent:agent",
            "dest": "/usr/local/lib/serviceradar/agent/serviceradar-agent-seed",
        },
        "files": [
            {
                "src": "//go/cmd/agent-updater:agent_updater",
                "dest": "/usr/local/bin/serviceradar-agent-updater",
                # Keep the package payload aligned with postinstall: the helper must
                # run setuid-root when the non-root agent applies add-on capabilities
                # or installs native add-on systemd units. postinstall still assigns
                # group serviceradar after ensuring that group exists.
                "mode": "4750",
            },
            {
                "src": "bin/serviceradar-agent",
                "dest": "/usr/local/bin/serviceradar-agent",
                "mode": "0755",
            },
            {
                "src": "//go/cmd/cli:srctl",
                "dest": "/usr/local/bin/srctl",
                "mode": "0755",
            },
            {
                "src": "config/agent.json",
                "dest": "/etc/serviceradar/agent.json",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
            {
                "src": "config/checkers/sweep/sweep.json",
                "dest": "/etc/serviceradar/checkers/sweep/sweep.json",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
                "allow_empty": True,
            },
            {
                # Repair legacy units that still own /run/serviceradar. This is
                # package-owned so upgrade converges before postinstall restarts.
                "src": "systemd/50-serviceradar-shared-runtime.conf",
                "dest": "/etc/systemd/system/serviceradar-agent.service.d/50-serviceradar-shared-runtime.conf",
                "mode": "0644",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-agent.service",
            "dest": "/lib/systemd/system/serviceradar-agent.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/agent.json",
            "/etc/serviceradar/checkers/sweep/sweep.json",
        ],
        # Deprecated alias for the pre-rename binary. Remove after the
        # compatibility window closes (see #4260).
        "symlinks": {
            "/usr/local/bin/serviceradar-cli": "srctl",
        },
    },
    "bumblebee-scan": {
        "package_name": "serviceradar-bumblebee-scan",
        "description": "Optional ServiceRadar Bumblebee root scanner add-on",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd", "serviceradar-agent"],
        "rpm_requires": ["systemd", "serviceradar-agent"],
        "files": [
            {
                "src": "//go/cmd/bumblebee-scan:bumblebee_scan",
                "dest": "/usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan",
                "mode": "0755",
            },
            {
                "src": "config/bumblebee-scan.json",
                "dest": "/etc/serviceradar/bumblebee-scan.json",
                "mode": "0640",
                "rpm_filetag": "config(noreplace)",
            },
            {
                "src": "systemd/serviceradar-bumblebee-scan.service",
                "dest": "/lib/systemd/system/serviceradar-bumblebee-scan.service",
                "mode": "0644",
            },
            {
                "src": "systemd/serviceradar-bumblebee-scan.timer",
                "dest": "/lib/systemd/system/serviceradar-bumblebee-scan.timer",
                "mode": "0644",
            },
        ],
        "directories": [
            {"path": "/var/lib/serviceradar/bumblebee", "mode": "0770", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/bumblebee/cache", "mode": "0770", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/bumblebee/catalog", "mode": "0770", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/bumblebee/profile", "mode": "0770", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/bumblebee/spool", "mode": "0750", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/bumblebee/spool/runs", "mode": "0750", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/bumblebee/tmp", "mode": "0770", "owner": "root", "group": "serviceradar"},
        ],
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/bumblebee-scan.json",
        ],
    },
    "core-elx": {
        "package_name": "serviceradar-core-elx",
        "description": "ServiceRadar Core Elixir service (core-elx)",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "rpm_tags": [],
        "files": [
            {
                "src": "//elixir/serviceradar_core_elx:release_tar",
                "dest": "/usr/local/share/serviceradar-core-elx/serviceradar-core-elx.tar.gz",
                "mode": "0644",
            },
            {
                "src": "config/core-elx.env",
                "dest": "/etc/serviceradar/core-elx.env",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-core-elx.service",
            "dest": "/lib/systemd/system/serviceradar-core-elx.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/core-elx.env",
        ],
    },
    "agent-gateway": {
        "package_name": "serviceradar-agent-gateway",
        "description": "ServiceRadar Agent Gateway service (agent-gateway)",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "rpm_tags": [],
        "files": [
            {
                "src": "//elixir/serviceradar_agent_gateway:release_tar",
                "dest": "/usr/local/share/serviceradar-agent-gateway/serviceradar-agent-gateway.tar.gz",
                "mode": "0644",
            },
            {
                "src": "config/agent-gateway.env",
                "dest": "/etc/serviceradar/agent-gateway.env",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-agent-gateway.service",
            "dest": "/lib/systemd/system/serviceradar-agent-gateway.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/agent-gateway.env",
        ],
    },
    "datasvc": {
        "package_name": "serviceradar-datasvc",
        "description": "ServiceRadar Data Service (KV + object store)",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "binary": {
            "target": "//go/cmd/data-services:data_services",
            "dest": "/usr/local/bin/serviceradar-datasvc",
        },
        "files": [
            {
                "src": "config/datasvc.json",
                "dest": "/etc/serviceradar/datasvc.json",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-datasvc.service",
            "dest": "/lib/systemd/system/serviceradar-datasvc.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/datasvc.json",
        ],
    },
    "faker": {
        "package_name": "serviceradar-faker",
        "description": "ServiceRadar Faker Service",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "binary": {
            "target": "//go/cmd/faker:faker",
            "dest": "/usr/local/bin/serviceradar-faker",
        },
        "files": [
            {
                "src": "config/faker.json",
                "dest": "/etc/serviceradar/faker.json",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-faker.service",
            "dest": "/lib/systemd/system/serviceradar-faker.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/faker.json",
        ],
    },
    "trapd": {
        "package_name": "serviceradar-trapd",
        "description": "ServiceRadar SNMP trap receiver service",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "net",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "binary": {
            "target": "//rust/trapd:trapd",
            "dest": "/usr/local/bin/serviceradar-trapd",
        },
        "files": [
            {
                "src": "config/trapd.json",
                "dest": "/etc/serviceradar/trapd.json",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-trapd.service",
            "dest": "/lib/systemd/system/serviceradar-trapd.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/trapd.json",
        ],
    },
    "log-collector": {
        "package_name": "serviceradar-log-collector",
        "description": "ServiceRadar unified log collector (syslog + OTEL)",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "binary": {
            "target": "//rust/log-collector:log-collector",
            "dest": "/usr/local/bin/serviceradar-log-collector",
        },
        "files": [
            {
                "src": "config/log-collector.toml",
                "dest": "/etc/serviceradar/log-collector.toml",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-log-collector.service",
            "dest": "/lib/systemd/system/serviceradar-log-collector.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/log-collector.toml",
        ],
    },
    "flow-collector": {
        "package_name": "serviceradar-flow-collector",
        "description": "ServiceRadar unified flow collector (NetFlow/IPFIX + sFlow)",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "net",
        "priority": "optional",
        "deb_depends": ["systemd", "serviceradar-cli"],
        "rpm_requires": ["systemd", "serviceradar-cli"],
        "binary": {
            "target": "//rust/flow-collector:flow-collector",
            "dest": "/usr/local/bin/serviceradar-flow-collector",
        },
        "files": [
            {
                "src": "config/flow-collector.json",
                "dest": "/etc/serviceradar/flow-collector.json",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-flow-collector.service",
            "dest": "/lib/systemd/system/serviceradar-flow-collector.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/flow-collector.json",
        ],
    },
    "bmp-collector": {
        "package_name": "serviceradar-bmp-collector",
        "description": "ServiceRadar BMP collector powered by Arancini runtime",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "net",
        "priority": "optional",
        "deb_depends": ["systemd", "serviceradar-cli"],
        "rpm_requires": ["systemd", "serviceradar-cli"],
        "binary": {
            "target": "//rust/bmp-collector:bmp-collector",
            "dest": "/usr/local/bin/serviceradar-bmp-collector",
        },
        "files": [],
        "systemd": {
            "src": "systemd/serviceradar-bmp-collector.service",
            "dest": "/lib/systemd/system/serviceradar-bmp-collector.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [],
    },
    "nats": {
        "package_name": "serviceradar-nats",
        "description": "ServiceRadar NATS JetStream service",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "files": [
            {
                "src": "@nats_server_linux_amd64//:nats_server",
                "dest": "/usr/bin/nats-server",
                "mode": "0755",
            },
            {
                "src": "config/nats-server.conf",
                "dest": "/etc/nats/nats-server.conf",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
            {
                "src": "config/nats-cloud.conf",
                "dest": "/etc/nats/templates/nats-cloud.conf",
                "mode": "0644",
            },
            {
                "src": "config/nats-leaf.conf",
                "dest": "/etc/nats/templates/nats-leaf.conf",
                "mode": "0644",
            },
        ],
        "directories": [
            {"path": "/etc/nats/templates", "mode": "0755"},
            {"path": "/var/lib/nats", "mode": "0755"},
            {"path": "/var/lib/nats/jetstream", "mode": "0755"},
            {"path": "/var/log/nats", "mode": "0755"},
        ],
        "systemd": {
            "src": "systemd/serviceradar-nats.service",
            "dest": "/lib/systemd/system/serviceradar-nats.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/nats/nats-server.conf",
        ],
    },
    "rperf": {
        "package_name": "serviceradar-rperf",
        "description": "ServiceRadar RPerf network performance server",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "net",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "binary": {
            "target": "//rust/rperf-server:rperf",
            "dest": "/usr/local/bin/serviceradar-rperf",
        },
        "files": [
            {
                "src": "config/rperf/rperf.conf",
                "dest": "/etc/serviceradar/rperf/rperf.conf",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-rperf.service",
            "dest": "/lib/systemd/system/serviceradar-rperf.service",
        },
        "directories": [
            {"path": "/var/log/rperf", "mode": "0755"},
            {"path": "/etc/serviceradar/rperf", "mode": "0755"},
        ],
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/rperf/rperf.conf",
        ],
    },
    "rperf-checker": {
        "package_name": "serviceradar-rperf-checker",
        "description": "ServiceRadar RPerf network performance checker",
        "maintainer": "Carver Automation Corporation <support@carverauto.dev>",
        "architecture": "amd64",
        "section": "net",
        "priority": "optional",
        "deb_depends": ["systemd"],
        "rpm_requires": ["systemd"],
        "binary": {
            "target": "//rust/rperf-client:rperf_checker",
            "dest": "/usr/local/bin/serviceradar-rperf-checker",
        },
        "files": [
            {
                "src": "config/checkers/rperf.json",
                "dest": "/etc/serviceradar/checkers/rperf.json.example",
                "mode": "0644",
                "rpm_filetag": "config(noreplace)",
            },
        ],
        "systemd": {
            "src": "systemd/serviceradar-rperf-checker.service",
            "dest": "/lib/systemd/system/serviceradar-rperf-checker.service",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/checkers/rperf.json.example",
        ],
    },
    "cli": {
        "package_name": "serviceradar-cli",
        "description": "ServiceRadar CLI tool (srctl)",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        "deb_depends": [],
        "rpm_requires": [],
        "binary": {
            "target": "//go/cmd/cli:srctl",
            "dest": "/usr/local/bin/srctl",
        },
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        # Deprecated alias for the pre-rename binary. Remove after the
        # compatibility window closes (see #4260).
        "symlinks": {
            "/usr/local/bin/serviceradar-cli": "srctl",
        },
    },
}

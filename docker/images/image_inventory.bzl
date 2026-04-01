"""Shared inventory for publishable OCI images."""

PUBLISHABLE_IMAGES = [
    {"image": "arc_runner_image_amd64", "repository": "registry.carverauto.dev/serviceradar/arc-runner"},
    {"image": "core_elx_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-core-elx"},
    {"image": "agent_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-agent"},
    {"image": "db_event_writer_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-db-event-writer"},
    {"image": "datasvc_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-datasvc"},
    {"image": "log_collector_image_amd64", "push_image": "log_collector_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-log-collector"},
    {"image": "trapd_image_amd64", "push_image": "trapd_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-trapd"},
    {"image": "flow_collector_image_amd64", "push_image": "flow_collector_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-flow-collector"},
    {"image": "bmp_collector_image_amd64", "push_image": "bmp_collector_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/arancini"},
    {"image": "rperf_client_image_amd64", "push_image": "rperf_client_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-rperf-client"},
    {"image": "agent_gateway_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-agent-gateway"},
    {"image": "faker_image_amd64", "push_image": "faker_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-faker"},
    {"image": "zen_image_amd64", "push_image": "zen_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-zen"},
    {"image": "config_updater_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-config-updater"},
    {"image": "web_ng_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-web-ng", "digest_label": ":web_ng_image_base_amd64.digest"},
    {"image": "cert_generator_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-cert-generator"},
    {"image": "tools_image_amd64", "repository": "registry.carverauto.dev/serviceradar/serviceradar-tools"},
    {
        "image": "cnpg_image_amd64",
        "repository": "registry.carverauto.dev/serviceradar/serviceradar-cnpg",
        "static_tags": ["18.3.0-sr2"],
    },
]

def publishable_image_labels():
    """Return local labels for the canonical build artifact of each publishable image."""

    labels = []
    for target in PUBLISHABLE_IMAGES:
        labels.append(":{}".format(target.get("push_image", target["image"])))
    return labels

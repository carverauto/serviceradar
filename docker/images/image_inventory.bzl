"""Shared inventory for publishable OCI images."""

PUBLISHABLE_IMAGES = [
    {"image": "nvr_image_amd64", "chart_service": "nvr", "push_image": "nvr_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-nvr"},
    {"image": "media_worker_image_amd64", "chart_service": "mediaWorker", "push_image": "media_worker_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-media-worker"},
    {"image": "core_elx_image_amd64", "chart_service": "core", "repository": "registry.carverauto.dev/serviceradar/serviceradar-core-elx"},
    {"image": "agent_image_amd64", "chart_service": "agent", "push_image": "agent_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-agent"},
    {"image": "trivy_sidecar_image_amd64", "chart_service": "trivySidecar", "push_image": "trivy_sidecar_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-trivy-sidecar"},
    {"image": "k8s_inventory_image_amd64", "chart_service": "k8sInventory", "push_image": "k8s_inventory_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-k8s-inventory"},
    {"image": "datasvc_image_amd64", "chart_service": "datasvc", "push_image": "datasvc_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-datasvc"},
    {"image": "log_collector_image_amd64", "chart_service": "logCollector", "push_image": "log_collector_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-log-collector"},
    {"image": "trapd_image_amd64", "chart_service": "trapd", "push_image": "trapd_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-trapd"},
    {"image": "dgraph_migrate_image_amd64", "chart_service": "dgraphMigrate", "push_image": "dgraph_migrate_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-dgraph-migrate"},
    {"image": "flow_collector_image_amd64", "chart_service": "flowCollector", "push_image": "flow_collector_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-flow-collector"},
    {"image": "bmp_collector_image_amd64", "chart_service": "bmpCollector", "push_image": "bmp_collector_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/arancini"},
    {"image": "agent_gateway_image_amd64", "chart_service": "agentGateway", "push_image": "agent_gateway_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-agent-gateway"},
    {"image": "faker_image_amd64", "chart_service": "faker", "push_image": "faker_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-faker"},
    {"image": "config_updater_image_amd64", "push_image": "config_updater_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-config-updater"},
    {"image": "web_ng_image_amd64", "chart_service": "webNg", "repository": "registry.carverauto.dev/serviceradar/serviceradar-web-ng"},
    {"image": "cert_generator_image_amd64", "push_image": "cert_generator_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-cert-generator"},
    {"image": "tools_image_amd64", "chart_service": "tools", "push_image": "tools_image_multiarch", "repository": "registry.carverauto.dev/serviceradar/serviceradar-tools"},
    {
        "image": "cnpg_image_amd64",
        "repository": "registry.carverauto.dev/serviceradar/serviceradar-cnpg",
        "static_tags": ["18.4.0-sr4"],
    },
]

# Infrastructure images built from a Dockerfile, not by Bazel: their contents are apt packages,
# which would be a long list of pre-fetched .debs for an image that changes rarely. Each is
# published one at a time by //.github/workflows/publish-dockerfile-image.yml, never by a
# release, and only an image listed here can be built, signed and promoted that way.
DOCKERFILE_IMAGES = [
    {"repository": "buildbuddy-workflow-runner", "dockerfile": "docker/images/Dockerfile.workflow-runner", "context": "docker/images"},
]

# Images assembled with crane around a binary that Bazel cannot build (RBE is amd64-only with
# no CUDA toolkit): the binary is built natively on a credential-less runner and the image is
# pushed, signed and promoted by the named workflow. Only an image listed here can be signed
# that way (SERVICERADAR_NATIVE_IMAGE in //scripts:sign-oci-publish.sh), never by a release.
NATIVE_BUILD_IMAGES = [
    {"repository": "serviceradar-media-worker-cuda"},
]

def publishable_image_labels():
    """Return local labels for the canonical build artifact of each publishable image."""

    labels = []
    for target in PUBLISHABLE_IMAGES:
        labels.append(":{}".format(target.get("push_image", target["image"])))
    return labels

defmodule ServiceRadar.NetworkDiscovery.MapperUnifiController do
  @moduledoc """
  Ubiquiti UniFi controller configuration for mapper discovery jobs.
  """

  use ServiceRadar.NetworkDiscovery.MapperControllerResource,
    table: "mapper_unifi_controllers",
    index_name: "mapper_unifi_controllers_job_idx",
    secret_field: :api_key,
    secret_present_calc: :api_key_present,
    normalizer_change: ServiceRadar.NetworkDiscovery.Changes.NormalizeUnifiBaseUrl,
    base_url_description: "UniFi controller base URL",
    secret_description: "UniFi API key",
    name_description: "Optional controller name",
    insecure_description: "Skip TLS verification for UniFi API",
    create_accept: [:name, :base_url, :api_key, :insecure_skip_verify, :mapper_job_id],
    update_accept: [:name, :base_url, :api_key, :insecure_skip_verify]
end

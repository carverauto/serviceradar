defmodule ServiceRadar.NetworkDiscovery.MapperMikrotikController do
  @moduledoc """
  MikroTik RouterOS REST API configuration for mapper discovery jobs.
  """

  use ServiceRadar.NetworkDiscovery.MapperControllerResource,
    table: "mapper_mikrotik_controllers",
    index_name: "mapper_mikrotik_controllers_job_idx",
    secret_field: :password,
    secret_present_calc: :password_present,
    normalizer_change: ServiceRadar.NetworkDiscovery.Changes.NormalizeMikrotikBaseUrl,
    base_url_description: "RouterOS REST API base URL",
    secret_description: "RouterOS API password",
    name_description: "Optional RouterOS source name",
    insecure_description: "Skip TLS verification for RouterOS API",
    extra_fields: [
      {:username, :string, [allow_nil?: false, description: "RouterOS API username"]}
    ],
    create_accept: [:name, :base_url, :username, :password, :insecure_skip_verify, :mapper_job_id],
    update_accept: [:name, :base_url, :username, :password, :insecure_skip_verify]
end

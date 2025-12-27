defmodule ServiceRadar.Integrations do
  @moduledoc """
  Domain for external integration configuration.

  Manages configuration for data sources like Armis, SNMP, Syslog, etc.
  Configuration is stored in Postgres and synced to datasvc for Go/Rust
  services to consume.
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.Integrations.IntegrationSource
  end
end

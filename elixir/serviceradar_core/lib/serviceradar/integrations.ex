defmodule ServiceRadar.Integrations do
  @moduledoc """
  Domain for external integration configuration.

  Manages configuration for data sources like Armis, SNMP, Syslog, etc.
  Configuration is stored in Postgres and delivered to agents for sync
  processing.
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.Integrations.IntegrationSource
  end
end

defmodule ServiceRadar.Observability.ThreatIntel.Provider do
  @moduledoc """
  Behaviour for core-hosted threat-intel providers.

  Edge collectors can still emit the same `ThreatIntel.Page` contract as plugin
  results. Core-hosted providers should implement this behaviour so OTX, generic
  TAXII collections, and SIEM adapters share pagination and normalization
  semantics.
  """

  alias ServiceRadar.Observability.ThreatIntel.Page

  @type cursor :: map()
  @type config :: map()
  @type error :: {:error, term()}

  @callback fetch_page(config(), cursor()) :: {:ok, Page.t()} | error()
end

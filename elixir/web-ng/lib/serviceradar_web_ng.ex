defmodule ServiceRadarWebNG do
  @moduledoc """
  ServiceRadarWebNG keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  use Boundary,
    check: [apps: [:datasvc, :serviceradar_core, :serviceradar_srql]],
    deps: [Datasvc, ServiceRadar, ServiceRadarSRQL],
    exports: :all
end

defmodule ServiceRadarWebNGWeb.Plugs.ApiSourceContext do
  @moduledoc """
  Stamps `source: "api"` into the Ash context for every request on the
  `:ash_json_api` pipeline (`/api/v2/*`).

  The source metadata contract and changeset propagation are documented in
  `ServiceRadar.Observability.Changes.StampEventSource`.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Ash.PlugHelpers.set_context(conn, %{source: "api"})
  end
end

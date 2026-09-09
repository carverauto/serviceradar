defmodule ServiceRadar.Observability.Changes.StampEventSource do
  @moduledoc """
  Stamps the AshEvents `metadata["source"]` field with the request
  transport ("api" or "web") for actions AshEvents records.

  Reads a `:source` changeset-context flag. The `:ash_json_api` router
  pipeline (`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`) sets that
  flag via `ServiceRadarWebNGWeb.Plugs.ApiSourceContext`, which calls
  `Ash.PlugHelpers.set_context(conn, %{source: "api"})`; `AshJsonApi.Request`
  reads that back off the conn and `AshJsonApi.Controllers.Helpers` threads
  it onto the changeset with `Ash.Changeset.set_context/2` before
  `for_create`/`for_update`/`for_destroy` runs. The existing
  `Settings.RulesLive` (LiveView) path never sets this context, so it falls
  back to `"web"`.

  Written into `changeset.context[:ash_events_metadata]`, which
  `AshEvents.Events.ActionWrapperHelpers.create_event!/5` reads directly
  (`Map.get(changeset.context, :ash_events_metadata, %{})`) as the `metadata`
  attribute on the recorded `ServiceRadar.Observability.ApiEvent` row.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    source =
      case Map.get(changeset.context, :source) do
        value when is_binary(value) -> value
        _ -> "web"
      end

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: %{"source" => source}})
  end
end

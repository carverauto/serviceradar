defmodule ServiceRadarWebNGWeb.Plugs.ApiSourceContext do
  @moduledoc """
  Stamps `source: "api"` into the Ash context for every request on the
  `:ash_json_api` pipeline (`/api/v2/*`).

  `Ash.PlugHelpers.set_context/2` stores this on the conn's private `:ash`
  fields; `AshJsonApi.Request.from/7` reads it back with
  `Ash.PlugHelpers.get_context/1` (see `deps/ash_json_api/lib/ash_json_api/request.ex`)
  and `AshJsonApi.Controllers.Helpers` threads it onto the changeset with
  `Ash.Changeset.set_context/2` before `for_create`/`for_update`/`for_destroy`
  runs. `ServiceRadar.Observability.Changes.StampEventSource` reads it back
  off `changeset.context[:source]` to stamp the AshEvents `metadata["source"]`
  field. Routes outside this pipeline (the Settings LiveViews) never run this
  plug, so `StampEventSource` falls back to `"web"` for them.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Ash.PlugHelpers.set_context(conn, %{source: "api"})
  end
end

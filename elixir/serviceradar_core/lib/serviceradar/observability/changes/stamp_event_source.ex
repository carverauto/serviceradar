defmodule ServiceRadar.Observability.Changes.StampEventSource do
  @moduledoc """
  Stamps the AshEvents `metadata` map with the request transport
  (`metadata["source"]`, `"api"` or `"web"`) and the acting actor's id
  (`metadata["actor_id"]`), for actions AshEvents records.

  ## `metadata["source"]`

  Reads a `:source` changeset-context flag. The `:ash_json_api` router
  pipeline (`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`) sets that
  flag via `ServiceRadarWebNGWeb.Plugs.ApiSourceContext`, which calls
  `Ash.PlugHelpers.set_context(conn, %{source: "api"})`; `AshJsonApi.Request`
  reads that back off the conn and `AshJsonApi.Controllers.Helpers` threads
  it onto the changeset with `Ash.Changeset.set_context/2` before
  `for_create`/`for_update`/`for_destroy` runs. The existing
  `Settings.RulesLive` (LiveView) path never sets this context, so it falls
  back to `"web"`. Background catalog writes also use this default;
  `"web"` does not prove that a browser initiated the action.

  ## `metadata["actor_id"]`

  `AshEvents.Events.ActionWrapperHelpers.create_event!/5`'s
  `persist_actor_primary_key` (configured on
  `ServiceRadar.Observability.ApiEvent` as `:user_id` /
  `ServiceRadar.Identity.User`) only captures the actor's id when the actor
  is a struct whose `__struct__` exactly matches that destination resource.
  Neither real actor-construction path builds that struct: `set_ash_actor`
  (`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`, the `:ash_json_api`
  pipeline) and the `Ash.Scope.ToOpts` implementation for `Scope`
  (`elixir/web-ng/lib/serviceradar_web_ng/ash_scope.ex`, the LiveView path)
  both build a plain map (`%{id:, role:, email:, role_profile_id:,
  permissions:}`), so `ApiEvent.user_id` ends up `nil` on real requests
  through either transport. This change reads `context.actor` -- the third,
  `%Ash.Resource.Change.Context{}`, argument to `change/3` (not private
  `changeset.context` internals) -- and pulls an `:id` out of it regardless
  of whether the actor is that map or a genuine `%User{}` struct, so
  `ServiceRadar.Security.AuditHistory`'s adapter has a shape-independent
  fallback (see `adapt_ash_event/1`) even though `persist_actor_primary_key`
  stays configured on `ApiEvent` as a defense-in-depth path for callers that
  do pass a real `%User{}` struct.

  Pass `actor:` when constructing the changeset with
  `Ash.Changeset.for_create/for_update/for_destroy`: this change runs then.
  Supplying the actor only to the final `Ash.create/update/destroy` call
  does not rerun changes on an already validated action. The catalog
  attribution regression is in `stateful_alert_rule_events_test.exs`.
  System actors from `ServiceRadar.Actors.SystemActor` are maps and use
  the same metadata fallback.

  Both are written into `changeset.context[:ash_events_metadata]`, which
  `AshEvents.Events.ActionWrapperHelpers.create_event!/5` reads directly
  (`Map.get(changeset.context, :ash_events_metadata, %{})`) as the `metadata`
  attribute on the recorded `ServiceRadar.Observability.ApiEvent` row.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    source =
      case Map.get(changeset.context, :source) do
        value when is_binary(value) -> value
        _ -> "web"
      end

    actor_id =
      case context.actor do
        %{id: id} -> to_string(id)
        _ -> nil
      end

    Ash.Changeset.set_context(changeset, %{
      ash_events_metadata: %{"source" => source, "actor_id" => actor_id}
    })
  end
end

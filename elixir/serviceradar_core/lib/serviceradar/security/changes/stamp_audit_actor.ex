defmodule ServiceRadar.Security.Changes.StampAuditActor do
  @moduledoc """
  Copies the Ash actor and request metadata onto AshPaperTrail version rows.

  AshPaperTrail's `version_action_inputs` is built solely from the source
  action's own accepted attributes/arguments (see
  `AshPaperTrail.Resource.Changes.CreateNewVersion.build_notifications/2`) --
  it never includes the actor. `belongs_to_actor` is the extension's own
  actor-capture mechanism, but it only fires when the actor is a literal
  struct matching the configured destination type
  (`is_struct(actor) && actor.__struct__ == belongs_to_actor.destination`).
  Real ServiceRadar actors are plain maps (built by `set_ash_actor` in the
  JSON:API router pipeline and by the `Ash.Scope.ToOpts` implementation for
  the LiveView path), so `belongs_to_actor` never matches and the version's
  Actor column always renders "-".

  This change reads `context.actor` directly instead, which works for both a
  struct and a plain map, and writes it onto the version resource three ways:
  the `:actor`/`:actor_id`/`:request_id` attributes declared alongside this
  change in each resource's `paper_trail` mixin, and merged into
  `version_action_inputs` under `"actor"`/`"actor_id"`/`"request_id"` so the
  existing History LiveView template (`extract_actor/1`, which reads
  `version_action_inputs["actor"]`) renders it with no template changes.

  Copied from (and kept consistent with)
  `ServiceRadar.Inventory.VisibilityProfile.Changes.StampAuditContext` and
  `ServiceRadar.SweepJobs.SweepGroupExecution.Changes.StampAuditContext`,
  which already prove this pattern in production. This shared version has no
  domain-specific quirks, so the 15 resources it's wired into (via
  `ServiceRadar.Credentials.PaperTrailMixin`, `ServiceRadar.Security.PaperTrailMixin`,
  and `ServiceRadar.Dashboards.PaperTrailMixin`) use it directly rather than
  each getting its own copy.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    actor = actor_from_context(context)
    actor_payload = normalize_actor(actor)
    actor_id = actor_id(actor_payload)
    request_id = request_id(changeset, context, actor)

    changeset
    |> maybe_change_attribute(:actor, actor_payload)
    |> maybe_change_attribute(:actor_id, actor_id)
    |> maybe_change_attribute(:request_id, request_id)
    |> merge_action_inputs(actor_payload, actor_id, request_id)
  end

  defp actor_from_context(%{actor: actor}), do: actor
  defp actor_from_context(%{private: %{actor: actor}}), do: actor
  defp actor_from_context(_context), do: nil

  defp normalize_actor(%{} = actor) do
    Enum.reduce([:id, :email, :role], %{}, fn key, acc ->
      case Map.fetch(actor, key) do
        {:ok, value} when not is_nil(value) ->
          Map.put(acc, Atom.to_string(key), normalize_value(value))

        _ ->
          acc
      end
    end)
  end

  defp normalize_actor(_actor), do: nil

  defp actor_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp actor_id(_actor), do: nil

  defp request_id(changeset, context, actor) do
    first_present([
      changeset_context_value(changeset, :request_id),
      changeset_context_value(changeset, "request_id"),
      changeset_context_value(changeset, :correlation_id),
      changeset_context_value(changeset, "correlation_id"),
      context_value(context, :request_id),
      context_value(context, "request_id"),
      context_value(context, :correlation_id),
      context_value(context, "correlation_id"),
      map_value(actor, :request_id),
      map_value(actor, "request_id"),
      Logger.metadata()[:request_id]
    ])
  end

  defp context_value(%{private: private}, key), do: map_value(private, key)
  defp context_value(context, key), do: map_value(context, key)

  defp changeset_context_value(%{context: context}, key), do: map_value(context, key)
  defp changeset_context_value(_changeset, _key), do: nil

  defp map_value(%{} = map, key), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) and value != "" -> value
      value when not is_nil(value) -> to_string(value)
      _ -> nil
    end)
  end

  defp maybe_change_attribute(changeset, _attribute, nil), do: changeset

  defp maybe_change_attribute(changeset, attribute, value) do
    Ash.Changeset.change_attribute(changeset, attribute, value)
  end

  defp merge_action_inputs(changeset, actor_payload, actor_id, request_id) do
    audit_inputs =
      %{}
      |> maybe_put("actor", actor_payload)
      |> maybe_put("actor_id", actor_id)
      |> maybe_put("request_id", request_id)

    # `version_action_inputs` only exists on the version resource when the
    # source resource sets `store_action_inputs? true` (AshPaperTrail omits
    # the attribute entirely otherwise -- see
    # `AshPaperTrail.Resource.Transformers.CreateVersionResource`). Two of
    # this shared change's consumers (NetworkCredentialSecret, ActionInvocation)
    # set it to false, so reading/writing that attribute unconditionally
    # raises "No such attribute version_action_inputs". The dedicated
    # `:actor`/`:actor_id`/`:request_id` attributes still get set either way.
    has_inputs_attribute? =
      changeset.resource
      |> Ash.Resource.Info.attribute(:version_action_inputs)
      |> is_struct(Ash.Resource.Attribute)

    if map_size(audit_inputs) == 0 or not has_inputs_attribute? do
      changeset
    else
      inputs = Ash.Changeset.get_attribute(changeset, :version_action_inputs) || %{}

      Ash.Changeset.change_attribute(
        changeset,
        :version_action_inputs,
        Map.merge(inputs, audit_inputs)
      )
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: to_string(value)
end

defmodule ServiceRadar.Inventory.VisibilityProfile.Changes.StampAuditContext do
  @moduledoc """
  Copies the Ash actor and request metadata onto VisibilityProfile audit rows.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    actor = actor_from_context(context)
    actor_payload = normalize_actor(actor)
    actor_id = actor_id(actor_payload)
    request_id = request_id(context, actor)

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

  defp request_id(context, actor) do
    first_present([
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

    if map_size(audit_inputs) == 0 do
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

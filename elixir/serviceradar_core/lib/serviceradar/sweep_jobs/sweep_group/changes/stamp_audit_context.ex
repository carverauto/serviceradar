defmodule ServiceRadar.SweepJobs.SweepGroup.Changes.StampAuditContext do
  @moduledoc false

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    actor = actor_from_context(context)
    payload = normalize_actor(actor)

    changeset
    |> maybe_change(:actor, payload)
    |> maybe_change(:actor_id, actor_id(payload))
    |> maybe_change(:request_id, request_id(changeset, context))
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

  defp request_id(changeset, context) do
    first_present([
      map_value(changeset.context, :request_id),
      map_value(changeset.context, "request_id"),
      map_value(context, :request_id),
      map_value(context, "request_id"),
      Logger.metadata()[:request_id]
    ])
  end

  defp map_value(%{} = map, key), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) and value != "" -> value
      value when not is_nil(value) -> to_string(value)
      _ -> nil
    end)
  end

  defp maybe_change(changeset, _attribute, nil), do: changeset

  defp maybe_change(changeset, attribute, value) do
    Ash.Changeset.change_attribute(changeset, attribute, value)
  end

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: to_string(value)
end

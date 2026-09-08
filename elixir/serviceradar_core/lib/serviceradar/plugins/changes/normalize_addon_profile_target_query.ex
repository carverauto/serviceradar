defmodule ServiceRadar.Plugins.Changes.NormalizeAddonProfileTargetQuery do
  @moduledoc """
  Ensures add-on profile targeting is an agents SRQL query.

  An omitted entity becomes `in:agents`. A query that already names an entity is
  left alone so the following validation can reject `in:devices` and other
  inventories instead of silently rewriting them.
  """

  use Ash.Resource.Change

  alias ServiceRadar.SRQLQuery

  @impl true
  def change(changeset, _opts, _context) do
    case incoming_query(changeset) do
      :unchanged -> changeset
      query -> Ash.Changeset.change_attribute(changeset, :target_query, normalize(query))
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp incoming_query(changeset) do
    case Ash.Changeset.fetch_change(changeset, :target_query) do
      {:ok, value} ->
        value

      :error when changeset.action_type == :create ->
        Ash.Changeset.get_attribute(changeset, :target_query)

      :error ->
        :unchanged
    end
  end

  defp normalize(value) when is_binary(value), do: SRQLQuery.ensure_target(value, :agents)
  defp normalize(_value), do: "in:agents"
end

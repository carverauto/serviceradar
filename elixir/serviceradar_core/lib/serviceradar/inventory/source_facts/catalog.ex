defmodule ServiceRadar.Inventory.SourceFacts.Catalog do
  @moduledoc """
  Sync operator fact-authority checkboxes into the platform catalog.

  Plugin manifests never write these rows.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.SourceFactAuthority
  alias ServiceRadar.Inventory.SourceFacts

  @spec sync(String.t(), String.t(), String.t(), String.t() | nil, [String.t()], keyword()) ::
          :ok | {:error, term()}
  def sync(source_kind, source_ref, source, source_instance, fact_keys, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:source_fact_authority))
    wanted = fact_keys |> List.wrap() |> Enum.filter(&SourceFacts.key?/1) |> Enum.uniq()

    Enum.each(SourceFacts.keys(), fn fact_key ->
      enabled? = fact_key in wanted

      attrs = %{
        source_kind: source_kind,
        source_ref: to_string(source_ref),
        source: source,
        source_instance: source_instance,
        fact_key: fact_key,
        rank: 1,
        enabled: enabled?
      }

      case SourceFactAuthority
           |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
           |> Ash.create() do
        {:ok, _row} -> :ok
        {:error, reason} -> throw({:error, reason})
      end
    end)

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end
end

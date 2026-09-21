defmodule ServiceRadar.NetworkChanges.Ingest do
  @moduledoc """
  Persist a change in CNPG and project it to Dgraph.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.NetworkChanges.Change
  alias ServiceRadar.NetworkChanges.Projector

  @spec submit(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def submit(attrs, opts \\ []) when is_map(attrs) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:network_changes_ingest))
    projector = Keyword.get(opts, :projector, &Projector.project/1)

    with {:ok, change} <-
           Ash.create(Change, attrs, actor: actor, domain: ServiceRadar.NetworkChanges),
         :ok <- projector.(change) do
      {:ok, change}
    end
  end
end

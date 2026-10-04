defmodule ServiceRadar.Analytics.StarRocks.Retention.Store do
  @moduledoc """
  CNPG access for the retention applier, as the system actor.

  `Retention` takes the store as an option so its reconcile logic can be
  exercised without a database; this is the store it uses in a running core.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.WarehouseRetentionSetting

  @spec list() :: {:ok, [WarehouseRetentionSetting.t()]} | {:error, term()}
  def list do
    WarehouseRetentionSetting.list(actor: actor())
  rescue
    error -> {:error, error}
  end

  @spec seed(String.t(), pos_integer()) :: {:ok, WarehouseRetentionSetting.t()} | {:error, term()}
  def seed(dataset, days) do
    WarehouseRetentionSetting.seed(%{dataset: dataset, days: days, seed_days: days},
      actor: actor()
    )
  rescue
    error -> {:error, error}
  end

  @spec record_seed(WarehouseRetentionSetting.t(), map()) ::
          {:ok, WarehouseRetentionSetting.t()} | {:error, term()}
  def record_seed(row, attrs) do
    WarehouseRetentionSetting.record_seed(row, attrs, actor: actor())
  rescue
    error -> {:error, error}
  end

  @spec record_outcome(WarehouseRetentionSetting.t(), map()) ::
          {:ok, WarehouseRetentionSetting.t()} | {:error, term()}
  def record_outcome(row, attrs) do
    WarehouseRetentionSetting.record_outcome(row, attrs, actor: actor())
  rescue
    error -> {:error, error}
  end

  defp actor, do: SystemActor.system(:warehouse_retention)
end

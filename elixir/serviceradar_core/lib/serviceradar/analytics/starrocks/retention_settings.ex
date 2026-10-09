defmodule ServiceRadar.Analytics.StarRocks.RetentionSettings do
  @moduledoc """
  The Data retention settings page's view of the warehouse retention settings.

  Lists every dataset with its stored row (or the product default while core has
  not stored one) and saves an operator's change after checking the dataset's
  floor. Authorization is the `WarehouseRetentionSetting` policies: reads need
  `settings.data_retention.view` or `.manage`, saves need `.manage`.
  """

  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Observability.WarehouseRetentionSetting

  @type entry :: %{
          dataset: atom(),
          tables: [String.t()],
          days: pos_integer(),
          stored?: boolean(),
          seed_days: pos_integer() | nil,
          default_days: pos_integer(),
          min_days: pos_integer(),
          min_partitions: pos_integer(),
          storage_warning?: boolean(),
          updated_by: String.t() | nil,
          updated_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          last_applied_days: pos_integer() | nil,
          last_applied_status: String.t() | nil,
          last_applied_error: String.t() | nil,
          last_applied_at: DateTime.t() | nil
        }

  @doc "Health of the retention applier (running state, last reconcile time and outcome)."
  defdelegate applier_health(opts \\ []), to: Retention

  @doc "Every dataset, in display order, as the actor in `opts` may see it."
  @spec list(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def list(opts) do
    with {:ok, rows} <- WarehouseRetentionSetting.list(opts) do
      by_dataset = Map.new(rows, &{&1.dataset, &1})
      {:ok, Enum.map(Retention.datasets(), &entry(&1, Map.get(by_dataset, Atom.to_string(&1))))}
    end
  end

  @doc """
  Saves `days` for a dataset (given by name) as the actor in `opts`.

  Values below the dataset's floor or above the maximum are rejected before
  anything is written. Core's applier picks the change up from the notifier's
  broadcast and records whether the warehouse took it.
  """
  @spec save(String.t(), integer(), keyword()) ::
          {:ok, WarehouseRetentionSetting.t()} | {:error, term()}
  def save(dataset_name, days, opts) when is_binary(dataset_name) do
    with {:ok, dataset} <- dataset(dataset_name),
         :ok <- Retention.validate_days(dataset, days),
         {:ok, rows} <- WarehouseRetentionSetting.list(opts) do
      case Enum.find(rows, &(&1.dataset == dataset_name)) do
        nil ->
          WarehouseRetentionSetting.create_setting(%{dataset: dataset_name, days: days}, opts)

        row ->
          WarehouseRetentionSetting.set_days(row, %{days: days}, opts)
      end
    end
  end

  defp dataset(name) do
    case Enum.find(Retention.datasets(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, "unknown dataset #{inspect(name)}"}
      dataset -> {:ok, dataset}
    end
  end

  defp entry(dataset, row) do
    days = if row, do: row.days, else: Retention.default_days(dataset)

    %{
      dataset: dataset,
      tables: Retention.tables_for(dataset),
      days: days,
      stored?: row != nil,
      seed_days: row && row.seed_days,
      default_days: Retention.default_days(dataset),
      min_days: Retention.min_days(dataset),
      min_partitions: Retention.min_partitions(dataset),
      storage_warning?: Retention.storage_warning?(dataset, days),
      updated_by: row && row.updated_by,
      updated_at: row && row.updated_at,
      inserted_at: row && row.inserted_at,
      last_applied_days: row && row.last_applied_days,
      last_applied_status: row && row.last_applied_status,
      last_applied_error: row && row.last_applied_error,
      last_applied_at: row && row.last_applied_at
    }
  end
end

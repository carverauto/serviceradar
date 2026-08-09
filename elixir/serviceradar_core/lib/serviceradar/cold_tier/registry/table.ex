defmodule ServiceRadar.ColdTier.Registry.Table do
  @moduledoc "One offloadable hypertable's cold-tier contract (see ServiceRadar.ColdTier.Registry)."

  @enforce_keys [
    :table,
    :time_column,
    :signal_class,
    :retention_config_key,
    :default_hot_days,
    :chunk_interval_key,
    :default_chunk_hours,
    :update_prone,
    :tiebreakers,
    :columns
  ]
  defstruct @enforce_keys

  @type column :: {name :: String.t(), source_type :: String.t(), export_cast :: :none | :text}

  @type t :: %__MODULE__{
          table: String.t(),
          time_column: String.t(),
          signal_class: atom(),
          retention_config_key: atom(),
          default_hot_days: pos_integer(),
          chunk_interval_key: atom(),
          default_chunk_hours: pos_integer(),
          update_prone: boolean(),
          tiebreakers: [String.t()],
          columns: [column()]
        }
end

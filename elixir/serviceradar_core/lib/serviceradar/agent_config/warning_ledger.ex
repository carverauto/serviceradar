defmodule ServiceRadar.AgentConfig.WarningLedger do
  @moduledoc """
  Remembers what config generation last warned about per subject, so a
  condition that persists is reported once per change instead of on every
  agent poll.

  Agent config is rebuilt on every poll, so a warning raised while building it
  repeats for as long as its cause persists. A caller passes `changed?/2` a
  stable subject and a fingerprint of what it is about to report: the answer is
  `true` the first time and whenever the fingerprint differs from the one
  recorded, and `false` while it repeats. `forget/1` clears the subject once the
  condition is gone, so a recurrence is reported again.

  The table holds one row per subject and is owned by this process. Where the
  process is not running, every call reports a change, which is the behaviour
  without a ledger.
  """

  use GenServer

  @table :agent_config_warning_ledger

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records `fingerprint` for `subject` and returns whether it differs from the
  fingerprint recorded before.
  """
  @spec changed?(term(), term()) :: boolean()
  def changed?(subject, fingerprint) do
    case :ets.lookup(@table, subject) do
      [{^subject, ^fingerprint}] ->
        false

      _ ->
        :ets.insert(@table, {subject, fingerprint})
        true
    end
  rescue
    # No table: the owner is not running here.
    ArgumentError -> true
  end

  @doc "Forgets `subject`, so the next warning about it is reported."
  @spec forget(term()) :: :ok
  def forget(subject) do
    :ets.delete(@table, subject)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    {:ok, :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])}
  end
end

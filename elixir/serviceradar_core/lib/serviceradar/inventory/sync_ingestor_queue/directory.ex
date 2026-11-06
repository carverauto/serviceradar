defmodule ServiceRadar.Inventory.SyncIngestorQueue.Directory do
  @moduledoc """
  Cluster-wide answer to "which process is the sync ingestion queue?".

  `ServiceRadar.Inventory.SyncIngestorQueue` runs on the coordinator only: it is
  started by `ServiceRadar.Ingestion.Supervisor`, a coordinator child. Its
  producers are not confined to that node. EventWriter workers run on every
  core replica, and the edge-record projectors they run (mapper, netprobe and
  sync-page discovery, add-on discovery telemetry) hand their updates to the
  queue. A registered name resolves only on its own node, so from every other
  replica the queue looked absent.

  The queue joins an OTP `:pg` group named for its registered name, and `:pg`
  replicates that membership to every node in the scope, where it is a local
  lookup. Membership is tied to the queue process, so a queue stops being
  advertised the moment it or its node goes away.

  Membership is also held by the scope process. A restarted scope has forgotten
  the queue, so the queue monitors the scope it joined and advertises itself
  again once a scope is running.
  """

  @scope :serviceradar_sync_ingest_queue

  def child_spec(_opts) do
    %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}
  end

  @doc """
  Advertises `pid`, which must be local, as the queue registered as `name`, and
  returns the scope process that now holds the membership. Returns `:error`
  when no scope is running; until `pid` is advertised again only same-node
  callers find it.
  """
  @spec advertise(atom(), pid()) :: {:ok, pid()} | :error
  def advertise(name, pid) when is_atom(name) and is_pid(pid) do
    case Process.whereis(@scope) do
      nil ->
        :error

      scope ->
        :ok = :pg.join(scope, name, pid)
        {:ok, scope}
    end
  catch
    :exit, _reason -> :error
  end

  @doc """
  Resolves `server` to a queue pid: the process registered under it on this
  node, else the queue advertised under that name on another node. Returns nil
  when neither exists.
  """
  @spec whereis(GenServer.server()) :: pid() | nil
  def whereis(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      nil when is_atom(server) -> advertised(server)
      _other -> nil
    end
  end

  defp advertised(name) do
    if Process.whereis(@scope) do
      case :pg.get_members(@scope, name) do
        [pid | _] -> pid
        [] -> nil
      end
    end
  end
end

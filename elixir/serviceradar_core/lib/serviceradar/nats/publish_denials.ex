defmodule ServiceRadar.NATS.PublishDenials do
  @moduledoc """
  The publishes the NATS broker denied on this node, by connection and subject.

  A NATS server that denies a publish does not answer the request. It sends the connection an
  asynchronous `-ERR 'Permissions Violation for Publish to "<subject>"'`, and Gnat only reports
  that through `:error_logger` (see `ServiceRadar.NATS.BrokerErrorLogFilter`, which records it
  here). A JetStream publish waiting for its PubAck therefore just times out, and a caller that
  retries timeouts retries a publish that can never succeed, once per PubAck timeout.

  `ServiceRadar.NATS.JetStreamPublish` reads these records to fail such a publish as
  `ServiceRadar.NATS.PublishDeniedError`:

    * a PubAck timeout on a connection that the broker denied that subject while the publish
      waited is the denial, not a slow broker;
    * for `hold_ms/0` after a denial, a publish of that subject on that connection is refused
      without being sent, so a backlog of them does not cost one PubAck timeout each. The first
      publish after the hold goes to the broker again, which is how a corrected grant is seen.

  A timeout with no recorded denial stays a timeout. Records are per connection, because the
  node's connections can authenticate as different NATS users.

  The table is created by the process that installs the log filter (`init/0`). Without it,
  nothing is recorded and every lookup is false, so publishes behave as if no denial was seen.
  """

  @table __MODULE__
  @hold_ms 60_000
  @denial ~r/\APermissions Violation for Publish to "(?<subject>[^"]+)"\z/

  @doc "How long a denial refuses further publishes of its subject on its connection."
  @spec hold_ms() :: pos_integer()
  def hold_ms, do: @hold_ms

  @doc """
  Creates the node's table if it does not exist. The caller owns it, so it is called from a
  long-lived process: the NATS supervisor that installs the log filter.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    # Another process created it between the check and the call.
    ArgumentError -> :ok
  end

  @doc """
  Records a broker `-ERR` text received on `conn` when it is a publish denial. Returns the
  denied subject, or nil for any other text. Never raises: it runs inside a logger filter, and
  a filter that raises is removed.
  """
  @spec note(pid(), term()) :: String.t() | nil
  def note(conn, message) when is_pid(conn) and is_binary(message) do
    case Regex.named_captures(@denial, message) do
      %{"subject" => subject} ->
        insert({conn, subject}, now_ms())
        subject

      nil ->
        nil
    end
  end

  def note(_conn, _message), do: nil

  @doc "Whether the broker denied `subject` on `conn` at or after `since_ms` (`now_ms/0` time)."
  @spec denied_since?(pid(), String.t(), integer()) :: boolean()
  def denied_since?(conn, subject, since_ms) do
    case lookup({conn, subject}) do
      at when is_integer(at) -> at >= since_ms
      nil -> false
    end
  end

  @doc "Whether a denial of `subject` on `conn` is recent enough to refuse its publish unsent."
  @spec held?(pid(), String.t()) :: boolean()
  def held?(conn, subject), do: denied_since?(conn, subject, now_ms() - @hold_ms)

  @doc "The clock `denied_since?/3` compares against, in milliseconds."
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  defp insert(key, at) do
    :ets.insert(@table, {key, at})
    prune(at)
  rescue
    ArgumentError -> :ok
  end

  # A record outlives its hold only until the next denial, which drops every expired one, so
  # the table holds at most the subjects denied within one hold.
  defp prune(now) do
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now - @hold_ms}], [true]}])
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, at}] -> at
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end
end

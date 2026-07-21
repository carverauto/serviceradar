defmodule ServiceRadarAgentGateway.EdgePrefix do
  @moduledoc """
  Gateway-side contiguous resolved-prefix tracker (unify-sweep-results-proto task
  3.5), the Elixir peer of the Go reference core `go/pkg/edge/gwprefix`.

  Frames publish asynchronously and may earn their durable PubAck out of order.
  The resolved watermark reported back to the agent advances only across a
  CONTIGUOUS run whose members each have a durable outcome -- a primary-stream
  PubAck (`:accepted`) or an audit/DLQ PubAck (`:rejected`). A sequence with no
  durable outcome yet (NATS unavailable/saturated) is never recorded, so the
  prefix withholds at that gap and the agent keeps the frame spooled.
  """

  defstruct base: 1, resolved: 0, durable: %{}

  @type status :: :accepted | :rejected
  @type t :: %__MODULE__{base: pos_integer(), resolved: non_neg_integer(), durable: map()}

  @doc "A tracker for a lane beginning at `first` (>= 1)."
  @spec new(pos_integer()) :: t()
  def new(first) when is_integer(first) and first >= 1, do: %__MODULE__{base: first, resolved: first - 1, durable: %{}}

  def new(_), do: new(1)

  @doc """
  Records a durable outcome and advances the contiguous prefix. Only `:accepted`
  or `:rejected` may be recorded; a pending outcome must not be passed here.
  """
  @spec record(t(), non_neg_integer(), status()) :: {:ok, t()} | {:error, atom()}
  def record(%__MODULE__{} = t, seq, status) when status in [:accepted, :rejected] do
    cond do
      seq < t.base ->
        {:error, :below_base}

      seq <= t.resolved ->
        {:ok, t}

      Map.has_key?(t.durable, seq) and Map.get(t.durable, seq) != status ->
        {:error, :conflict}

      Map.has_key?(t.durable, seq) ->
        {:ok, t}

      true ->
        {:ok, advance(%{t | durable: Map.put(t.durable, seq, status)})}
    end
  end

  def record(%__MODULE__{}, _seq, _status), do: {:error, :not_durable}

  @doc "The contiguous resolved watermark."
  @spec resolved_through(t()) :: non_neg_integer()
  def resolved_through(%__MODULE__{resolved: r}), do: r

  @doc "How many durable outcomes are held waiting for an earlier gap to fill."
  @spec pending_out_of_order(t()) :: non_neg_integer()
  def pending_out_of_order(%__MODULE__{durable: d}), do: map_size(d)

  defp advance(t) do
    next = t.resolved + 1

    case Map.pop(t.durable, next) do
      {nil, _durable} -> t
      {_status, durable} -> advance(%{t | resolved: next, durable: durable})
    end
  end
end

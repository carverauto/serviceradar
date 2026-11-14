defmodule ServiceRadar.EventWriter.EdgeRecordRefusedError do
  @moduledoc """
  The failure of an edge record that `ServiceRadar.EventWriter.Processors.EdgeRecord.ingest/4`
  refused: a header, slot, wire or contract check failed, its grant or assignment is no longer
  current, its delivery slot or event id is bound to other bytes, or its projector refused it.
  `reason` is normalized to a bare `atom()` or 2-tuple `{reason_atom, detail}` so dead-letter
  routing (`ServiceRadar.EventWriter.Telemetry.failure_class/1`) always extracts the specific
  `reason_atom`.

  The same bytes are refused again on every redelivery, so the pipeline dead-letters the record
  on its first delivery (`ServiceRadar.EventWriter.EdgeRecordDeadLetter.terminal?/1`), where it
  stays for inspection and for replay once its cause is fixed.
  """

  defexception [:reason]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{reason: normalize_reason(Keyword.get(opts, :reason))}
  end

  def exception(reason) do
    %__MODULE__{reason: normalize_reason(reason)}
  end

  @doc """
  Normalizes a refusal reason to a bare `atom()` or 2-tuple `{reason_atom, detail}`,
  unwrapping any nested `{:refused, inner}` wrapper and collapsing 3+ tuples.
  """
  @spec normalize_reason(term()) :: atom() | {atom(), term()}
  def normalize_reason({:refused, inner}), do: normalize_reason(inner)

  def normalize_reason({:refused, reason_atom, detail}) when is_atom(reason_atom),
    do: {reason_atom, detail}

  def normalize_reason(reason) when is_atom(reason) and not is_nil(reason), do: reason

  def normalize_reason({reason_atom, detail})
      when is_atom(reason_atom) and reason_atom != :refused,
      do: {reason_atom, detail}

  def normalize_reason(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 3 do
    case elem(tuple, 0) do
      reason_atom when is_atom(reason_atom) ->
        rest = tuple |> Tuple.to_list() |> tl() |> List.to_tuple()
        {reason_atom, rest}

      _ ->
        {:refused_record, tuple}
    end
  end

  def normalize_reason(other), do: {:refused_record, other}

  @impl true
  def message(%__MODULE__{reason: reason}) do
    normalized = normalize_reason(reason)
    "edge record refused: #{inspect(normalized, limit: 8, printable_limit: 128)}"
  end
end

defmodule ServiceRadar.Observability.JsonApiCompositeId do
  @moduledoc """
  Encodes a null composite JSON:API id part without changing the stored value.

  `AshJsonApi.Resource.encode_primary_key/1` stringifies every composite key
  part. A null part (`otel_metrics.span_id`, hourly `device_id`) raises
  `Protocol.UndefinedError` and the index page fails. This preparation runs
  on the telemetry `api_index` actions and wraps those parts on the records
  the serializer receives.

  A null part is the single character U+001F. Text that already starts with
  U+001F is prefixed with a second U+001F, so null stays distinct from `""`
  and from every real string. Every other part stays `to_string/1`, so an id
  with no null part is unchanged. The attribute stays null or the original
  string. `decode_part/1` reverses the id text.
  """

  use Ash.Resource.Preparation

  alias AshJsonApi.Resource.Info

  @null_part <<0x1F>>

  defstruct [:id_text, :attribute]

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, records ->
      {:ok, Enum.map(records, &encode_record/1)}
    end)
  end

  @doc """
  Id text for one composite key part.

  `nil` is U+001F. A string that starts with U+001F is prefixed with another
  U+001F. Anything else is `to_string/1`.
  """
  def encode_part(value) do
    case wrap_part(value) do
      %__MODULE__{id_text: text} -> text
      other -> to_string(other)
    end
  end

  @doc """
  Reverses `encode_part/1`.

  The single character U+001F is `nil`. A string that starts with two U+001F
  characters drops that prefix. Every other string is returned unchanged.
  """
  def decode_part(@null_part), do: nil
  def decode_part(<<0x1F, 0x1F, rest::binary>>), do: rest
  def decode_part(value) when is_binary(value), do: value

  @doc false
  def encode_record(%resource{} = record) do
    case Info.primary_key_fields(resource) do
      [_, _ | _] = keys ->
        Enum.reduce(keys, record, &wrap_field/2)

      _keys ->
        record
    end
  end

  defp wrap_field(key, record), do: Map.update!(record, key, &wrap_part/1)

  defp wrap_part(%__MODULE__{} = wrapped), do: wrapped
  defp wrap_part(nil), do: %__MODULE__{id_text: @null_part, attribute: nil}

  defp wrap_part(<<0x1F, _::binary>> = text) do
    %__MODULE__{id_text: <<0x1F, 0x1F, text::binary>>, attribute: text}
  end

  defp wrap_part(value), do: value
end

defimpl String.Chars, for: ServiceRadar.Observability.JsonApiCompositeId do
  def to_string(%{id_text: text}), do: text
end

defimpl Jason.Encoder, for: ServiceRadar.Observability.JsonApiCompositeId do
  def encode(%{attribute: value}, opts), do: Jason.Encoder.encode(value, opts)
end

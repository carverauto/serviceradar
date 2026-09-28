defmodule ServiceRadar.EventWriter.StableId do
  @moduledoc """
  Row ids derived from a name, so a JetStream message redelivered after a
  failed batch maps to the rows it already stored instead of new ones.

  EventWriter tables insert with `on_conflict: :nothing` on their primary key,
  so a stable id is what makes a redelivery store, promote and alert nothing a
  second time.
  """

  @doc """
  A version-5-layout UUID (raw 16 bytes) from the SHA-256 of `name`.

  This is the layout `Processors.Events` has always used to coerce a non-UUID
  event id, so ids it produced before are unchanged.
  """
  @spec uuid(iodata()) :: <<_::128>>
  def uuid(name) do
    <<u0::48, _::4, u1::12, _::2, u2::62, _rest::bitstring>> = :crypto.hash(:sha256, name)
    <<u0::48, 5::4, u1::12, 2::2, u2::62>>
  end

  @doc """
  The identity of the JetStream message that carried `metadata`: its
  `Nats-Msg-Id` when the producer set one, else its stream and stream
  sequence. `nil` for a message that did not come from JetStream.
  """
  @spec message_identity(map()) :: String.t() | nil
  def message_identity(metadata) when is_map(metadata) do
    msg_id_header(metadata[:headers]) || stream_position(metadata[:jetstream_ack])
  end

  def message_identity(_metadata), do: nil

  defp msg_id_header(headers) when is_list(headers) or is_map(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(value) and value != "" ->
        if String.downcase(to_string(key)) == "nats-msg-id", do: "msg:" <> value

      _ ->
        nil
    end)
  end

  defp msg_id_header(_headers), do: nil

  defp stream_position(%{stream: stream, stream_sequence: sequence})
       when is_binary(stream) and is_integer(sequence),
       do: "seq:#{stream}:#{sequence}"

  defp stream_position(_ack), do: nil
end

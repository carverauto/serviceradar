defmodule ServiceRadar.EventWriter.TransientMessageError do
  @moduledoc """
  The failure of a message for a reason that is not the message's fault, so a
  later delivery of the same bytes can succeed: a database error or timeout.
  `reason` is the processor's reason.

  `ServiceRadar.EventWriter.Pipeline` NAKs such a message with backoff rather
  than for immediate redelivery, and terminates it as a dead letter on its
  final delivery.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "message not stored yet: #{inspect(reason, limit: 8, printable_limit: 128)}"
end

defmodule ServiceRadar.EventWriter.TerminalMessageError do
  @moduledoc """
  The failure of a message its processor knows can never be stored, whatever
  delivery it is on: a schema or validation failure of the payload itself.
  `reason` is the processor's reason.

  `ServiceRadar.EventWriter.Pipeline` terminates (`+TERM`) such a message on
  the delivery that failed and records it as a dead letter, as it does for a
  message on its final delivery. A processor returns it only once anything it
  must record about the failure has been stored.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "message can never be stored: #{inspect(reason, limit: 8, printable_limit: 128)}"
end

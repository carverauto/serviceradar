defmodule ServiceRadar.NATS.PublishDeniedError do
  @moduledoc """
  A publish the NATS broker refused for the connection's permissions.

  `ServiceRadar.NATS.JetStreamPublish` returns it as `{:error, %PublishDeniedError{}}` when the
  broker denied the subject (see `ServiceRadar.NATS.PublishDenials`). Retrying does not help
  until the connection's grant changes, so a caller that retries on failure treats it as
  terminal: the EventWriter dead-letters an edge record whose republish was denied instead of
  redelivering it.
  """

  defexception [:subject]

  @type t :: %__MODULE__{subject: String.t()}

  @impl true
  def message(%__MODULE__{subject: subject}),
    do: "NATS broker denied publish to #{inspect(subject)}"

  @doc """
  The denial inside a failure reason that wraps it in tagged tuples, as projectors do
  (`{:metrics_publish_failed, %PublishDeniedError{}}`), or nil.
  """
  @spec find(term()) :: t() | nil
  def find(%__MODULE__{} = denied), do: denied
  def find({_tag, reason}), do: find(reason)
  def find(_reason), do: nil
end

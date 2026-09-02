defmodule ServiceRadar.Credentials.CredentialUsage.Consumer do
  @moduledoc """
  Redacted identity of a configured credential consumer.

  Routes are intentionally owned by web-ng. Core returns only stable resource
  identity and a human-readable label.
  """

  @enforce_keys [:kind, :id, :label]
  defstruct [:kind, :id, :label, :slot]

  @type t :: %__MODULE__{
          kind: atom(),
          id: String.t(),
          label: String.t(),
          slot: atom() | nil
        }
end

defmodule ServiceRadar.Credentials.CredentialUsage.LiveGrant do
  @moduledoc """
  Redacted identity and lifetime fields for a live broker grant.

  The raw grant resource is never returned because it contains injection,
  request-policy, and metadata fields that do not belong in settings UI state.
  """

  @enforce_keys [:id, :status, :consumer_kind, :purpose, :expires_at]
  defstruct [:id, :status, :consumer_kind, :consumer_id, :purpose, :expires_at]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :issued | :active,
          consumer_kind: atom(),
          consumer_id: String.t() | nil,
          purpose: String.t(),
          expires_at: DateTime.t()
        }
end

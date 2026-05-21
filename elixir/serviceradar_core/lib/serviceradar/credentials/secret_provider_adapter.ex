defmodule ServiceRadar.Credentials.SecretProviderAdapter do
  @moduledoc """
  Behaviour implemented by external secret provider adapters.

  Adapters return secret values only to the credential broker. Callers must not
  invoke adapters directly from plugin, browser, or untrusted request paths.
  """

  @type secret_reference :: %{
          required(:provider_type) => atom(),
          required(:external_secret_ref) => String.t(),
          optional(:external_secret_version) => String.t() | nil,
          optional(:external_secret_fields) => map(),
          optional(:credential_kind) => atom() | String.t(),
          optional(:metadata) => map()
        }

  @type provider :: map() | struct()
  @type resolved :: %{
          required(:value) => String.t(),
          optional(:lease_expires_at) => DateTime.t() | nil,
          optional(:cache_status) => atom(),
          optional(:metadata) => map()
        }

  @callback resolve(secret_reference(), provider(), keyword()) ::
              {:ok, resolved()} | {:error, atom() | {atom(), term()}}

  @callback test(secret_reference(), provider(), keyword()) ::
              {:ok, map()} | {:error, atom() | {atom(), term()}}

  @optional_callbacks test: 3
end

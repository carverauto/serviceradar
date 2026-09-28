defmodule ServiceRadar.Credentials.SecretProviderAdapters.Stub do
  @moduledoc """
  Test-only external secret provider adapter.

  The adapter intentionally has no network behavior. It lets broker tests and
  future UI/API tests exercise external-reference semantics before a real
  Delinea/CyberArk/Vault adapter exists.

  It returns plaintext from a reference's unencrypted metadata, which is not an
  acceptable store for a credential outside tests. It is therefore gated by
  `config :serviceradar_core, :stub_secret_provider_enabled`, which only
  `config/test.exs` sets. While the gate is off (the default):

    * `CredentialSecretProvider` refuses to create or update a `:stub` provider,
    * `SecretBroker` finds no built-in adapter for `:stub`, so a `:stub` row
      already present in a database fails with `:adapter_unavailable`, and
    * this adapter refuses to resolve even when a caller names it directly.
  """

  @behaviour ServiceRadar.Credentials.SecretProviderAdapter

  @doc """
  Whether the stub provider may be created and resolved in this environment.

  Read at call time rather than compile time, so the value comes from the
  running application's configuration.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:serviceradar_core, :stub_secret_provider_enabled, false) == true
  end

  @impl true
  def resolve(reference, _provider, opts) do
    if enabled?() do
      resolve_stub_value(reference, opts)
    else
      {:error, :adapter_unavailable}
    end
  end

  @impl true
  def test(reference, provider, opts) do
    case resolve(reference, provider, opts) do
      {:ok, _resolved} -> {:ok, %{status: :success, adapter: :stub}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_stub_value(reference, opts) do
    value =
      Keyword.get(opts, :stub_secret_value) ||
        get_in(reference, [:metadata, "stub_secret_value"]) ||
        get_in(reference, [:metadata, :stub_secret_value])

    case value do
      value when is_binary(value) and value != "" ->
        {:ok, %{value: value, cache_status: :disabled, metadata: %{"adapter" => "stub"}}}

      _ ->
        {:error, :not_found}
    end
  end
end

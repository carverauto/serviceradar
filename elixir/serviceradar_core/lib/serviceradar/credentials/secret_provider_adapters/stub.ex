defmodule ServiceRadar.Credentials.SecretProviderAdapters.Stub do
  @moduledoc """
  Test-only external secret provider adapter.

  The adapter intentionally has no network behavior. It lets broker tests and
  future UI/API tests exercise external-reference semantics before a real
  Delinea/CyberArk/Vault adapter exists.
  """

  @behaviour ServiceRadar.Credentials.SecretProviderAdapter

  @impl true
  def resolve(reference, _provider, opts) do
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

  @impl true
  def test(reference, provider, opts) do
    case resolve(reference, provider, opts) do
      {:ok, _resolved} -> {:ok, %{status: :success, adapter: :stub}}
      {:error, reason} -> {:error, reason}
    end
  end
end

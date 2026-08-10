defmodule ServiceRadar.Notifications.Callbacks.AppRegistryTest do
  @moduledoc """
  Resolution of inbound callback key material (task 4.3.1a).

  The lookup is injected, so these run with no database - but deliberately NOT
  the decryption. `Edge.Crypto` is exercised for real, because a seam there would
  mean the one thing this module does with key material is the one thing nothing
  checks. The cost is `async: false`, since the crypto secret is application
  environment.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Notifications.Callbacks.AppRegistry

  @app_id "A0123456789"

  setup do
    original = Application.get_env(:serviceradar_core, :crypto_secret)
    Application.put_env(:serviceradar_core, :crypto_secret, String.duplicate("a", 32))

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, :crypto_secret)
        value -> Application.put_env(:serviceradar_core, :crypto_secret, value)
      end
    end)

    :ok
  end

  defp lookup_returning(result) do
    [lookup: fn _provider_key, _external_app_id -> result end]
  end

  test "returns the decrypted secret for a registered app" do
    secret = "slack-signing-secret-for-tests-only"

    opts = lookup_returning({:ok, %{signing_secret_ciphertext: Crypto.encrypt(secret)}})

    assert {:ok, ^secret} = AppRegistry.signing_secret(:slack, @app_id, opts)
  end

  test "reports an unregistered app distinctly from unreadable key material" do
    # An operator chasing :app_not_registered registers the app. An operator
    # chasing :key_material_unreadable has a CLOAK_KEY problem, and no amount of
    # re-registering will fix it. One error value for both is how an afternoon
    # goes into rotating a secret that was never the problem.
    assert {:error, :app_not_registered} =
             AppRegistry.signing_secret(:slack, @app_id, lookup_returning({:error, :not_found}))

    assert {:error, :key_material_unreadable} =
             AppRegistry.signing_secret(
               :slack,
               @app_id,
               lookup_returning({:ok, %{signing_secret_ciphertext: "not-a-ciphertext"}})
             )
  end

  test "treats a missing row as unregistered rather than raising" do
    assert {:error, :app_not_registered} =
             AppRegistry.signing_secret(:slack, @app_id, lookup_returning({:ok, nil}))
  end

  test "refuses a blank app id without consulting the store" do
    test = self()

    opts = [
      lookup: fn _provider, _app ->
        send(test, :consulted)
        {:ok, nil}
      end
    ]

    assert {:error, :app_not_registered} = AppRegistry.signing_secret(:slack, "", opts)
    refute_received :consulted
  end

  test "refuses an empty decrypted secret rather than verifying against it" do
    # An empty secret would make every HMAC comparison a comparison against a
    # constant, which is worse than refusing.
    opts = lookup_returning({:ok, %{signing_secret_ciphertext: Crypto.encrypt("")}})

    assert {:error, :key_material_unreadable} = AppRegistry.signing_secret(:slack, @app_id, opts)
  end
end

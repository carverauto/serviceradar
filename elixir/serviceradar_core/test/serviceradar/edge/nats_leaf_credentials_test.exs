defmodule ServiceRadar.Edge.NatsLeafCredentialsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.NatsLeafCredentials

  require Ash.Query

  @moduletag :database

  defmodule AccountClientStub do
    @moduledoc false
    def generate_user_credentials(account_name, account_seed, user_name, type, opts) do
      send(self(), {:minted, account_name, account_seed, user_name, type, opts[:permissions]})

      {:ok,
       %{
         user_public_key: "U" <> String.duplicate("A", 55),
         user_jwt: "jwt",
         creds_file_content:
           "-----BEGIN NATS USER JWT-----\njwt\n------END NATS USER JWT------\n",
         expires_at: nil
       }}
    end
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    prior =
      {Application.get_env(:serviceradar, :nats_account_name),
       Application.get_env(:serviceradar, :nats_account_seed)}

    on_exit(fn ->
      {name, seed} = prior
      restore(:nats_account_name, name)
      restore(:nats_account_seed, seed)
    end)

    site = %{id: Ash.UUID.generate(), slug: "nyc-#{System.unique_integer([:positive])}"}
    %{site: site}
  end

  test "returns no creds when no NATS account is configured", %{site: site} do
    Application.delete_env(:serviceradar, :nats_account_name)
    Application.delete_env(:serviceradar, :nats_account_seed)

    assert {:ok, nil} = NatsLeafCredentials.mint(site, account_client: AccountClientStub)
    refute_received {:minted, _, _, _, _, _}
  end

  test "mints leaf-scoped creds through the account client and records them", %{site: site} do
    Application.put_env(:serviceradar, :nats_account_name, "tenant-account")
    Application.put_env(:serviceradar, :nats_account_seed, "SAEXAMPLESEED")

    assert {:ok, creds} = NatsLeafCredentials.mint(site, account_client: AccountClientStub)
    assert creds =~ "BEGIN NATS USER JWT"
    refute creds =~ "PLACEHOLDER"

    user_name = "leaf-#{site.slug}"

    assert_received {:minted, "tenant-account", "SAEXAMPLESEED", ^user_name, :service,
                     permissions}

    refute "config.>" in permissions.subscribe_allow

    assert {:ok, [credential]} =
             NatsCredential
             |> Ash.Query.filter(user_name == ^user_name)
             |> Ash.read(actor: SystemActor.system(:test))

    assert credential.credential_type == :service
  end

  defp restore(key, nil), do: Application.delete_env(:serviceradar, key)
  defp restore(key, value), do: Application.put_env(:serviceradar, key, value)
end

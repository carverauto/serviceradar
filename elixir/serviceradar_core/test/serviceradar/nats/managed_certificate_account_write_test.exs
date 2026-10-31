defmodule ServiceRadar.NATS.ManagedCertificateAccountWriteTest do
  @moduledoc """
  A matching deployment account stores the singleton NATS certificate config
  once. A later different account leaves that material in place.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ManagedCertificateNatsConfig
  alias ServiceRadar.NATS.CertificateAuthorizationToken, as: Token
  alias ServiceRadar.NATS.ManagedCertificateAuthorization, as: Authorizer
  alias ServiceRadar.NATS.ManagedCertificateConfiguration, as: Configuration

  setup do
    previous = Application.get_env(:serviceradar, :nats_account_name)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:serviceradar, :nats_account_name)
      else
        Application.put_env(:serviceradar, :nats_account_name, previous)
      end
    end)

    :ok
  end

  test "stores the deployment account once and keeps it when a later account disagrees" do
    actor = %{permissions: MapSet.new(["settings.edge.manage"])}
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")

    assert {:ok, stored} = Configuration.bootstrap("EDGE", actor)
    assert public_fields?(stored)
    assert stored.auth_mode == "static_mtls"
    assert stored.account_name == "EDGE"
    assert public_nkey?(stored.issuer_nkey, "A")
    assert public_nkey?(stored.auth_nkey, "U")
    assert public_nkey?(stored.system_nkey, "U")
    assert distinct_nkeys?(stored)

    assert {:ok, reused} = Configuration.bootstrap("EDGE", actor)
    assert same_material?(reused, stored)

    Application.put_env(:serviceradar, :nats_account_name, "OTHER")
    assert {:error, :nats_account_mismatch} = Configuration.bootstrap("EDGE", actor)

    assert {:error, :existing_nats_authentication_mode_conflicts} =
             Configuration.bootstrap("OTHER", actor)

    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    assert {:ok, kept} = Configuration.bootstrap("EDGE", actor)
    assert same_material?(kept, stored)
  end

  test "reports a JWT deployment unready when no account signer is configured" do
    issuer = Token.new_key(:account)
    auth = Token.new_key(:user)
    system = Token.new_key(:user)

    assert {:ok, _config} =
             ManagedCertificateNatsConfig
             |> Ash.Changeset.for_create(
               :configure,
               %{
                 auth_mode: "operator_jwt",
                 account_name: "EDGE",
                 issuer_nkey: issuer.public_key,
                 issuer_seed: issuer.seed,
                 auth_nkey: auth.public_key,
                 auth_seed: auth.seed,
                 system_nkey: system.public_key,
                 system_seed: system.seed
               },
               actor: SystemActor.system(:managed_certificate_nats)
             )
             |> Ash.create()

    assert {:noreply, state} = Authorizer.handle_info(:tick, blank_authorizer())
    assert state.reason == "jwt_account_signer_unconfigured"
    assert state.signer == nil
    assert state.subscription == nil
    assert state.config.auth_mode == "operator_jwt"
    assert state.config.account_name == "EDGE"
    refute Map.has_key?(state.config, :issuer_seed)
    refute Map.has_key?(state.config, :auth_seed)
    refute Map.has_key?(state.config, :system_seed)

    assert {:reply, status, ^state} = Authorizer.handle_call(:readiness, self(), state)

    assert status == %{
             auth_mode: "operator_jwt",
             account_name: "EDGE",
             ready: false,
             reason: "jwt_account_signer_unconfigured"
           }
  end

  defp blank_authorizer do
    %{
      config: nil,
      signer: nil,
      snapshot: nil,
      subscription: nil,
      sessions: %{},
      probe: nil,
      reason: "not_configured"
    }
  end

  defp public_fields?(config) do
    config |> Map.keys() |> Enum.sort() == [
      :account_name,
      :auth_mode,
      :auth_nkey,
      :issuer_nkey,
      :system_nkey
    ]
  end

  defp public_nkey?(value, prefix) when is_binary(value) do
    String.starts_with?(value, prefix) and byte_size(value) > 20 and
      String.match?(value, ~r/\A[A-Z2-7]+\z/)
  end

  defp public_nkey?(_, _), do: false

  defp distinct_nkeys?(config) do
    [config.issuer_nkey, config.auth_nkey, config.system_nkey]
    |> Enum.uniq()
    |> length() == 3
  end

  defp same_material?(left, right) do
    left.auth_mode == right.auth_mode and left.account_name == right.account_name and
      left.issuer_nkey == right.issuer_nkey and left.auth_nkey == right.auth_nkey and
      left.system_nkey == right.system_nkey
  end
end

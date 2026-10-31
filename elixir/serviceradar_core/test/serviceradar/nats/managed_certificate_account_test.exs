defmodule ServiceRadar.NATS.ManagedCertificateAccountTest do
  @moduledoc """
  Bootstrap accepts only the deployment NATS account, and readiness stays
  unready when the stored account disagrees with that account.
  """
  use ExUnit.Case, async: false

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

  test "refuses bootstrap when the deployment account is missing or unusable" do
    actor = actor()

    Application.delete_env(:serviceradar, :nats_account_name)
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)

    Application.put_env(:serviceradar, :nats_account_name, "")
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)

    Application.put_env(:serviceradar, :nats_account_name, "not an account")
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)

    Application.put_env(:serviceradar, :nats_account_name, :EDGE)
    assert {:error, :nats_account_unconfigured} = Configuration.bootstrap("EDGE", actor)
  end

  test "refuses a requested account other than the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")

    assert {:error, :nats_account_mismatch} = Configuration.bootstrap("OTHER", actor())
  end

  test "rejects an illegal account name before the deployment check" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")
    assert {:error, :invalid_account_name} = Configuration.bootstrap("not an account", actor())

    Application.delete_env(:serviceradar, :nats_account_name)
    assert {:error, :invalid_account_name} = Configuration.bootstrap("not an account", actor())
  end

  test "denies bootstrap before account checks when permission is missing" do
    Application.delete_env(:serviceradar, :nats_account_name)

    assert {:error, :forbidden} = Configuration.bootstrap("EDGE", actor([]))
  end

  test "reports ready when the stored account is the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "EDGE")

    assert readiness(ready_state("EDGE")) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: true,
             reason: nil
           }
  end

  test "stays unready when the stored account disagrees with the deployment account" do
    Application.put_env(:serviceradar, :nats_account_name, "OTHER")

    assert readiness(ready_state("EDGE")) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: false,
             reason: "nats_account_mismatch"
           }

    Application.delete_env(:serviceradar, :nats_account_name)

    assert readiness(ready_state("EDGE")) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: false,
             reason: "nats_account_mismatch"
           }
  end

  test "keeps an earlier unreadiness reason" do
    Application.put_env(:serviceradar, :nats_account_name, "OTHER")

    assert readiness(%{config: nil, reason: "not_configured"}) == %{
             auth_mode: nil,
             account_name: nil,
             ready: false,
             reason: "not_configured"
           }

    assert readiness(%{ready_state("EDGE") | reason: "connecting"}) == %{
             auth_mode: "static_mtls",
             account_name: "EDGE",
             ready: false,
             reason: "connecting"
           }
  end

  test "reports no account when the authorizer process is down" do
    assert Authorizer.readiness() == %{
             auth_mode: nil,
             account_name: nil,
             ready: false,
             reason: "authorizer_unavailable"
           }
  end

  defp actor(permissions \\ ["settings.edge.manage"]) do
    %{permissions: MapSet.new(permissions)}
  end

  defp ready_state(account) do
    %{config: %{auth_mode: "static_mtls", account_name: account}, reason: nil}
  end

  defp readiness(state) do
    assert {:reply, status, ^state} =
             Authorizer.handle_call(:readiness, {self(), make_ref()}, state)

    status
  end
end

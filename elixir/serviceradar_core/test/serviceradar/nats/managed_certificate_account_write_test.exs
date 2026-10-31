defmodule ServiceRadar.NATS.ManagedCertificateAccountWriteTest do
  @moduledoc """
  A matching deployment account stores the singleton NATS certificate config
  once. A later different account leaves that material in place.
  """

  use ServiceRadar.DataCase, async: false

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

defmodule ServiceRadarWebNGWeb.Api.IdentityControllerTest do
  @moduledoc """
  Resolving an address to a device uid, without probing it.

  The point of these is as much what does not happen as what does: before this route,
  the only way to obtain a uid was to start a validation run, which scans real hardware.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.ValidationRun
  alias ServiceRadar.Inventory.DeviceIdentifier

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
    ip = unique_ip()
    device = device_fixture(%{uid: "sr:" <> Ecto.UUID.generate(), ip: ip})

    %{conn: log_in_api_user(conn, user), user: user, device: device, ip: ip}
  end

  # There is deliberately no test for the `ambiguous` outcome. Two active devices cannot
  # share an address: `ocsf_devices_unique_active_ip_idx` is a unique index on `ip` where
  # `deleted_at IS NULL`, and `DeviceIdentifier` is unique on
  # (identifier_type, identifier_value, partition). Both resolver branches that can return
  # `{:ambiguous, _}` are therefore unreachable through any state this suite can create.
  # The controller still handles it, because the resolver declares it in its error type
  # and a schema constraint is not a contract.

  defp unique_ip do
    n = System.unique_integer([:positive])
    "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 253) + 1}"
  end

  defp register_mac(uid, value) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: uid,
        identifier_type: :mac,
        identifier_value: value,
        partition: "default",
        source: "test"
      },
      actor: SystemActor.system(:identity_resolve_api_test)
    )
    |> Ash.create!()
  end

  describe "GET /api/v1/identity/resolve" do
    test "resolves a known address", %{conn: conn, device: device, ip: ip} do
      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => ip, "partition" => "default"})
        |> json_response(200)

      assert response["data"]["uid"] == device.uid
      assert response["data"]["ip"] == ip
      assert response["data"]["partition"] == "default"
    end

    test "defaults the partition", %{conn: conn, device: device, ip: ip} do
      response = conn |> get(~p"/api/v1/identity/resolve", %{"ip" => ip}) |> json_response(200)

      assert response["data"]["uid"] == device.uid
      assert response["data"]["partition"] == "default"
    end

    test "treats a blank partition as absent", %{conn: conn, device: device, ip: ip} do
      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => ip, "partition" => ""})
        |> json_response(200)

      assert response["data"]["uid"] == device.uid
      assert response["data"]["partition"] == "default"
    end

    test "starts no validation run", %{conn: conn, ip: ip} do
      before = count_validation_runs()

      conn |> get(~p"/api/v1/identity/resolve", %{"ip" => ip}) |> json_response(200)

      assert count_validation_runs() == before
    end

    test "accepts a corroborating mac", %{conn: conn, device: device, ip: ip} do
      register_mac(device.uid, "AABBCCDDEE01")

      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => ip, "mac" => "aa:bb:cc:dd:ee:01"})
        |> json_response(200)

      assert response["data"]["uid"] == device.uid
    end

    test "ignores a mac no device holds", %{conn: conn, device: device, ip: ip} do
      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => ip, "mac" => "aa:bb:cc:00:00:99"})
        |> json_response(200)

      assert response["data"]["uid"] == device.uid
    end

    test "reports a mac belonging to another device as a conflict", %{conn: conn, ip: ip} do
      other = device_fixture(%{uid: "sr:" <> Ecto.UUID.generate(), ip: unique_ip()})
      register_mac(other.uid, "AABBCCDDEE02")

      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => ip, "mac" => "aa:bb:cc:dd:ee:02"})
        |> json_response(409)

      assert response["error"] == "mac_ip_conflict"
      # Both devices are named: a caller can say which ones disagree, not only that
      # something did.
      assert is_binary(response["ip_uid"])
      assert response["mac_uid"] == other.uid
      refute Map.has_key?(response, "uid")
    end

    test "reports an unknown address as not found", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => "203.0.113.251"})
        |> json_response(404)

      assert response["error"] == "not_found"
    end

    test "rejects an address that is not an address", %{conn: conn} do
      response =
        conn
        |> get(~p"/api/v1/identity/resolve", %{"ip" => "not-an-ip"})
        |> json_response(400)

      assert response["error"] == "invalid_ip"
    end

    test "rejects a request with no address", %{conn: conn} do
      response = conn |> get(~p"/api/v1/identity/resolve") |> json_response(400)

      assert response["error"] == "missing_ip"
    end
  end

  describe "POST /api/v1/identity/resolve" do
    test "resolves a batch", %{conn: conn, device: device, ip: ip} do
      second_ip = unique_ip()
      second = device_fixture(%{uid: "sr:" <> Ecto.UUID.generate(), ip: second_ip})

      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{
          "partition" => "default",
          "devices" => [%{"ip" => ip}, %{"ip" => second_ip}]
        })
        |> json_response(200)

      assert [first, last] = response["data"]
      assert first["ip"] == ip
      assert first["uid"] == device.uid
      assert last["ip"] == second_ip
      assert last["uid"] == second.uid
    end

    test "one unresolvable address does not fail the batch", %{conn: conn, device: device, ip: ip} do
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{
          "devices" => [%{"ip" => ip}, %{"ip" => "203.0.113.252"}]
        })
        |> json_response(200)

      assert [resolved, missing] = response["data"]
      assert resolved["uid"] == device.uid
      assert missing["ip"] == "203.0.113.252"
      assert missing["error"] == "not_found"
      refute Map.has_key?(missing, "uid")
    end

    test "every outcome names the address it is for", %{conn: conn, ip: ip} do
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{
          "devices" => [%{"ip" => ip}, %{"ip" => "203.0.113.253"}]
        })
        |> json_response(200)

      assert Enum.all?(response["data"], &is_binary(&1["ip"]))
      assert Enum.all?(response["data"], &is_binary(&1["partition"]))
    end

    test "a per-device partition overrides the default", %{conn: conn, ip: ip} do
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{
          "partition" => "default",
          "devices" => [%{"ip" => ip, "partition" => "other"}]
        })
        |> json_response(200)

      assert [%{"partition" => "other"}] = response["data"]
    end

    test "refuses an over-long batch and states the limit", %{conn: conn} do
      devices = Enum.map(1..129, fn _ -> %{"ip" => "10.0.0.1"} end)

      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{"devices" => devices})
        |> json_response(400)

      assert response["error"] == "too_many_devices"
      assert response["message"] =~ "128"
    end

    test "a blank per-device partition falls back to the request's, not to default",
         %{conn: conn, ip: ip} do
      # Only nil and false are falsy in Elixir, so a blank string is a value: coalescing
      # on truthiness kept it and then fell through to "default", quietly ignoring the
      # partition the request asked for.
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{
          "partition" => "other",
          "devices" => [%{"ip" => ip, "partition" => ""}]
        })
        |> json_response(200)

      assert [%{"partition" => "other"}] = response["data"]
    end

    test "a blank request partition falls back to default", %{conn: conn, ip: ip} do
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{
          "partition" => "",
          "devices" => [%{"ip" => ip}]
        })
        |> json_response(200)

      assert [%{"partition" => "default"}] = response["data"]
    end

    test "refuses a batch holding an entry with no address", %{conn: conn, ip: ip} do
      # Dropping it would return one result for a two-entry request, which breaks the
      # promise that every entry can be matched to its input.
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{"devices" => [%{"ip" => ip}, %{}]})
        |> json_response(400)

      assert response["error"] == "missing_ip"
    end

    test "refuses a batch whose only entry has a blank address", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/v1/identity/resolve", %{"devices" => [%{"ip" => "   "}]})
        |> json_response(400)

      assert response["error"] == "missing_ip"
    end

    test "refuses an empty batch", %{conn: conn} do
      response =
        conn |> post(~p"/api/v1/identity/resolve", %{"devices" => []}) |> json_response(400)

      assert response["error"] == "empty_devices"
    end
  end

  describe "authorization" do
    test "a viewer may resolve without being able to start a validation run", %{ip: ip} do
      # The separation this permission exists for: resolving is a read of something the
      # inventory already shows, and must not require the right to scan a fleet.
      viewer = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :viewer})

      response =
        build_conn()
        |> log_in_api_user(viewer)
        |> get(~p"/api/v1/identity/resolve", %{"ip" => ip})
        |> json_response(200)

      assert is_binary(response["data"]["uid"])
    end

    test "an unauthenticated caller is refused", %{ip: ip} do
      conn = get(build_conn(), ~p"/api/v1/identity/resolve", %{"ip" => ip})

      assert conn.status in [401, 403]
    end
  end

  defp count_validation_runs do
    case Ash.read(ValidationRun, actor: SystemActor.system(:identity_resolve_api_test)) do
      {:ok, runs} -> length(runs)
      {:error, _} -> 0
    end
  end
end

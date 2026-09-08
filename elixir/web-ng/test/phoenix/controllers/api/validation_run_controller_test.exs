defmodule ServiceRadarWebNGWeb.Api.ValidationRunControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.Inventory.DeviceIdentifier

  setup %{conn: conn} do
    user = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :operator})
    n = System.unique_integer([:positive])
    ip = "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 253) + 1}"

    device =
      device_fixture(%{
        uid: "sr:" <> Ecto.UUID.generate(),
        ip: ip
      })

    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "API Isolation #{n}",
          scope_query: "in:devices"
        },
        actor: SystemActor.system(:validation_run_api_test)
      )
      |> Ash.create()

    {:ok, check} =
      check
      |> Ash.Changeset.for_update(:enable, %{acknowledge_coverage_gap: true},
        actor: SystemActor.system(:validation_run_api_test)
      )
      |> Ash.update()

    %{
      conn: log_in_api_user(conn, user),
      user: user,
      device: device,
      ip: ip,
      check: check
    }
  end

  test "POST shorthand returns uid and run id", %{conn: conn, device: device, ip: ip, check: check} do
    response =
      conn
      |> post(~p"/api/v1/validation-runs", %{
        "check" => check.slug,
        "partition" => "default",
        "ip" => ip
      })
      |> json_response(202)

    assert is_binary(response["id"])
    assert response["status"] == "pending"
    assert response["check"] == check.slug
    assert [%{"ip" => ^ip, "uid" => uid, "partition" => "default"}] = response["devices"]
    assert uid == device.uid
  end

  test "POST rejects an unknown IP", %{conn: conn, check: check} do
    response =
      conn
      |> post(~p"/api/v1/validation-runs", %{
        "check" => check.slug,
        "ip" => "203.0.113.9"
      })
      |> json_response(404)

    assert response["error"] == "device_not_found"
  end

  test "POST rejects an unknown check", %{conn: conn, ip: ip} do
    response =
      conn
      |> post(~p"/api/v1/validation-runs", %{
        "check" => "missing-check",
        "ip" => ip
      })
      |> json_response(404)

    assert response["error"] == "check_not_found"
  end

  test "GET returns the run", %{conn: conn, ip: ip, check: check} do
    created =
      conn
      |> post(~p"/api/v1/validation-runs", %{"check" => check.slug, "ip" => ip})
      |> json_response(202)

    response =
      conn
      |> get(~p"/api/v1/validation-runs/#{created["id"]}")
      |> json_response(200)

    assert response["data"]["id"] == created["id"]
    assert is_list(response["data"]["devices"])
  end

  test "requires authentication", %{device: _device, ip: ip, check: check} do
    build_conn()
    |> post(~p"/api/v1/validation-runs", %{"check" => check.slug, "ip" => ip})
    |> json_response(401)
  end

  test "POST devices list returns both uids", %{conn: conn, device: device, ip: ip, check: check} do
    n = System.unique_integer([:positive])
    ip2 = "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 253) + 1}"
    device2 = device_fixture(%{uid: "sr:" <> Ecto.UUID.generate(), ip: ip2})

    response =
      conn
      |> post(~p"/api/v1/validation-runs", %{
        "check" => check.slug,
        "devices" => [%{"ip" => ip}, %{"ip" => ip2}]
      })
      |> json_response(202)

    uids = response["devices"] |> Enum.map(& &1["uid"]) |> Enum.sort()
    assert uids == Enum.sort([device.uid, device2.uid])
  end

  test "POST rejects a conflicting MAC", %{conn: conn, ip: ip, check: check} do
    other =
      device_fixture(%{
        uid: "sr:" <> Ecto.UUID.generate(),
        ip: "203.0.113.#{rem(System.unique_integer([:positive]), 200) + 20}",
        mac: "AA:BB:CC:DD:EE:FF"
      })

    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: other.uid,
        identifier_type: :mac,
        identifier_value: "AABBCCDDEEFF",
        partition: "default",
        source: "test"
      },
      actor: SystemActor.system(:validation_run_api_test)
    )
    |> Ash.create!()

    response =
      conn
      |> post(~p"/api/v1/validation-runs", %{
        "check" => check.slug,
        "ip" => ip,
        "mac" => "aa:bb:cc:dd:ee:ff"
      })
      |> json_response(409)

    assert response["error"] == "mac_ip_conflict"
  end

  test "POST rejects a draft check", %{conn: conn, ip: ip} do
    {:ok, draft} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Draft Isolation #{System.unique_integer([:positive])}",
          scope_query: "in:devices"
        },
        actor: SystemActor.system(:validation_run_api_test)
      )
      |> Ash.create()

    response =
      conn
      |> post(~p"/api/v1/validation-runs", %{"check" => draft.slug, "ip" => ip})
      |> json_response(400)

    assert response["error"] == "check_not_enabled"
  end

  test "POST is forbidden for a viewer", %{ip: ip, check: check} do
    viewer = ServiceRadarWebNG.AccountsFixtures.user_fixture(%{role: :viewer})

    response =
      build_conn()
      |> log_in_api_user(viewer)
      |> post(~p"/api/v1/validation-runs", %{"check" => check.slug, "ip" => ip})
      |> json_response(403)

    assert response["error"] == "forbidden"
  end

  test "GET results returns per-device rows", %{conn: conn, ip: ip, check: check} do
    created =
      conn
      |> post(~p"/api/v1/validation-runs", %{"check" => check.slug, "ip" => ip})
      |> json_response(202)

    response =
      conn
      |> get(~p"/api/v1/validation-runs/#{created["id"]}/results")
      |> json_response(200)

    assert [%{"ip" => ^ip, "uid" => _uid}] = response["data"]
  end
end

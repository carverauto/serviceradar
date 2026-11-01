defmodule ServiceRadarWebNGWeb.Api.ManagedComponentAdoptionDbTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadar.Edge.ComponentCertificate
  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadar.Edge.RevokedComponentCertificate
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Admin.ManagedComponentsLive.Index, as: Inventory
  alias ServiceRadarWebNGWeb.Api.ManagedComponentController, as: Controller

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @validity {{2026, 1, 1}, {2027, 6, 1}}

  test "returns the projected grant and leaves the certificate pem out of the response", %{conn: conn} do
    %{pem: pem, der: der} = self_signed()
    id = "example-gateway-#{System.unique_integer([:positive])}"

    conn =
      conn
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(id, pem))

    refute conn.resp_body =~ "BEGIN CERTIFICATE"
    body = json_response(conn, 201)
    data = body["data"]

    assert data["component_id"] == id
    assert data["service"] == "agent-gateway"
    assert data["host_agent_id"] == nil
    assert data["partition_id"] == "example-partition"
    assert data["generation"] == 1
    assert data["blocked"] == false
    assert data["server_hosts"] == ["gateway.example.com"]
    assert data["nats_permissions"]["publish"] == ["metrics.example.>"]
    assert data["nats_permissions"]["publish_deny"] == []
    assert data["nats_permissions"]["subscribe"] == [">"]
    assert data["nats_permissions"]["subscribe_deny"] == ["$SYS.>", "flow.example.>"]
    assert data["certificate"]["fingerprint"] == fingerprint(der)
    assert data["certificate"]["issuer_fingerprint"] == data["certificate"]["fingerprint"]
    assert data["certificate"]["role"] == "client"
    assert String.starts_with?(data["certificate"]["not_before"], "2026-01-01T13:00:00")
    assert String.starts_with?(data["certificate"]["not_after"], "2027-06-01T13:00:00")
    refute Map.has_key?(data, "certificate_pem")

    assert {:ok, stored} = Ash.get(ManagedComponent, id, scope: operator_scope())
    assert stored.generation_started_by == "example-operator"
    assert stored.nats_permissions["subscribe"] == [">"]
  end

  test "records a successor without changing the grant or retiring the predecessor", %{conn: conn} do
    first = self_signed()
    successor = self_signed(~c"example-gateway-next")
    id = "example-gateway-#{System.unique_integer([:positive])}"

    adopted =
      conn
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(id, first.pem))

    assert json_response(adopted, 201)

    refused =
      adopted
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.record_successor(%{
        "id" => id,
        "certificate_pem" => private_key_pem(first.pem)
      })

    assert json_response(refused, 409) == %{"error" => "private_key"}
    assert {:ok, [stored_first]} = certificates(id)
    assert stored_first.fingerprint == fingerprint(first.der)

    recorded =
      refused
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.record_successor(%{
        "id" => id,
        "component_id" => "other-example-gateway",
        "certificate_pem" => successor.pem,
        "permissions" => %{
          "publish" => %{"allow" => ["events.example.>"]},
          "subscribe" => %{"allow" => ["telemetry.example.>"], "deny" => []}
        }
      })

    refute recorded.resp_body =~ "BEGIN CERTIFICATE"
    body = json_response(recorded, 201)
    data = body["data"]

    assert data["component_id"] == id
    assert data["generation"] == 1
    assert data["nats_permissions"]["publish"] == ["metrics.example.>"]
    assert data["nats_permissions"]["publish_deny"] == []
    assert data["nats_permissions"]["subscribe"] == [">"]
    assert data["nats_permissions"]["subscribe_deny"] == ["$SYS.>", "flow.example.>"]
    assert data["certificate"]["fingerprint"] == fingerprint(successor.der)
    refute data["certificate"]["fingerprint"] == fingerprint(first.der)
    refute Map.has_key?(data, "certificate_pem")

    assert {:ok, stored} = Ash.get(ManagedComponent, id, scope: operator_scope())
    assert stored.generation == 1
    assert stored.nats_permissions["publish"] == ["metrics.example.>"]
    assert stored.nats_permissions["subscribe"] == [">"]
    assert stored.nats_permissions["subscribe_deny"] == ["$SYS.>", "flow.example.>"]

    assert {:ok, rows} = certificates(id)

    assert MapSet.new(rows, & &1.fingerprint) ==
             MapSet.new([fingerprint(first.der), fingerprint(successor.der)])

    assert Enum.all?(rows, &(&1.generation == 1))
    assert {:ok, []} = revocations(id)
    assert {:ok, []} = certificates("other-example-gateway")

    missing =
      recorded
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.record_successor(%{
        "id" => "missing-#{id}",
        "certificate_pem" => self_signed(~c"example-gateway-missing").pem
      })

    assert json_response(missing, 409) == %{"error" => "unknown_component"}
  end

  test "revokes one fingerprint and leaves the successor authorized", %{conn: conn} do
    first = self_signed()
    successor = self_signed(~c"example-gateway-next")
    other = self_signed(~c"example-gateway-other")
    id = "example-gateway-#{System.unique_integer([:positive])}"
    other_id = "example-gateway-#{System.unique_integer([:positive])}"

    adopted =
      conn
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(id, first.pem))

    assert json_response(adopted, 201)

    recorded =
      adopted
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.record_successor(%{"id" => id, "certificate_pem" => successor.pem})

    assert json_response(recorded, 201)

    other_adopted =
      recorded
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(other_id, other.pem))

    assert json_response(other_adopted, 201)

    revoked =
      other_adopted
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.revoke_certificate(%{
        "id" => id,
        "fingerprint" => fingerprint(first.der)
      })

    body = json_response(revoked, 200)
    data = body["data"]
    assert data["component_id"] == id
    assert data["generation"] == 1
    assert data["blocked"] == false
    refute revoked.resp_body =~ "BEGIN CERTIFICATE"

    repeated =
      revoked
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.revoke_certificate(%{
        "id" => id,
        "fingerprint" => fingerprint(first.der)
      })

    assert json_response(repeated, 200)

    assert {:ok, stored} = Ash.get(ManagedComponent, id, scope: operator_scope())
    assert stored.generation == 1
    assert stored.blocked == false
    assert stored.nats_permissions["publish"] == ["metrics.example.>"]
    assert stored.nats_permissions["subscribe"] == [">"]
    assert stored.nats_permissions["subscribe_deny"] == ["$SYS.>", "flow.example.>"]

    assert {:ok, [decision]} = revocations(id)
    assert decision.fingerprint == fingerprint(first.der)
    assert decision.generation == 1
    assert decision.reason == "operator-request"
    assert {:ok, rows} = certificates(id)

    assert MapSet.new(rows, & &1.fingerprint) ==
             MapSet.new([fingerprint(first.der), fingerprint(successor.der)])

    mismatched =
      repeated
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.revoke_certificate(%{
        "id" => id,
        "fingerprint" => fingerprint(other.der)
      })

    assert json_response(mismatched, 409) == %{"error" => "unknown_certificate"}
    assert {:ok, []} = revocations(other_id)

    missing =
      mismatched
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.revoke_certificate(%{
        "id" => id,
        "fingerprint" => "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      })

    assert json_response(missing, 409) == %{"error" => "unknown_certificate"}
    assert {:ok, [still_one]} = revocations(id)
    assert still_one.fingerprint == fingerprint(first.der)
  end

  test "inventory history revokes one fingerprint and leaves the component enrolled", %{conn: conn} do
    first = self_signed()
    successor = self_signed(~c"example-gateway-next")
    other = self_signed(~c"example-gateway-other")
    id = "example-gateway-#{System.unique_integer([:positive])}"
    other_id = "example-gateway-other-#{System.unique_integer([:positive])}"
    predecessor = fingerprint(first.der)

    adopted =
      conn
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(id, first.pem))

    assert json_response(adopted, 201)

    recorded =
      adopted
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.record_successor(%{"id" => id, "certificate_pem" => successor.pem})

    assert json_response(recorded, 201)

    other_adopted =
      recorded
      |> recycle()
      |> assign(:current_scope, operator_scope())
      |> Controller.adopt(params(other_id, other.pem))

    assert json_response(other_adopted, 201)

    assert {:noreply, denied} =
             Inventory.handle_event(
               "revoke-certificate",
               %{"id" => id, "fingerprint" => predecessor},
               inventory_socket(denied_scope(), id)
             )

    assert denied.assigns.flash["error"] ==
             "You do not have permission to manage service certificates."

    assert {:ok, []} = revocations(id)

    assert {:noreply, revoked} =
             Inventory.handle_event(
               "revoke-certificate",
               %{"id" => id, "fingerprint" => predecessor},
               inventory_socket(operator_scope(), id)
             )

    assert revoked.assigns.flash["info"] =~ "The component stays enrolled."
    assert revoked.assigns.selected == id
    assert MapSet.member?(revoked.assigns.revoked_fingerprints, predecessor)
    refute MapSet.member?(revoked.assigns.revoked_fingerprints, fingerprint(successor.der))

    assert Enum.any?(revoked.assigns.certificates, &(&1.fingerprint == predecessor))
    assert Enum.any?(revoked.assigns.certificates, &(&1.fingerprint == fingerprint(successor.der)))

    component = Enum.find(revoked.assigns.components, &(&1.component_id == id))
    assert component.blocked == false
    assert component.generation == 1
    assert component.nats_permissions["publish"] == ["metrics.example.>"]
    assert component.nats_permissions["subscribe"] == [">"]
    assert component.nats_permissions["subscribe_deny"] == ["$SYS.>", "flow.example.>"]

    assert {:ok, stored} = Ash.get(ManagedComponent, id, scope: operator_scope())
    assert stored.generation == 1
    assert stored.blocked == false
    assert stored.nats_permissions["subscribe"] == [">"]

    assert {:ok, [decision]} = revocations(id)
    assert decision.fingerprint == predecessor
    assert decision.generation == 1
    assert decision.reason == "operator-request"

    assert {:noreply, mismatched} =
             Inventory.handle_event(
               "revoke-certificate",
               %{"id" => id, "fingerprint" => fingerprint(other.der)},
               inventory_socket(operator_scope(), id)
             )

    assert mismatched.assigns.flash["error"] ==
             "The certificate could not be revoked. Refresh the history and try again."

    assert {:ok, []} = revocations(other_id)
    assert {:ok, [still_one]} = revocations(id)
    assert still_one.fingerprint == predecessor
  end

  defp inventory_socket(scope, selected) do
    socket = %Phoenix.LiveView.Socket{}
    socket = %{socket | assigns: Map.put(socket.assigns, :flash, %{})}

    Phoenix.Component.assign(socket,
      current_scope: scope,
      components: [],
      operations: %{},
      certificates: [],
      revoked_fingerprints: MapSet.new(),
      revoked_generations: MapSet.new(),
      selected: selected,
      cursor: nil,
      more?: false,
      loading?: false
    )
  end

  defp denied_scope do
    %Scope{
      user: %{id: "example-operator", role: :operator},
      permissions: MapSet.new()
    }
  end

  defp operator_scope do
    %Scope{
      user: %{id: "example-operator", role: :operator},
      permissions: MapSet.new(["settings.edge.manage"])
    }
  end

  defp params(id, pem) do
    %{
      "component_id" => id,
      "component_type" => "agent-gateway",
      "partition_id" => "example-partition",
      "server_hosts" => ["gateway.example.com"],
      "certificate_pem" => pem,
      "permissions" => %{
        "publish" => %{"allow" => ["metrics.example.>"], "deny" => []},
        "subscribe" => %{"allow" => [], "deny" => ["$SYS.>", "flow.example.>"]}
      }
    }
  end

  defp self_signed(name \\ ~c"example-gateway") do
    %{cert: der} = :public_key.pkix_test_root_cert(name, validity: @validity)

    %{
      der: der,
      pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    }
  end

  defp private_key_pem(certificate_pem) do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
    certificate_pem <> key_pem
  end

  defp certificates(component_id) do
    ComponentCertificate
    |> Ash.Query.filter(component_id == ^component_id)
    |> Ash.read(scope: operator_scope())
  end

  defp revocations(component_id) do
    RevokedComponentCertificate
    |> Ash.Query.filter(component_id == ^component_id)
    |> Ash.read(scope: operator_scope())
  end

  defp fingerprint(der), do: :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)
end

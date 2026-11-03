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

  test "polling drops a selected component that leaves the page without a history error" do
    token = page_token()
    ids = Enum.map(1..25, &page_id(token, &1))
    Enum.each(ids, &enroll_gateway/1)
    displaced = List.last(ids)

    {:noreply, loaded} =
      Inventory.handle_info(
        :refresh,
        inventory_socket(operator_scope(), nil, %{cursor: token <> "-"})
      )

    assert Enum.map(loaded.assigns.components, & &1.component_id) == ids

    opened =
      put_assigns(loaded,
        selected: displaced,
        certificates: [%{fingerprint: "sentinel"}],
        revoked_fingerprints: MapSet.new(["sentinel"]),
        revoked_generations: MapSet.new([9])
      )

    {:noreply, stayed} = Inventory.handle_info(:poll, opened)
    assert stayed.assigns.selected == displaced
    assert stayed.assigns.certificates == []
    assert stayed.assigns.revoked_fingerprints == MapSet.new()
    assert stayed.assigns.revoked_generations == MapSet.new()
    refute stayed.assigns.flash["error"]

    enroll_gateway(page_id(token, 0))

    {:noreply, dropped} = Inventory.handle_info(:poll, stayed)
    assert dropped.assigns.selected == nil
    assert dropped.assigns.certificates == []
    assert dropped.assigns.revoked_fingerprints == MapSet.new()
    assert dropped.assigns.revoked_generations == MapSet.new()
    refute dropped.assigns.flash["error"]
    assert Enum.map(dropped.assigns.components, & &1.component_id) == Enum.map(0..24, &page_id(token, &1))

    {:noreply, again} = Inventory.handle_info(:certificate_policy_changed, dropped)
    assert again.assigns.selected == nil
    refute again.assigns.flash["error"]
  end

  test "history errors stay on a visible component and a missing row clears quietly" do
    id = "visible-history-#{System.unique_integer([:positive])}"

    component = %ManagedComponent{
      component_id: id,
      component_type: "agent-gateway",
      generation: 1,
      blocked: false
    }

    kept = [%{fingerprint: "keep"}]

    {:noreply, failed} =
      Inventory.handle_event(
        "inspect",
        %{"id" => id},
        inventory_socket(denied_scope(), id, %{
          components: [component],
          certificates: kept,
          revoked_fingerprints: MapSet.new(["keep"]),
          revoked_generations: MapSet.new([4])
        })
      )

    assert failed.assigns.flash["error"] == "Could not load certificate history."
    assert failed.assigns.selected == id
    assert failed.assigns.certificates == kept
    assert failed.assigns.revoked_fingerprints == MapSet.new(["keep"])
    assert failed.assigns.revoked_generations == MapSet.new([4])

    {:noreply, cleared} =
      Inventory.handle_event(
        "inspect",
        %{"id" => "not-on-this-page"},
        inventory_socket(operator_scope(), id, %{
          components: [component],
          certificates: kept,
          revoked_fingerprints: MapSet.new(["keep"]),
          revoked_generations: MapSet.new([4])
        })
      )

    assert cleared.assigns.selected == nil
    assert cleared.assigns.certificates == []
    assert cleared.assigns.revoked_fingerprints == MapSet.new()
    assert cleared.assigns.revoked_generations == MapSet.new()
    refute cleared.assigns.flash["error"]
  end

  test "page controls commit the cursor and clear the open component only after the page read succeeds" do
    token = page_token()
    ids = Enum.map(1..26, &page_id(token, &1))
    Enum.each(ids, &enroll_gateway/1)
    cursor = token <> "-"
    page1 = Enum.take(ids, 25)
    page2_id = List.last(ids)
    page1_id = List.last(page1)

    {:noreply, loaded} =
      Inventory.handle_info(:refresh, inventory_socket(operator_scope(), nil, %{cursor: cursor}))

    assert Enum.map(loaded.assigns.components, & &1.component_id) == page1
    assert loaded.assigns.more?

    opened =
      put_assigns(loaded,
        selected: page1_id,
        certificates: [%{fingerprint: "open"}],
        revoked_fingerprints: MapSet.new(["open"]),
        revoked_generations: MapSet.new([2])
      )

    {:noreply, failed_next} =
      Inventory.handle_event("next", %{}, put_assigns(opened, %{current_scope: denied_scope()}))

    assert failed_next.assigns.cursor == cursor
    assert failed_next.assigns.previous_cursors == []
    assert Enum.map(failed_next.assigns.components, & &1.component_id) == page1
    assert failed_next.assigns.more?
    assert failed_next.assigns.selected == page1_id
    assert failed_next.assigns.certificates == [%{fingerprint: "open"}]
    assert failed_next.assigns.revoked_fingerprints == MapSet.new(["open"])
    assert failed_next.assigns.flash["error"] == "Could not refresh managed certificates."

    {:noreply, polled} =
      Inventory.handle_info(:poll, put_assigns(failed_next, %{current_scope: operator_scope()}))

    assert polled.assigns.cursor == cursor
    assert polled.assigns.previous_cursors == []
    assert Enum.map(polled.assigns.components, & &1.component_id) == page1
    assert polled.assigns.selected == page1_id
    refute polled.assigns.flash["error"] == "Could not load certificate history."

    {:noreply, advanced} = Inventory.handle_event("next", %{}, polled)
    assert advanced.assigns.cursor == page1_id
    assert advanced.assigns.previous_cursors == [cursor]
    assert hd(Enum.map(advanced.assigns.components, & &1.component_id)) == page2_id
    refute page1_id in Enum.map(advanced.assigns.components, & &1.component_id)
    assert advanced.assigns.selected == nil
    assert advanced.assigns.certificates == []
    assert advanced.assigns.revoked_fingerprints == MapSet.new()
    assert advanced.assigns.revoked_generations == MapSet.new()

    reopened = put_assigns(advanced, %{selected: page2_id, certificates: [%{fingerprint: "page-two"}]})

    {:noreply, failed_previous} =
      Inventory.handle_event("previous", %{}, put_assigns(reopened, %{current_scope: denied_scope()}))

    assert failed_previous.assigns.cursor == page1_id
    assert failed_previous.assigns.previous_cursors == [cursor]
    assert failed_previous.assigns.selected == page2_id
    assert failed_previous.assigns.certificates == [%{fingerprint: "page-two"}]
    assert hd(Enum.map(failed_previous.assigns.components, & &1.component_id)) == page2_id
    assert failed_previous.assigns.flash["error"] == "Could not refresh managed certificates."

    {:noreply, returned} =
      Inventory.handle_event(
        "previous",
        %{},
        put_assigns(failed_previous, %{current_scope: operator_scope()})
      )

    assert returned.assigns.cursor == cursor
    assert returned.assigns.previous_cursors == []
    assert Enum.map(returned.assigns.components, & &1.component_id) == page1
    assert returned.assigns.selected == nil

    {:noreply, page_two} = Inventory.handle_event("next", %{}, returned)
    selected_two = put_assigns(page_two, %{selected: page2_id, certificates: [%{fingerprint: "stay"}]})

    {:noreply, failed_first} =
      Inventory.handle_event("first", %{}, put_assigns(selected_two, %{current_scope: denied_scope()}))

    assert failed_first.assigns.cursor == page1_id
    assert failed_first.assigns.previous_cursors == [cursor]
    assert failed_first.assigns.selected == page2_id
    assert failed_first.assigns.certificates == [%{fingerprint: "stay"}]
    assert hd(Enum.map(failed_first.assigns.components, & &1.component_id)) == page2_id

    {:noreply, first} =
      Inventory.handle_event("first", %{}, put_assigns(failed_first, %{current_scope: operator_scope()}))

    assert first.assigns.cursor == nil
    assert first.assigns.previous_cursors == []
    assert first.assigns.selected == nil
    assert first.assigns.certificates == []
    assert length(first.assigns.components) == 25
    assert first.assigns.more?
    refute page2_id in Enum.map(first.assigns.components, & &1.component_id)
  end

  defp inventory_socket(scope, selected, overrides \\ %{}) do
    socket = %Phoenix.LiveView.Socket{}
    socket = %{socket | assigns: Map.put(socket.assigns, :flash, %{})}

    socket
    |> Phoenix.Component.assign(
      current_scope: scope,
      components: [],
      operations: %{},
      certificates: [],
      revoked_fingerprints: MapSet.new(),
      revoked_generations: MapSet.new(),
      selected: selected,
      cursor: nil,
      previous_cursors: [],
      more?: false,
      loading?: false
    )
    |> put_assigns(overrides)
  end

  defp put_assigns(socket, attrs), do: Phoenix.Component.assign(socket, attrs)

  defp page_token do
    suffix =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string()
      |> String.pad_leading(12, "0")

    "zz" <> suffix
  end

  defp page_id(token, index), do: token <> "-" <> String.pad_leading(Integer.to_string(index), 2, "0")

  defp enroll_gateway(id) do
    {:ok, _component} =
      ManagedComponent
      |> Ash.Changeset.for_create(
        :adopt_infrastructure,
        %{
          component_id: id,
          component_type: "agent-gateway",
          partition_id: "example-partition",
          server_hosts: ["gateway.example.com"],
          permissions: %{
            "publish" => ["metrics.example.>"],
            "publish_deny" => [],
            "subscribe" => [">"],
            "subscribe_deny" => ["$SYS.>"]
          }
        },
        scope: operator_scope()
      )
      |> Ash.create(scope: operator_scope())
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

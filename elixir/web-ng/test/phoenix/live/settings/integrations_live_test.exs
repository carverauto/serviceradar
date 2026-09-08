defmodule ServiceRadarWebNGWeb.Settings.IntegrationsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Integrations.IntegrationUpdateRunTarget
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  setup :register_and_log_in_admin_user

  test "create form persists armis credentials from rendered credential inputs", %{
    conn: conn,
    scope: scope
  } do
    agent = create_connected_agent!()
    source_name = "Armis Credential Source #{System.unique_integer([:positive])}"

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/new")

    lv
    |> form("#create_source_form", %{
      "form" => %{
        "name" => source_name,
        "source_type" => "armis",
        "endpoint" => "https://armis.example.test",
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "armis-api-key",
      "cred_api_secret" => "armis-secret",
      "cred_v3_client_id" => "armis-client@example.test",
      "cred_v3_client_secret" => "armis-client-secret",
      "cred_v3_vendor_id" => "armis-vendor"
    })
    |> render_submit()

    source = get_source_by_name!(source_name, scope)

    assert source.credentials == %{
             "api_key" => "armis-api-key",
             "api_secret" => "armis-secret",
             "client_id" => "armis-client@example.test",
             "client_secret" => "armis-client-secret",
             "vendor_id" => "armis-vendor"
           }
  end

  test "edit form updates armis credentials from rendered credential inputs", %{
    conn: conn,
    scope: scope
  } do
    agent = create_connected_agent!()

    source =
      create_armis_source!(scope, %{
        name: "Armis Credential Edit #{System.unique_integer([:positive])}",
        agent_id: agent.uid
      })

    {:ok, lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    # The stored key must never be rendered back into the form. It is masked and
    # carries NO value attribute at all -- the same shape as cred_api_secret --
    # so a re-render cannot clobber a half-typed value either. This assertion
    # previously read `[value='key']`, which encoded the exposure as intended
    # behaviour; the credentials map is a single AshCloak-encrypted, sensitive?
    # true blob with no per-key distinction, so the key is exactly as sensitive
    # as the secret beside it.
    assert has_element?(lv, "input[name='cred_api_key'][type='password']")
    refute has_element?(lv, "input[name='cred_api_key'][value='key']")
    refute has_element?(lv, "input[name='cred_api_key'][value]")
    assert html =~ "API key:"
    # Identifiers, not secrets: these stay prefilled on purpose.
    assert has_element?(lv, "input[name='cred_v3_client_id']")
    assert has_element?(lv, "input[name='cred_v3_vendor_id']")
    refute has_element?(lv, "input[name='form[gateway_id]']")
    refute has_element?(lv, "input[name='form[poll_interval_seconds]']")
    refute has_element?(lv, "input[name='form[sweep_interval_seconds]']")
    assert html =~ "API secret:"
    assert html =~ "saved"

    lv
    |> form("#edit_source_form", %{
      "form" => %{
        "name" => source.name,
        "endpoint" => source.endpoint,
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "updated-api-key",
      "cred_api_secret" => "updated-secret",
      "cred_v3_client_id" => "updated-client@example.test",
      "cred_v3_client_secret" => "updated-client-secret",
      "cred_v3_vendor_id" => "updated-vendor"
    })
    |> render_submit()

    updated_source = get_source_by_name!(source.name, scope)

    assert updated_source.credentials == %{
             "api_key" => "updated-api-key",
             "api_secret" => "updated-secret",
             "client_id" => "updated-client@example.test",
             "client_secret" => "updated-client-secret",
             "vendor_id" => "updated-vendor"
           }
  end

  test "edit form preserves existing armis secret when secret field is blank", %{
    conn: conn,
    scope: scope
  } do
    agent = create_connected_agent!()

    source =
      create_armis_source!(scope, %{
        name: "Armis Credential Preserve #{System.unique_integer([:positive])}",
        agent_id: agent.uid,
        credentials: %{
          api_key: "existing-api-key",
          api_secret: "existing-secret",
          client_id: "existing-client@example.test",
          client_secret: "existing-client-secret",
          vendor_id: "existing-vendor"
        }
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    lv
    |> form("#edit_source_form", %{
      "form" => %{
        "name" => source.name,
        "endpoint" => source.endpoint,
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "updated-api-key",
      "cred_api_secret" => "",
      "cred_v3_client_id" => "updated-client@example.test",
      "cred_v3_client_secret" => "",
      "cred_v3_vendor_id" => "updated-vendor"
    })
    |> render_submit()

    updated_source = get_source_by_name!(source.name, scope)

    assert updated_source.credentials == %{
             "api_key" => "updated-api-key",
             "api_secret" => "existing-secret",
             "client_id" => "updated-client@example.test",
             "client_secret" => "existing-client-secret",
             "vendor_id" => "updated-vendor"
           }
  end

  test "submitting a blank api key keeps the stored one", %{conn: conn, scope: scope} do
    # This is now the COMMON path, not an edge case: the key field is no longer
    # prefilled, so every save that does not deliberately rotate it submits "".
    # maybe_add_cred/3 is a no-op on "" and the merge starts from
    # existing_credentials, which is what makes removing the prefill safe --
    # api_secret has relied on exactly this since it was never prefilled.
    agent = create_connected_agent!()

    source =
      create_armis_source!(scope, %{
        name: "Armis Blank Key Preserve #{System.unique_integer([:positive])}",
        agent_id: agent.uid,
        credentials: %{api_key: "existing-api-key", api_secret: "existing-secret"}
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    lv
    |> form("#edit_source_form", %{
      "form" => %{
        "name" => source.name,
        "endpoint" => source.endpoint,
        "agent_id" => agent.uid,
        "discovery_interval_seconds" => "3600"
      },
      "cred_api_key" => "",
      "cred_api_secret" => ""
    })
    |> render_submit()

    updated_source = get_source_by_name!(source.name, scope)

    assert updated_source.credentials["api_key"] == "existing-api-key"
    assert updated_source.credentials["api_secret"] == "existing-secret"
  end

  test "edit modal exposes armis northbound settings", %{conn: conn, scope: scope} do
    source =
      create_armis_source!(scope, %{
        name: "Armis Edit Source",
        custom_fields: ["availability_status"],
        northbound_enabled: true,
        northbound_interval_seconds: 900
      })

    {:ok, lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}/edit")

    assert html =~ "Armis Northbound"
    assert has_element?(lv, "input[name='custom_fields_text'][value='availability_status']")
    assert has_element?(lv, "input[name='form[northbound_interval_seconds]'][value='900']")
    assert has_element?(lv, "input[name='form[northbound_enabled]'][type='checkbox'][checked]")
  end

  test "details modal shows separate armis northbound status and recent runs", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Detail Source",
        custom_fields: ["availability_status"],
        northbound_enabled: true,
        northbound_interval_seconds: 1800
      })

    source =
      source
      |> Ash.Changeset.for_update(:northbound_success, %{
        result: :success,
        device_count: 12,
        updated_count: 9,
        skipped_count: 3
      })
      |> Ash.update!(scope: scope)

    _success_run =
      create_run!(scope, source.id, %{
        status_action: :finish_success,
        device_count: 12,
        updated_count: 9,
        skipped_count: 3,
        error_count: 0
      })

    _failed_run =
      create_run!(scope, source.id, %{
        status_action: :finish_failed,
        device_count: 12,
        updated_count: 5,
        skipped_count: 4,
        error_count: 3,
        error_message: "bulk update rejected"
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Discovery Status"
    assert html =~ "Armis Northbound"
    assert html =~ "availability_status"
    assert html =~ "Recent Runs"
    assert html =~ "bulk update rejected"
    assert html =~ "Collection accounting unavailable"
    assert html =~ "Accepted"
    assert html =~ "9"
  end

  test "details modal shows an exact collection reconciliation funnel", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Reconciled Source",
        custom_fields: ["availability_status"],
        northbound_enabled: true
      })

    run =
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(:start_run, %{
        integration_source_id: source.id,
        run_type: :armis_northbound,
        metadata: %{}
      })
      |> Ash.create!(scope: scope)

    run =
      run
      |> Ash.Changeset.for_update(:bind_collection, %{
        collection_id: "collection-2026-09-01",
        collection_content_hash: String.duplicate("a", 64),
        collection_observed_at: ~U[2026-09-01 08:00:00.000000Z],
        raw_rows: 15,
        excluded_rows: 0,
        invalid_rows: 1,
        valid_occurrences: 14,
        distinct_source_ids: 12,
        duplicate_occurrences: 2,
        conflicting_duplicate_ids: 1,
        eligible_count: 9,
        withheld_count: 3,
        reconciliation_status: :pending,
        metadata: %{"accounting_status" => "exact"}
      })
      |> Ash.update!(scope: scope)

    _run =
      run
      |> Ash.Changeset.for_update(:finish_success, %{
        device_count: 12,
        updated_count: 9,
        skipped_count: 3,
        error_count: 0,
        eligible_count: 9,
        withheld_count: 3,
        accepted_count: 9,
        failed_count: 0,
        unattempted_count: 0,
        reconciliation_status: :degraded,
        metadata: %{
          "accounting_status" => "exact",
          "collection" => %{
            "duplicate_source_id_examples" => ["armis-101", "armis-202"],
            "invalid_row_examples" => ["query=main page=1 row=7"]
          },
          "withheld_reason_counts" => %{"multiple_typed_ids_per_device" => 3}
        }
      })
      |> Ash.update!(scope: scope)

    {:ok, lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert has_element?(lv, "#armis-reconciliation-funnel")
    assert has_element?(lv, "#armis-reconciliation-statuses")
    assert has_element?(lv, "#armis-withheld-reasons")
    assert has_element?(lv, "#armis-run-target-export")
    assert has_element?(lv, "#armis-duplicate-examples")
    assert has_element?(lv, "#armis-invalid-examples")
    assert html =~ "Distinct Armis IDs"
    assert html =~ "Accepted by Armis"
    assert html =~ "Unattempted IDs"
    assert html =~ "multiple typed ids per device: 3"
    refute has_element?(lv, "#armis-accounting-unavailable")
  end

  test "authorized operator can export a complete per-source-ID ledger", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Ledger Export",
        custom_fields: ["availability_status"],
        northbound_enabled: true
      })

    run =
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(:start_run, %{
        integration_source_id: source.id,
        run_type: :armis_northbound,
        metadata: %{}
      })
      |> Ash.create!(scope: scope)

    run =
      run
      |> Ash.Changeset.for_update(:bind_collection, %{
        collection_id: "collection-export",
        collection_content_hash: String.duplicate("b", 64),
        collection_observed_at: ~U[2026-09-01 08:00:00.000000Z],
        raw_rows: 1,
        excluded_rows: 0,
        invalid_rows: 0,
        valid_occurrences: 1,
        distinct_source_ids: 1,
        duplicate_occurrences: 0,
        conflicting_duplicate_ids: 0,
        eligible_count: 0,
        withheld_count: 1,
        reconciliation_status: :pending,
        metadata: %{"accounting_status" => "exact"}
      })
      |> Ash.update!(scope: scope)

    now = DateTime.utc_now()

    filler_targets =
      Enum.map(1..1_001, fn index ->
        %{
          id: Ecto.UUID.bingenerate(),
          integration_update_run_id: run.id,
          collection_id: run.collection_id,
          source_object_id: "armis-#{String.pad_leading(to_string(index), 4, "0")}",
          canonical_device_uid: "device-export-#{index}",
          eligibility: :eligible,
          outcome: :accepted,
          reason: nil,
          is_available: true,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    {1_002, _} =
      Repo.insert_all(IntegrationUpdateRunTarget, [
        %{
          id: Ecto.UUID.bingenerate(),
          integration_update_run_id: run.id,
          collection_id: run.collection_id,
          source_object_id: "=armis-formula",
          canonical_device_uid: "device-export",
          eligibility: :withheld,
          outcome: :withheld,
          reason: "multiple_typed_ids_per_device",
          is_available: nil,
          metadata: %{"typed_ids" => ["101", "202"]},
          inserted_at: now,
          updated_at: now
        }
        | filler_targets
      ])

    conn = get(conn, ~p"/settings/networks/integrations/runs/#{run.id}/export.csv")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    assert body =~ "source_object_id"
    assert body =~ "\"'=armis-formula\""
    assert body =~ "multiple_typed_ids_per_device"
    assert body =~ "armis-1001"
  end

  test "details modal shows armis credential presence without revealing the secret", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Credential Detail",
        credentials: %{api_key: "hidden-armis-api-key", api_secret: "hidden-armis-secret"}
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Credentials"
    # Neither credential is ever rendered. The detail panel reports PRESENCE for
    # both, which is all an operator needs to know whether a save took. The key
    # was previously printed verbatim in a <code> block next to a secret that
    # correctly showed only a badge -- the fixture was even named
    # "visible-armis-api-key" -- but nothing in the schema makes the key less
    # sensitive than the secret.
    refute html =~ "hidden-armis-api-key"
    refute html =~ "hidden-armis-secret"
    assert html =~ "Saved"
  end

  test "details modal shows recent agent config dispatch diagnostics", %{
    conn: conn,
    scope: scope
  } do
    source =
      create_armis_source!(scope, %{
        name: "Armis Config Dispatch Detail",
        credentials: %{api_key: "dispatch-api-key", api_secret: "dispatch-secret"}
      })

    DependencyDiagnostics.record(%{
      dependency_id: :integration_source_sync_config,
      resource_id: source.id,
      resource_name: source.name,
      config_type: :sync,
      action_type: :update,
      affected_agents: [source.agent_id],
      affected_agent_count: 1,
      result: :ok,
      secrets: %{"api_secret" => true},
      recorded_at: DateTime.utc_now()
    })

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Agent Config Dispatch"
    assert html =~ "sync"
    assert html =~ "Pushed"
    assert html =~ source.agent_id
    refute html =~ "dispatch-secret"
  end

  test "details modal suppresses stale internal timestamp precision errors", %{
    conn: conn,
    scope: scope
  } do
    raw_error = """
    %ArgumentError{message: ":utc_datetime expects microseconds to be empty, got: ~U[2026-05-15 18:00:08.246357Z]\n\nUse `DateTime.truncate(utc_datetime, :second)` (available in Elixir v1.6+) to remove microseconds.\n"}
    """

    source =
      create_armis_source!(scope, %{
        name: "Armis Stale Error Detail",
        credentials: %{api_key: "stale-error-key", api_secret: "stale-error-secret"}
      })

    source =
      source
      |> Ash.Changeset.for_update(:sync_start, %{device_count: 0})
      |> Ash.update!(scope: scope)

    source
    |> Ash.Changeset.for_update(:sync_failed, %{
      result: :failed,
      device_count: 0,
      error_message: raw_error
    })
    |> Ash.update!(scope: scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

    assert html =~ "Agent Config Dispatch"
    assert html =~ "No recent config dispatch recorded for this source."
    refute html =~ "%ArgumentError"
    refute html =~ ":utc_datetime expects microseconds"
    refute html =~ "DateTime.truncate(utc_datetime, :second)"
  end

  test "prefix tag preview panel is on the CRM/IPAM tab and accepts empty IP", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/integrations?tab=crm_ipam")

    assert html =~ "Prefix tag preview"
    assert html =~ "local node"
    assert has_element?(lv, ~s(form[phx-submit="prefix_tag_preview"] input[name="ip"]))

    lv
    |> form(~s(form[phx-submit="prefix_tag_preview"]), %{"ip" => "   "})
    |> render_submit()

    assert render(lv) =~ "Enter an IP address"
  end

  test "prefix tag preview looks up the local trie and shows matches", %{conn: conn} do
    alias ServiceRadar.PrefixTags.Store

    Store.put_rows("netbox", [
      %{prefix: "10.1.0.0/16", tags: ["netbox:tag:corp", "site:hq"], source: "netbox"}
    ])

    on_exit(fn -> Store.clear("netbox") end)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations?tab=crm_ipam")

    lv
    |> form(~s(form[phx-submit="prefix_tag_preview"]), %{"ip" => "10.1.2.3"})
    |> render_submit()

    html = render(lv)
    assert html =~ "Most-specific first"
    assert html =~ "10.1.0.0/16"
    assert html =~ "netbox:tag:corp"
    assert html =~ "site:hq"
    assert html =~ "netbox"
  end

  test "prefix tag preview reports no match for unmapped IPs", %{conn: conn} do
    alias ServiceRadar.PrefixTags.Store

    Store.clear()
    on_exit(fn -> Store.clear() end)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations?tab=crm_ipam")

    lv
    |> form(~s(form[phx-submit="prefix_tag_preview"]), %{"ip" => "203.0.113.9"})
    |> render_submit()

    assert render(lv) =~ "No matching prefixes for this address."
  end

  test "viewer without integrations manage is redirected", %{conn: _conn} do
    viewer = AccountsFixtures.user_fixture(%{role: :viewer})
    viewer_conn = log_in_user(build_conn(), viewer)

    assert {:error, {:redirect, %{to: "/settings/profile"}}} =
             live(viewer_conn, ~p"/settings/networks/integrations")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp create_connected_agent! do
    uid = "agent-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{uid: uid, name: uid},
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp get_source_by_name!(name, scope) do
    IntegrationSource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.load([:credentials_encrypted, :credentials])
    |> Ash.read_one!(scope: scope)
  end

  defp create_armis_source!(scope, attrs) do
    credentials = Map.get(attrs, :credentials, %{api_key: "key", api_secret: "secret"})
    attrs = Map.delete(attrs, :credentials)

    defaults = %{
      name: "Armis Source #{System.unique_integer([:positive])}",
      source_type: :armis,
      endpoint: "https://armis.example.test/#{System.unique_integer([:positive])}",
      agent_id: create_connected_agent!().uid,
      custom_fields: [],
      northbound_enabled: false,
      northbound_interval_seconds: 3600
    }

    IntegrationSource
    |> Ash.Changeset.for_create(
      :create,
      defaults |> Map.merge(attrs) |> Map.put(:credentials, credentials)
    )
    |> Ash.create!(scope: scope)
  end

  defp create_run!(scope, source_id, attrs) do
    start_attrs = %{
      integration_source_id: source_id,
      run_type: :armis_northbound,
      metadata: %{trigger: "manual"}
    }

    run =
      IntegrationUpdateRun
      |> Ash.Changeset.for_create(:start_run, start_attrs)
      |> Ash.create!(scope: scope)

    action = Map.fetch!(attrs, :status_action)

    finish_attrs =
      attrs
      |> Map.delete(:status_action)
      |> Map.put_new(:metadata, %{trigger: "manual"})

    run
    |> Ash.Changeset.for_update(action, finish_attrs)
    |> Ash.update!(scope: scope)
  end

  describe "reusable credential selection" do
    # IntegrationSource has carried `credential_secret_id` and
    # sync_config_generator has branched on it for some time. Nothing in this UI
    # could set it, so in practice every source stored its own encrypted copy and
    # the shared inventory was unreachable from here.

    defp shared_secret!(name_suffix) do
      {:ok, secret} =
        ServiceRadar.Credentials.NetworkCredentialSecret.create_secret(
          %{
            name: "Shared integration credential #{name_suffix}",
            provider: "armis",
            credential_kind: :api_token,
            secret_payload: "shared-token-#{name_suffix}"
          },
          actor: system_actor()
        )

      secret
    end

    test "selecting a credential binds the source to it", %{conn: conn, scope: scope} do
      agent = create_connected_agent!()
      unique = System.unique_integer([:positive])
      source_name = "Bound Source #{unique}"
      secret = shared_secret!(unique)

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/new")

      lv
      |> form("#create_source_form", %{
        "form" => %{
          "name" => source_name,
          "source_type" => "armis",
          "endpoint" => "https://armis.example.test",
          "agent_id" => agent.uid,
          "discovery_interval_seconds" => "3600"
        },
        "cred_credential_secret_id" => secret.id
      })
      |> render_submit()

      source = get_source_by_name!(source_name, scope)

      assert source.credential_secret_id == secret.id
    end

    test "the form-only key never reaches the source", %{conn: conn, scope: scope} do
      agent = create_connected_agent!()
      unique = System.unique_integer([:positive])
      source_name = "No Leak Source #{unique}"
      secret = shared_secret!(unique)

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/new")

      lv
      |> form("#create_source_form", %{
        "form" => %{
          "name" => source_name,
          "source_type" => "armis",
          "endpoint" => "https://armis.example.test",
          "agent_id" => agent.uid,
          "discovery_interval_seconds" => "3600"
        },
        "cred_credential_secret_id" => secret.id,
        "cred_api_key" => "still-typed-a-key"
      })
      |> render_submit()

      source = get_source_by_name!(source_name, scope)

      # The per-source fields are left untouched rather than cleared, so clearing
      # the binding later falls back to whatever was already stored.
      assert source.credential_secret_id == secret.id
      refute Map.has_key?(source.credentials || %{}, "cred_credential_secret_id")
    end

    test "leaving the selector blank does not bind anything", %{conn: conn, scope: scope} do
      agent = create_connected_agent!()
      unique = System.unique_integer([:positive])
      source_name = "Unbound Source #{unique}"

      # A credential has to exist for the selector to render at all -- it is
      # hidden when the inventory is empty, so "blank" is only a meaningful
      # choice when there is something to choose.
      _available = shared_secret!(unique)

      {:ok, lv, _html} = live(conn, ~p"/settings/networks/integrations/new")

      lv
      |> form("#create_source_form", %{
        "form" => %{
          "name" => source_name,
          "source_type" => "armis",
          "endpoint" => "https://armis.example.test",
          "agent_id" => agent.uid,
          "discovery_interval_seconds" => "3600"
        },
        "cred_credential_secret_id" => "",
        "cred_api_key" => "armis-api-key"
      })
      |> render_submit()

      source = get_source_by_name!(source_name, scope)

      assert source.credential_secret_id == nil
      assert source.credentials["api_key"] == "armis-api-key"
    end
  end

  describe "composite export in run status" do
    defp composite_run!(scope, source, metadata) do
      create_run!(scope, source.id, %{
        status_action: :finish_success,
        device_count: 4,
        updated_count: 4,
        skipped_count: 0,
        error_count: 0,
        metadata: Map.merge(%{trigger: "manual"}, metadata)
      })
    end

    test "a run that exported a composite check shows its slug and value form", %{
      conn: conn,
      scope: scope
    } do
      source = create_armis_source!(scope, %{})

      composite_run!(scope, source, %{
        composite_check_slug: "pci-isolation",
        composite_value_form: "verdict",
        composite_custom_field: "sr_isolation"
      })

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

      assert html =~ "Composite"
      assert html =~ "pci-isolation"
      assert html =~ "(verdict)"
    end

    test "the status value form is distinguishable from the verdict form", %{
      conn: conn,
      scope: scope
    } do
      source = create_armis_source!(scope, %{})

      composite_run!(scope, source, %{
        composite_check_slug: "pci-isolation",
        composite_value_form: "status"
      })

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

      # Verdict slugs are operator vocabulary and status is a fixed enum, so an
      # operator reading run history has to be able to tell which one went out.
      assert html =~ "(status)"
      refute html =~ "(verdict)"
    end

    test "a run with no composite export renders a dash rather than a blank cell", %{
      conn: conn,
      scope: scope
    } do
      source = create_armis_source!(scope, %{})

      create_run!(scope, source.id, %{
        status_action: :finish_success,
        device_count: 2,
        updated_count: 2,
        skipped_count: 0,
        error_count: 0
      })

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

      assert html =~ "Recent Runs"
      refute html =~ "(verdict)"
      refute html =~ "(status)"
    end

    test "the column reads the run's own metadata, not the source's current selection", %{
      conn: conn,
      scope: scope
    } do
      # The source is configured for one check while an older run exported a
      # different one. Reading the live selection would retroactively relabel
      # that run's history.
      source =
        create_armis_source!(scope, %{
          settings: %{
            "composite" => %{
              "check_slug" => "current-selection",
              "value_form" => "status",
              "custom_field" => "sr_isolation"
            }
          }
        })

      composite_run!(scope, source, %{
        composite_check_slug: "older-selection",
        composite_value_form: "verdict"
      })

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

      assert html =~ "older-selection"
      refute html =~ "current-selection"
    end

    test "a half-written metadata entry renders the dash rather than a partial label", %{
      conn: conn,
      scope: scope
    } do
      source = create_armis_source!(scope, %{})

      composite_run!(scope, source, %{composite_check_slug: "pci-isolation"})

      {:ok, _lv, html} = live(conn, ~p"/settings/networks/integrations/#{source.id}")

      # A slug with no value form does not say what actually went out, so it is
      # not shown at all.
      refute html =~ "pci-isolation"
    end
  end
end

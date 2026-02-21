defmodule ServiceRadarWebNGWeb.Settings.DeviceEnrichmentRulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  setup do
    original_dir = Application.get_env(:serviceradar_web_ng, :device_enrichment_rules_dir)

    tmp_dir =
      Path.join(System.tmp_dir!(), "device-enrichment-ui-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Application.put_env(:serviceradar_web_ng, :device_enrichment_rules_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if is_nil(original_dir) do
        Application.delete_env(:serviceradar_web_ng, :device_enrichment_rules_dir)
      else
        Application.put_env(:serviceradar_web_ng, :device_enrichment_rules_dir, original_dir)
      end
    end)

    %{tmp_dir: tmp_dir}
  end

  test "renders device enrichment settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/device-enrichment")

    assert html =~ "Device Enrichment Rules"
    assert html =~ "No raw YAML editing"
  end

  test "creates rule file and saves a typed rule", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/device-enrichment")

    lv
    |> element("#open-new-file")
    |> render_click()

    lv
    |> form("#new-rule-file-form", %{"new_file" => %{"file_name" => "custom-overrides.yaml"}})
    |> render_submit()

    assert has_element?(lv, "button[phx-value-file='custom-overrides.yaml']")

    lv
    |> element("#new-rule")
    |> render_click()

    lv
    |> form("#rule-editor-form", %{
      "rule" => %{
        "id" => "ubiquiti-router-custom",
        "enabled" => "on",
        "priority" => "1200",
        "confidence" => "95",
        "reason" => "UI test",
        "all_source" => "mapper",
        "any_sys_descr" => "udm-pro",
        "set_vendor_name" => "Ubiquiti",
        "set_type" => "Router",
        "set_type_id" => "12"
      }
    })
    |> render_submit()

    file_path = Path.join(tmp_dir, "custom-overrides.yaml")
    assert File.exists?(file_path)

    {:ok, content} = File.read(file_path)
    assert content =~ "ubiquiti-router-custom"
    assert content =~ "vendor_name"
    assert content =~ "type_id"
  end

  test "runs simulation and shows matched rule output", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/device-enrichment")

    payload = """
    {
      "hostname": "farm01",
      "source": "mapper",
      "metadata": {
        "sys_object_id": ".1.3.6.1.4.1.8072.3.2.10",
        "sys_descr": "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
        "sys_name": "farm01",
        "ip_forwarding": "1"
      }
    }
    """

    lv
    |> form("#simulation-form", %{"simulation" => %{"payload" => payload}})
    |> render_submit()

    assert render(lv) =~ "Rule:"
    assert render(lv) =~ "ubiquiti-router-udm"
    assert render(lv) =~ "Vendor:"
    assert render(lv) =~ "Ubiquiti"
  end

  test "apply now shows coordinator error when core is not reachable", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/device-enrichment")

    lv
    |> element("#apply-now")
    |> render_click()

    assert render(lv) =~ "No core coordinator found"
  end

  test "duplicates a rule and allows reordering", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/device-enrichment")

    lv
    |> element("#open-new-file")
    |> render_click()

    lv
    |> form("#new-rule-file-form", %{"new_file" => %{"file_name" => "order-test.yaml"}})
    |> render_submit()

    lv
    |> element("#new-rule")
    |> render_click()

    lv
    |> form("#rule-editor-form", %{
      "rule" => %{
        "id" => "base-rule",
        "enabled" => "on",
        "priority" => "1000",
        "confidence" => "90",
        "reason" => "base",
        "all_source" => "mapper",
        "set_vendor_name" => "Ubiquiti"
      }
    })
    |> render_submit()

    lv
    |> element("tr#rule-row-0 button[phx-click='duplicate_rule']")
    |> render_click()

    assert render(lv) =~ "base-rule-copy-1"

    lv
    |> element("tr#rule-row-1 button[phx-click='move_rule_up']")
    |> render_click()

    html = render(lv)
    assert html =~ "Rule order updated"
    assert html =~ "base-rule-copy-1"
  end

  test "imports yaml into selected file and exports current yaml", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/device-enrichment")

    lv
    |> element("#open-new-file")
    |> render_click()

    lv
    |> form("#new-rule-file-form", %{"new_file" => %{"file_name" => "import-export.yaml"}})
    |> render_submit()

    yaml = """
    rules:
      - id: imported-rule
        enabled: true
        priority: 1600
        confidence: 88
        reason: imported from test
        match:
          all:
            source: [mapper]
          any: {}
        set:
          vendor_name: Ubiquiti
          type: Router
    """

    lv
    |> element("#open-import-yaml")
    |> render_click()

    lv
    |> form("#import-yaml-form", %{"import" => %{"yaml" => yaml}})
    |> render_submit()

    assert render(lv) =~ "Imported YAML into import-export.yaml"
    assert render(lv) =~ "imported-rule"

    lv
    |> element("#open-export-yaml")
    |> render_click()

    exported = render(lv)
    assert exported =~ "Export YAML"
    assert exported =~ "imported-rule"
    assert exported =~ "import-export.yaml"

    lv
    |> element("#download-export-yaml")
    |> render_click()

    assert render(lv) =~ "Downloading import-export.yaml"
  end

  test "can deactivate, activate, and delete an override rule file", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, lv, _html} = live(conn, ~p"/settings/networks/device-enrichment")

    lv
    |> element("#open-new-file")
    |> render_click()

    lv
    |> form("#new-rule-file-form", %{"new_file" => %{"file_name" => "test.yaml"}})
    |> render_submit()

    assert File.exists?(Path.join(tmp_dir, "test.yaml"))

    lv
    |> element("button[phx-click='deactivate_file'][phx-value-file='test.yaml']")
    |> render_click()

    assert render(lv) =~ "Deactivated test.yaml"
    refute File.exists?(Path.join(tmp_dir, "test.yaml"))
    assert File.exists?(Path.join(tmp_dir, "test.yaml.disabled"))

    lv
    |> element("button[phx-click='activate_file'][phx-value-file='test.yaml']")
    |> render_click()

    assert render(lv) =~ "Activated test.yaml"
    assert File.exists?(Path.join(tmp_dir, "test.yaml"))
    refute File.exists?(Path.join(tmp_dir, "test.yaml.disabled"))

    lv
    |> element("button[phx-click='delete_file'][phx-value-file='test.yaml']")
    |> render_click()

    assert render(lv) =~ "Deleted test.yaml"
    refute File.exists?(Path.join(tmp_dir, "test.yaml"))
    refute File.exists?(Path.join(tmp_dir, "test.yaml.disabled"))
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end

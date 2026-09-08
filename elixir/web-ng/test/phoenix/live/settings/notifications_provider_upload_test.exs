defmodule ServiceRadarWebNGWeb.Settings.NotificationsProviderUploadTest do
  @moduledoc """
  Upload, inline validation, versioning, and rollback on the Providers tab
  (tasks 2.3.1-2.3.3, 2.5.4).

  Four things are proven here, and each of them is a claim the declarative tier
  makes rather than a rendering detail:

    * an operator adds a provider by pasting a document, and the row that lands
      is `:declarative`, `source: :uploaded`, `managed: false`, version 1;
    * a document that does not validate is refused with the PATH of each problem
      and the validator's own sentence - a generic "invalid document" would leave
      the operator bisecting their own YAML - and no provider row is written;
    * a second upload is a new version, and a rollback re-uploads an older
      document as the NEXT version rather than rewriting the one deliveries
      already point at;
    * the upload events are refused for a scope without
      `notifications.providers.manage` when they are pushed DIRECTLY at the
      mounted LiveView. A hidden button is not authorization, so the negative
      case bypasses the DOM entirely and then checks the tables.

  The under-privileged actor is an `:operator`, chosen because it holds
  `notifications.channels.view` - so it can MOUNT the Providers tab and forge an
  event there - while holding none of `notifications.providers.manage`.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.NotificationsFixtures

  require Ash.Query

  @key "acme_pager"

  @document """
  schema_version: 1
  key: #{@key}
  display_name: Acme Pager
  description: Page the Acme on-call rotation.
  capabilities: [send, test]
  payload_formats: [markdown, plain]
  routes: [control_plane]
  config_schema:
    type: object
    additionalProperties: false
    required: [webhook_url]
    properties:
      webhook_url:
        type: string
        title: Webhook URL
      team:
        type: string
        title: Team
  request:
    method: POST
    url: "{{ config.webhook_url }}"
    headers:
      Content-Type: application/json
    body_format: json
    body:
      summary: "{{ alert.severity | upper }} {{ alert.title }}"
      routing_key: "{{ config.team | default: \\"noc\\" }}"
  success:
    status: [200, 202]
  failure:
    retryable_status: [429, "500-599"]
  """

  setup %{conn: conn} do
    NotificationsFixtures.seed_providers()

    admin = AccountsFixtures.user_fixture(%{role: :admin})
    operator = AccountsFixtures.user_fixture(%{role: :operator})

    %{
      conn: log_in_user(conn, admin),
      operator: operator,
      operator_conn: log_in_user(build_conn(), operator)
    }
  end

  describe "upload" do
    test "a pasted document becomes a declarative provider", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      assert lv |> element("button[phx-click='new_provider_upload']") |> render_click() =~
               "Upload a provider definition"

      html = render_submit(lv, "save_provider_upload", %{"provider" => %{"document" => @document}})

      assert html =~ "saved as version 1"

      provider = provider!(@key)

      assert provider.provider_type == :declarative
      assert provider.source == :uploaded
      refute provider.managed
      assert provider.definition_version == 1
      assert provider.status == :draft
      assert provider.display_name == "Acme Pager"
      assert provider.capabilities == [:send, :test]
      assert provider.supported_routes == [:control_plane]
      assert provider.definition["request"]["method"] == "POST"

      # The tier is authored, not compiled: an uploaded provider names no module.
      assert is_nil(provider.implementation_module)
    end

    test "the editor previews the request the document would issue", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      render_click(lv, "new_provider_upload", %{})

      html =
        render_change(lv, "validate_provider_upload", %{"provider" => %{"document" => @document}})

      assert html =~ "Rendered request"
      assert html =~ "POST"
      assert html =~ "config.webhook_url"
      assert html =~ "alert.title"
      # The channel form the document declares, read back from its config_schema.
      assert html =~ "webhook_url"
      assert html =~ "Webhook URL"
    end

    test "a second upload of the same key is a new version, not a second provider", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      render_submit(lv, "save_provider_upload", %{"provider" => %{"document" => @document}})

      html =
        render_submit(lv, "save_provider_upload", %{
          "provider" => %{"document" => renamed(@document, "Acme Pager 2")}
        })

      assert html =~ "saved as version 2"

      provider = provider!(@key)

      assert provider.definition_version == 2
      assert provider.display_name == "Acme Pager 2"
      assert length(providers_with_key(@key)) == 1
    end

    test "an uploaded key belonging to another tier is refused by name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      # `webhook` is a seeded `:native` provider. An uploaded document must never
      # take over a provider resolved from the compile-time allowlist.
      html =
        render_submit(lv, "save_provider_upload", %{
          "provider" => %{"document" => String.replace(@document, "key: #{@key}", "key: webhook")}
        })

      assert html =~ "already belongs to a Native provider"
      assert provider!("webhook").provider_type == :native
    end

    test "saving a blank document says so rather than doing nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      html = render_submit(lv, "save_provider_upload", %{"provider" => %{"document" => "  "}})

      assert html =~ "Paste a YAML or JSON definition document first"
    end
  end

  describe "inline validation" do
    test "names the path of every problem and repeats the validator's sentence", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      broken =
        @document
        |> String.replace("method: POST", "method: GET")
        |> String.replace("{{ config.webhook_url }}", "http://pager.example.com/hook")
        |> String.replace("{{ config.team | default: \\\"noc\\\" }}", "{{ config.nope }}")

      html =
        render_change(lv, "validate_provider_upload", %{"provider" => %{"document" => broken}})

      assert html =~ "was not accepted"

      # The PATH of each problem, which is what makes the message actionable.
      assert html =~ "request.method"
      assert html =~ "request.url"
      assert html =~ "request.body.routing_key"

      # The validator's own sentences, not a summary of them.
      assert html =~ "disallowed_scheme"
      assert html =~ "config.nope"

      refute html =~ "Rendered request"
      assert providers_with_key(@key) == []
    end

    test "a document carrying markup is refused as a document", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      html =
        render_change(lv, "validate_provider_upload", %{
          "provider" => %{"document" => @document <> "html: \"<b>no</b>\"\n"}
        })

      assert html =~ "never ships markup"
      assert providers_with_key(@key) == []
    end

    test "a failed save writes nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      html =
        render_submit(lv, "save_provider_upload", %{
          "provider" => %{"document" => String.replace(@document, "key: #{@key}", "key: 9bad")}
        })

      assert html =~ "must be a lower-case provider key"
      assert providers_with_key("9bad") == []
    end
  end

  describe "versions and rollback" do
    setup %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/notifications/providers")

      render_submit(lv, "save_provider_upload", %{"provider" => %{"document" => @document}})

      render_submit(lv, "save_provider_upload", %{
        "provider" => %{"document" => renamed(@document, "Acme Pager 2")}
      })

      %{lv: lv, provider: provider!(@key)}
    end

    test "the panel lists every definition version and what binds to them", %{
      lv: lv,
      provider: provider
    } do
      NotificationsFixtures.channel_fixture(%{
        provider: provider,
        name: "Acme on-call",
        config: %{"webhook_url" => "https://93.184.216.34/hooks/acme"}
      })

      html = render_click(lv, "show_provider_versions", %{"id" => provider.id})

      assert html =~ "Definition versions"
      assert html =~ "Version 1"
      assert html =~ "Version 2"
      assert html =~ "Channels bound to this provider render at v2"
      assert html =~ "Acme on-call"
    end

    test "rolling back writes the older document as the NEXT version", %{
      lv: lv,
      provider: provider
    } do
      render_click(lv, "show_provider_versions", %{"id" => provider.id})

      confirmation =
        render_click(lv, "confirm_rollback_provider", %{
          "id" => provider.id,
          "version" => "1"
        })

      assert confirmation =~ "Roll back to version 1?"
      assert confirmation =~ "re-uploaded as version 3"

      html = render_click(lv, "rollback_provider", %{"id" => provider.id, "version" => "1"})

      assert html =~ "Rolled back to version 1, saved as version 3"

      rolled_back = provider!(@key)

      # Version 3 - not 1. `NotificationDelivery.provider_version` names the
      # version that rendered each delivery, so history is append-only.
      assert rolled_back.definition_version == 3
      assert rolled_back.display_name == "Acme Pager"
      assert rolled_back.definition["display_name"] == "Acme Pager"
    end

    test "a rollback can itself be rolled back", %{lv: lv, provider: provider} do
      render_click(lv, "rollback_provider", %{"id" => provider.id, "version" => "1"})
      html = render_click(lv, "rollback_provider", %{"id" => provider.id, "version" => "2"})

      assert html =~ "saved as version 4"
      assert provider!(@key).display_name == "Acme Pager 2"
    end

    test "an unknown version is refused", %{lv: lv, provider: provider} do
      html = render_click(lv, "rollback_provider", %{"id" => provider.id, "version" => "99"})

      assert html =~ "not available"
      assert provider!(@key).definition_version == 2
    end

    test "a native provider carries no uploaded definition", %{lv: lv} do
      native = provider!("webhook")

      html = render_click(lv, "show_provider_versions", %{"id" => native.id})

      assert html =~ "carries no uploaded definition"
    end
  end

  describe "without notifications.providers.manage" do
    setup %{operator_conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/settings/notifications/providers")

      %{lv: lv, html: html}
    end

    test "no upload control is rendered", %{html: html} do
      refute html =~ "phx-click=\"new_provider_upload\""
      refute html =~ "phx-click=\"show_provider_versions\""
    end

    test "every upload and version event forged at the LiveView is refused", %{lv: lv} do
      provider = provider!("webhook")

      forged = [
        {"new_provider_upload", %{}},
        {"replace_provider_definition", %{"id" => to_string(provider.id)}},
        {"cancel_provider_upload", %{}},
        {"validate_provider_upload", %{"provider" => %{"document" => @document}}},
        {"save_provider_upload", %{"provider" => %{"document" => @document}}},
        {"show_provider_versions", %{"id" => to_string(provider.id)}},
        {"close_provider_versions", %{}},
        {"confirm_rollback_provider", %{"id" => to_string(provider.id), "version" => "1"}},
        {"rollback_provider", %{"id" => to_string(provider.id), "version" => "1"}}
      ]

      for {event, params} <- forged do
        html = render_click(lv, event, params)

        assert html =~ "not authorized", "#{event} was not refused"
        refute html =~ "Upload a provider definition", "#{event} opened the editor"
      end

      assert providers_with_key(@key) == []
    end

    test "the resource policy refuses the write even with the LiveView bypassed", %{
      operator: operator
    } do
      # The event gate and the resource policy are two independent refusals. This
      # one skips the LiveView entirely and calls the Ash action as the operator.
      scope = operator_scope(operator)

      result =
        NotificationProvider
        |> Ash.Changeset.for_create(
          :create,
          %{
            provider_key: @key,
            provider_type: :declarative,
            display_name: "Forged",
            capabilities: [:send, :test],
            supported_routes: [:control_plane],
            payload_formats: [:markdown],
            config_schema: %{},
            definition: %{"schema_version" => 1}
          },
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = result
      assert providers_with_key(@key) == []
    end
  end

  defp operator_scope(user) do
    scope = %Scope{user: user}

    %{scope | permissions: ServiceRadarWebNG.RBAC.permissions_for_scope(scope)}
  end

  defp renamed(document, display_name) do
    String.replace(document, "display_name: Acme Pager", "display_name: " <> display_name)
  end

  defp provider!(key) do
    case providers_with_key(key) do
      [provider] -> provider
      other -> flunk("expected exactly one #{key} provider, got #{length(other)}")
    end
  end

  # Read with the system actor rather than the viewer's scope: a scope-scoped
  # read returns the same empty list whether the row was written or not.
  defp providers_with_key(key) do
    NotificationProvider
    |> NotificationsFixtures.read_all()
    |> Enum.filter(&(&1.provider_key == key))
  end
end

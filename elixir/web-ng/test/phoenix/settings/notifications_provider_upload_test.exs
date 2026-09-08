defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderUploadTest do
  @moduledoc """
  The declarative upload form's pure half: what an operator is told about a
  document, what the preview shows them, and how a definition becomes provider
  attributes.

  The assertions that matter are about MESSAGES. A validator that refuses a
  document is worth nothing to the operator writing it unless the refusal names
  the path and says what to do, so these tests read the text rather than only
  checking that a failure happened.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderUpload
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderVersions

  @moduletag :db_free

  @document """
  schema_version: 1
  key: acme_pager
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
      api_token:
        type: string
        title: API token
        secretRef: true
        credentialKind: api_token
  request:
    method: POST
    url: "{{ config.webhook_url }}"
    headers:
      Content-Type: application/json
      Authorization: "Bearer {{ secrets.api_token }}"
    body_format: json
    body:
      text: "{{ alert.severity | upper }} {{ alert.title }}"
      team: "{{ config.team | default: \\"noc\\" }}"
  success:
    status: [200, 202]
  failure:
    retryable_status: [429, "500-599"]
  """

  defp valid_form do
    ProviderUpload.blank_form()
    |> ProviderUpload.merge(%{"document" => @document})
    |> ProviderUpload.validate()
  end

  describe "a blank form" do
    test "reports nothing, because there is nothing to report yet" do
      form = ProviderUpload.validate(ProviderUpload.blank_form())

      assert form.errors == []
      assert form.definition == nil
      assert form.preview == nil
    end

    test "whitespace is still blank" do
      form =
        ProviderUpload.blank_form()
        |> ProviderUpload.merge(%{"document" => "   \n  "})
        |> ProviderUpload.validate()

      assert form.errors == []
      assert form.definition == nil
    end
  end

  describe "a valid document" do
    test "parses into a definition and a preview" do
      form = valid_form()

      assert form.errors == []
      assert %Definition{key: "acme_pager", display_name: "Acme Pager"} = form.definition
      assert form.preview
    end

    test "the preview shows the request the document would issue" do
      preview = valid_form().preview

      assert preview.method == "POST"
      assert preview.url == "<config.webhook_url>"
      assert {"content-type", "application/json"} in preview.headers
      assert {"authorization", "Bearer <secrets.api_token>"} in preview.headers
      assert preview.body_format == :json
      assert preview.success == "200, 202"
      assert preview.retryable == "429, 500-599"
    end

    test "the preview substitutes markers, never values, and resolves no secret" do
      preview = valid_form().preview

      # `<secrets.api_token>` is this module's marker for where the resolved
      # credential goes. Nothing read a secret to render it: no channel exists at
      # upload time and the broker is never consulted here.
      assert preview.body =~ "<alert.title>"
      assert preview.body =~ "<config.team>"
      refute preview.body =~ "secretref:"
    end

    test "the preview applies the document's filters" do
      # `upper` is applied to the marker, which is how an operator sees that the
      # filter parsed and where it lands.
      assert valid_form().preview.body =~ "<ALERT.SEVERITY>"
    end

    test "the preview lists the channel form the document declares" do
      fields = valid_form().preview.fields

      assert %{name: "webhook_url", title: "Webhook URL", required?: true, secret?: false} =
               Enum.find(fields, &(&1.name == "webhook_url"))

      assert %{name: "api_token", secret?: true, required?: false} =
               Enum.find(fields, &(&1.name == "api_token"))
    end
  end

  describe "an invalid document" do
    test "names the path of every problem, not just the first" do
      document = """
      schema_version: 1
      key: broken
      display_name: Broken
      capabilities: [send, test]
      payload_formats: [markdown]
      config_schema:
        type: object
        properties:
          api_key:
            type: string
      request:
        method: GET
        url: http://example.com/hook
        body_format: json
        body:
          text: "{{ alert.title }}"
      success:
        status: [200]
      failure:
        retryable_status: [500]
      """

      form =
        ProviderUpload.blank_form()
        |> ProviderUpload.merge(%{"document" => document})
        |> ProviderUpload.validate()

      assert form.definition == nil
      paths = Enum.map(form.errors, & &1.path)

      assert "request.method" in paths
      assert "request.url" in paths
      assert "config_schema.properties.api_key" in paths
    end

    test "repeats the validator's own sentence rather than a generic refusal" do
      document = String.replace(@document, "{{ config.team", "{{ config.nonexistent")

      form =
        ProviderUpload.blank_form()
        |> ProviderUpload.merge(%{"document" => document})
        |> ProviderUpload.validate()

      error = Enum.find(form.errors, &(&1.path == "request.body.team"))

      assert error
      assert error.message =~ "config.nonexistent"
      assert error.message =~ "This document declares"
      refute error.message == "invalid document"
    end

    test "a scheme the outbound policy would refuse is reported at save time" do
      document = String.replace(@document, "{{ config.webhook_url }}", "http://pager.example.com")

      form =
        ProviderUpload.blank_form()
        |> ProviderUpload.merge(%{"document" => document})
        |> ProviderUpload.validate()

      messages =
        form.errors
        |> Enum.filter(&(&1.path == "request.url"))
        |> Enum.map_join(" ", & &1.message)

      assert messages =~ "disallowed_scheme"
    end

    test "a document carrying markup is refused as a document" do
      form =
        ProviderUpload.blank_form()
        |> ProviderUpload.merge(%{"document" => @document <> "html: \"<b>no</b>\"\n"})
        |> ProviderUpload.validate()

      assert Enum.any?(form.errors, &(&1.message =~ "never ships markup"))
      assert form.definition == nil
    end

    test "a document past the size cap is refused without being held in assigns" do
      oversized = String.duplicate("a", ProviderUpload.max_document_bytes() + 1)

      form = ProviderUpload.merge(ProviderUpload.blank_form(), %{"document" => oversized})

      assert form.error =~ "larger than"
      assert ProviderUpload.document(form) == ""
    end
  end

  describe "provider attributes" do
    test "a create carries the tier, the key, and version 1" do
      attrs = ProviderUpload.create_attrs(valid_form().definition)

      assert attrs.provider_key == "acme_pager"
      assert attrs.provider_type == :declarative
      assert attrs.definition_version == 1
      assert attrs.source == :uploaded
      assert attrs.capabilities == [:send, :test]
      assert attrs.supported_routes == [:control_plane]
      assert attrs.payload_formats == [:markdown, :plain]
      assert attrs.definition["request"]["method"] == "POST"
    end

    test "an update never rewrites a version and never changes the tier" do
      attrs = ProviderUpload.update_attrs(valid_form().definition, 4)

      assert attrs.definition_version == 5
      refute Map.has_key?(attrs, :provider_key)
      refute Map.has_key?(attrs, :provider_type)
    end

    test "the stored document round-trips back through the validator" do
      definition = valid_form().definition
      stored = ProviderUpload.create_attrs(definition).definition

      assert {:ok, reparsed} = Definition.parse(stored)
      assert reparsed == definition
    end

    test "a form seeded from a stored provider validates immediately" do
      stored = ProviderUpload.create_attrs(valid_form().definition).definition

      form =
        ProviderUpload.form_for(%{
          id: "11111111-1111-1111-1111-111111111111",
          provider_type: :declarative,
          provider_key: "acme_pager",
          definition: stored
        })

      assert form.mode == :replace
      assert form.errors == []
      assert form.definition.key == "acme_pager"
    end
  end

  describe "version history" do
    test "one entry per definition version, newest first" do
      rows = [
        version_row(1, %{"definition" => %{"key" => "acme_pager"}, "definition_version" => 1}, action: "create"),
        version_row(2, %{"status" => "active"}, action: "activate"),
        version_row(3, %{"definition" => %{"key" => "acme_pager", "v" => 2}, "definition_version" => 2})
      ]

      assert [second, first] = ProviderVersions.history(rows, 2)

      assert second.number == 2
      assert second.current?
      assert first.number == 1
      refute first.current?
      assert first.action == "create"
    end

    test "an activate is not a definition version" do
      rows = [
        version_row(1, %{"definition" => %{"key" => "k"}, "definition_version" => 1}),
        version_row(2, %{"status" => "active"}, action: "activate")
      ]

      assert [only] = ProviderVersions.history(rows, 1)
      assert only.number == 1
    end

    test "a version that changed only its number carries the document forward" do
      # This is the rollback-to-an-identical-document case: `changes_only`
      # tracking omits `definition` when the value did not change.
      rows = [
        version_row(1, %{"definition" => %{"key" => "k"}, "definition_version" => 1}),
        version_row(2, %{"definition_version" => 2})
      ]

      assert [current, _first] = ProviderVersions.history(rows, 2)
      assert current.definition == %{"key" => "k"}
    end

    test "rows are folded chronologically even when they arrive newest first" do
      rows = [
        version_row(3, %{"definition" => %{"n" => 3}, "definition_version" => 3}),
        version_row(1, %{"definition" => %{"n" => 1}, "definition_version" => 1}),
        version_row(2, %{"definition" => %{"n" => 2}, "definition_version" => 2})
      ]

      assert [3, 2, 1] == rows |> ProviderVersions.history(3) |> Enum.map(& &1.number)
    end

    test "atom-keyed changes are read the same as their jsonb round trip" do
      rows = [version_row(1, %{definition: %{"key" => "k"}, definition_version: 1})]

      assert [entry] = ProviderVersions.history(rows, 1)
      assert entry.number == 1
    end

    test "find and supersedable answer over the entries" do
      rows = [
        version_row(1, %{"definition" => %{"n" => 1}, "definition_version" => 1}),
        version_row(2, %{"definition" => %{"n" => 2}, "definition_version" => 2})
      ]

      entries = ProviderVersions.history(rows, 2)

      assert ProviderVersions.find(entries, 1).definition == %{"n" => 1}
      assert ProviderVersions.find(entries, 99) == nil
      assert [%{number: 1}] = ProviderVersions.supersedable(entries)
    end

    test "rows with no definition at all produce no history" do
      assert ProviderVersions.history([version_row(1, %{"status" => "active"})], 1) == []
      assert ProviderVersions.history([], nil) == []
    end
  end

  defp version_row(sequence, changes, opts \\ []) do
    %{
      id: "0000000#{sequence}-0000-0000-0000-000000000000",
      changes: changes,
      version_inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], sequence, :second),
      version_action_name: Keyword.get(opts, :action, "update"),
      version_action_type: "update"
    }
  end
end

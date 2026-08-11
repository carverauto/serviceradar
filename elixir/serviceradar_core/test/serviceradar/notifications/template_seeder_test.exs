defmodule ServiceRadar.Notifications.TemplateSeederTest do
  @moduledoc """
  The template catalog is data and the renderer is pure, so these tests are
  database-free and async.

  The failure they exist to prevent is specific. A notification template is
  exercised for the first time during an incident: a variable path outside the
  published catalog renders as an empty string, and an alert class with no
  resolvable template for the negotiated format fails the dispatch outright. Both
  are silent until the page is owed. Asserting the shipped rows against
  `Template.Syntax` and then rendering every one of them is what turns that into
  a test failure at build time.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Notifications.NotificationTemplate
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Renderer.Rendered
  alias ServiceRadar.Notifications.SeedFingerprint
  alias ServiceRadar.Notifications.Template.Syntax
  alias ServiceRadar.Notifications.TemplateSeeder

  @expression_regex ~r/\{\{(.*?)\}\}/s

  defp catalog, do: TemplateSeeder.default_templates()

  defp texts(template), do: [template.subject_template, template.body_template]

  defp expressions(text) when is_binary(text) do
    @expression_regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [body] -> body end)
  end

  defp expressions(_text), do: []

  defp variable_paths(text) do
    text
    |> expressions()
    |> Enum.map(fn body -> body |> String.split("|") |> hd() |> String.trim() end)
  end

  defp filter_names(text) do
    text
    |> expressions()
    |> Enum.flat_map(fn body -> body |> String.split("|") |> tl() end)
    |> Enum.map(fn segment -> segment |> String.split(":") |> hd() |> String.trim() end)
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "0198f0aa-1111-7000-8000-000000000001",
        "title" => "Device tonka01 is unreachable",
        "message" => "ICMP probe failed three consecutive times",
        "severity" => "critical",
        "status" => "pending",
        "alert_class" => "device_down",
        "source" => "stateful_alert_engine",
        "dedupe_key" => "rule-42|device_id=abc|severity=critical",
        "rule_name" => "icmp_unreachable",
        "occurrence_count" => 3,
        "first_seen_at" => ~U[2026-08-09 12:00:00Z],
        "last_seen_at" => ~U[2026-08-09 12:05:00Z],
        "url" => "https://serviceradar.example.com/alerts/0198"
      },
      overrides
    )
  end

  defp context do
    %{
      "device" => %{"name" => "tonka01", "ip" => "10.0.2.11"},
      "system" => %{"name" => "ServiceRadar", "url" => "https://serviceradar.example.com"}
    }
  end

  defp render!(template, opts \\ []) do
    assert {:ok, rendered} =
             Renderer.render(
               Keyword.get(opts, :snapshot, snapshot()),
               template,
               template.payload_format,
               supported_formats: [template.payload_format],
               context: Keyword.get(opts, :context, context())
             )

    rendered
  end

  describe "coverage" do
    test "every payload format the renderer supports has a managed default" do
      seeded = catalog() |> Enum.map(& &1.payload_format) |> Enum.sort()

      assert seeded == Enum.sort(Renderer.payload_formats())
    end

    test "every row is the generic catch-all for its format" do
      # `provider_key: nil` is the row `:resolve` falls back to when no
      # provider-specific template exists; `"default"` is the catch-all alert
      # class. A provider-specific default would only shadow these.
      for template <- catalog() do
        assert template.alert_class == "default"
        assert is_nil(template.provider_key)
      end
    end

    test "selection keys are unique, which the NULLS NOT DISTINCT index enforces too" do
      keys = Enum.map(catalog(), &{&1.alert_class, &1.payload_format, &1.provider_key})

      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "names are unique and non-empty" do
      names = Enum.map(catalog(), & &1.name)

      assert length(Enum.uniq(names)) == length(names)
      assert Enum.all?(names, &(is_binary(&1) and &1 != ""))
    end

    test "every row ships managed and versioned" do
      for template <- catalog() do
        assert template.managed
        assert is_binary(template.template_version)
        assert template.template_version != ""
      end
    end
  end

  describe "the restricted substitution language (design D9)" do
    test "every subject and body validates" do
      for template <- catalog(), text <- texts(template) do
        assert Syntax.validate_template(text) == :ok,
               "#{template.name}: #{inspect(Syntax.validate_template(text))}"
      end
    end

    test "every variable path is an exact entry in the published catalog" do
      # Deliberately not accepting an open namespace. `alert.metadata.*` and
      # friends are operator data whose leaves cannot be enumerated, so a shipped
      # default that leaned on one would render empty on every alert that happens
      # not to carry that key.
      published = MapSet.new(Syntax.variable_catalog())

      for template <- catalog(), text <- texts(template), path <- variable_paths(text) do
        assert MapSet.member?(published, path),
               "#{template.name} uses \"#{path}\", which the renderer cannot resolve"
      end
    end

    test "every filter is one of the seven" do
      published = MapSet.new(Syntax.filters())

      for template <- catalog(), text <- texts(template), name <- filter_names(text) do
        assert MapSet.member?(published, name), "#{template.name} uses the filter \"#{name}\""
      end
    end

    test "no template carries a code construct" do
      for template <- catalog(), text <- texts(template) do
        for marker <- ["<%", "%>", "{%", "%}"] do
          refute String.contains?(text, marker), "#{template.name} contains #{marker}"
        end
      end
    end

    test "the payload format is one NotificationTemplate accepts" do
      allowed =
        NotificationTemplate
        |> Info.attribute(:payload_format)
        |> Map.fetch!(:constraints)
        |> Keyword.fetch!(:one_of)

      for template <- catalog() do
        assert template.payload_format in allowed
      end
    end
  end

  describe "rendering" do
    test "every seeded template renders a non-empty subject and body" do
      for template <- catalog() do
        rendered = render!(template)

        assert rendered.payload_format == template.payload_format
        assert String.trim(rendered.subject) != ""
        assert String.trim(rendered.body) != ""
      end
    end

    test "a fully populated alert leaves nothing unresolved" do
      for template <- catalog() do
        rendered = render!(template)

        refute Rendered.unresolved?(rendered),
               "#{template.name} left #{inspect(Rendered.unresolved_paths(rendered))} unresolved"
      end
    end

    test "an alert with no device still resolves, because every gap has a default" do
      # An alert with no subject device is ordinary, not exceptional. Without a
      # `default:` the body would render "Device:  ()" and
      # `Rendered.unresolved?/1` would fire on every such alert, training
      # operators to ignore the signal that catches a real typo.
      for template <- catalog() do
        rendered = render!(template, context: %{})

        refute Rendered.unresolved?(rendered),
               "#{template.name} left #{inspect(Rendered.unresolved_paths(rendered))} unresolved"

        assert String.trim(rendered.body) != ""
      end
    end

    test "an alert carrying only a title still renders" do
      bare = %{"id" => "0198f0aa-1111-7000-8000-000000000001", "title" => "Something happened"}

      for template <- catalog() do
        rendered = render!(template, snapshot: bare, context: %{})

        refute Rendered.unresolved?(rendered)
        assert String.trim(rendered.body) != ""
      end
    end

    test "the JSON default keeps the stable envelope instead of becoming the payload" do
      # `Renderers.Json` treats a body that parses as a JSON object as the payload
      # document itself. A shipped default must not replace the ServiceRadar
      # envelope with an opinion about some receiver's schema.
      json = Enum.find(catalog(), &(&1.payload_format == :json))
      rendered = render!(json)

      assert {:error, _reason} = Jason.decode(json.body_template)
      assert rendered.payload["alert_id"] == snapshot()["id"]
      assert rendered.payload["severity"] == "critical"
      assert rendered.payload["body"] == rendered.body
    end

    test "the HTML default escapes substituted values rather than emitting them as markup" do
      html = Enum.find(catalog(), &(&1.payload_format == :html))
      hostile = snapshot(%{"message" => "<img src=x onerror=alert(1)>"})
      rendered = render!(html, snapshot: hostile)

      refute String.contains?(rendered.payload["html"], "<img")
      assert String.contains?(rendered.payload["html"], "&lt;img")
      # The literal markup the template itself carries is emitted as written.
      assert String.contains?(rendered.payload["html"], "<table")
    end

    test "the Slack default uses mrkdwn bold, which is a single asterisk" do
      slack = Enum.find(catalog(), &(&1.payload_format == :slack_blocks))

      refute String.contains?(slack.body_template, "**")
      assert String.contains?(slack.body_template, "*Device:*")
    end
  end

  describe "reconciliation contract" do
    test "the managed set is exactly the resource's content fields" do
      assert Enum.sort(TemplateSeeder.managed_fields()) ==
               Enum.sort([:name, :subject_template, :body_template])
    end

    test "every managed field is one the reconcile action accepts" do
      accepted =
        NotificationTemplate
        |> Info.action(:reconcile_managed)
        |> Map.fetch!(:accept)

      for field <- TemplateSeeder.managed_fields() do
        assert field in accepted
      end

      for field <- [:managed, :template_version, :template_fingerprint] do
        assert field in accepted
      end
    end

    test "the selection key is never reconciled" do
      # Changing a template's alert class or payload format would move it to a
      # different row rather than update this one.
      for field <- [:alert_class, :payload_format, :provider_key] do
        refute field in TemplateSeeder.managed_fields()
      end
    end

    test "an edited body reads as diverged, an untouched one does not" do
      fields = TemplateSeeder.managed_fields()
      plain = Enum.find(catalog(), &(&1.payload_format == :plain))
      stamped = Map.put(plain, :template_fingerprint, SeedFingerprint.fingerprint(plain, fields))

      refute SeedFingerprint.diverged?(stamped, fields)
      assert SeedFingerprint.diverged?(%{stamped | body_template: "Paged again."}, fields)
    end
  end
end

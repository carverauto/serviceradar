defmodule ServiceRadar.Notifications.Declarative.DefinitionTest do
  @moduledoc """
  The declarative provider document format and its validator (tasks 2.1.1-2.1.4,
  2.5.1).

  The tier's claim is that an operator adds a notification destination by
  uploading a document - no code, no release, no Wasm toolchain. That claim is
  only worth making if the document is checked hard enough that an operator
  learns about a mistake when they press save rather than during the incident the
  provider was added for, so almost every test here is a REJECTION, and each one
  asserts the message an operator would read, not merely that the parse failed. A
  validator that answers "invalid" is a validator nobody can author against.

  No database and no network: the validator is pure, so the whole file runs
  `async: true`. The one exception is `from_yaml/1`, which decodes inside a
  heap-bounded process; that is still process-local and needs no fixture.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadar.Notifications.Declarative.Definition.Correlation
  alias ServiceRadar.Notifications.Declarative.Definition.Request
  alias ServiceRadar.Notifications.Renderer
  alias ServiceRadar.Notifications.Template.Syntax
  alias ServiceRadar.Notifications.Transport

  @yaml """
  schema_version: 1
  key: mattermost
  display_name: Mattermost
  description: Post alerts into a Mattermost channel via an incoming webhook.
  capabilities: [send, test]
  payload_formats: [markdown, json]
  routes: [control_plane]
  config_schema:
    type: object
    properties:
      webhook_url:
        type: string
        title: Webhook URL
        secretRef: true
        credentialKind: api_token
      username:
        type: string
        title: Override username
    required: [webhook_url]
  request:
    method: POST
    url: "{{ secrets.webhook_url }}"
    headers:
      Content-Type: application/json
    body_format: json
    body:
      text: "**{{ alert.severity | upper }}** {{ alert.title }}"
      username: "{{ config.username | default: \\"ServiceRadar\\" }}"
  success:
    status: [200, 204]
  failure:
    retryable_status: [429, "500-599"]
    retry_after_header: Retry-After
  response:
    external_correlation_id:
      from: body
      path: id
  """

  # Every rejection this format owes an operator, as data: a name, the mutations
  # that break the valid document, the path the error must be reported at, and a
  # fragment of the sentence the operator has to be able to act on.
  @rejections [
    # --- the format is closed ------------------------------------------------
    {"an unknown top-level key", [{:put, ["extras"], "anything"}], "extras",
     "the document format is closed"},
    {"an unknown key inside request", [{:put, ["request", "auth"], "bearer"}], "request.auth",
     "the document format is closed"},
    {"a missing required section", [{:delete, ["request"]}], "request", "is required"},
    {"an unrecognised schema_version", [{:put, ["schema_version"], 2}], "schema_version",
     "not a supported document version"},
    {"a non-integer schema_version", [{:put, ["schema_version"], "1"}], "schema_version",
     "must be an integer"},

    # --- the nine UI-code keys, at any depth ---------------------------------
    {"a ui_code key at the top level", [{:put, ["ui_code"], "render()"}], "ui_code",
     "never ships markup or code"},
    {"an html key nested inside config_schema",
     [{:put, ["config_schema", "properties", "html"], %{"type" => "string"}}],
     "config_schema.properties.html", "never ships markup or code"},
    {"a javascript key nested inside a header value",
     [{:put, ["request", "headers", "X-Meta"], %{"javascript" => "alert(1)"}}],
     "request.headers.X-Meta.javascript", "never ships markup or code"},
    # NOTE: there is deliberately no rejection case for a forbidden key NAME
    # inside `request.body`. Those keys belong to the destination's API, not to
    # ServiceRadar's document structure - `component` is a real PagerDuty
    # Events API v2 field and `html` is a real field in more than one chat API.
    # See the "destination payload keys" describe block below, which asserts
    # both that such keys are accepted there and that the control that actually
    # matters - code constructs in a VALUE - still applies inside the body.
    {"a LiveView key differing only in case", [{:put, ["Live_View"], "x"}], "Live_View",
     "never ships markup or code"},

    # --- EEx and other code constructs, anywhere -----------------------------
    {"an EEx tag in a body template",
     [{:put, ["request", "body", "text"], "<%= System.cmd(\"id\", []) %>"}], "request.body.text",
     "is data, never code"},
    {"an EEx tag in a field that is never rendered",
     [{:put, ["display_name"], "Mattermost <%= 1 + 1 %>"}], "display_name",
     "is data, never code"},
    {"an interpolation marker in a header value",
     [{:put, ["request", "headers", "X-Trace"], "trace-\#{secret}"}], "request.headers.X-Trace",
     "is data, never code"},

    # --- the restricted substitution grammar ---------------------------------
    {"a variable path outside the catalog",
     [{:put, ["request", "body", "text"], "{{ alert.telepathy }}"}], "request.body.text",
     "unknown variable path \"alert.telepathy\""},
    {"a config field the schema does not declare",
     [{:put, ["request", "body", "text"], "{{ config.nickname }}"}], "request.body.text",
     "unknown variable path \"config.nickname\""},
    {"a secret field addressed under config",
     [{:put, ["request", "url"], "https://example.com/{{ config.webhook_url }}"}], "request.url",
     "unknown variable path \"config.webhook_url\""},
    {"a filter outside the fixed set",
     [{:put, ["request", "body", "text"], "{{ alert.title | shout }}"}], "request.body.text",
     "unknown filter \"shout\""},
    {"an unclosed expression", [{:put, ["request", "body", "text"], "{{ alert.title"}],
     "request.body.text", "every expression must close"},

    # --- config_schema -------------------------------------------------------
    {"a config_schema that is not an object", [{:put, ["config_schema"], %{"type" => "array"}}],
     "config_schema", "must be \"object\""},
    {"a config_schema property with an unsupported key",
     [{:put, ["config_schema", "properties", "username", "nope"], true}], "config_schema",
     "unsupported keys"},
    {"a credential-named field that is not a secretRef",
     [{:put, ["config_schema", "properties", "api_token"], %{"type" => "string"}}],
     "config_schema.properties.api_token", "not marked \"secretRef: true\""},
    {"a routing key that is not a secretRef",
     [{:put, ["config_schema", "properties", "routing_key"], %{"type" => "string"}}],
     "config_schema.properties.routing_key", "non-sensitive config column"},

    # --- capabilities, formats, routes --------------------------------------
    {"capabilities without test", [{:put, ["capabilities"], ["send"]}], "capabilities",
     "must declare [:test]"},
    {"capabilities without send", [{:put, ["capabilities"], ["test"]}], "capabilities",
     "must declare [:send]"},
    {"a capability this tier cannot honour",
     [{:put, ["capabilities"], ["send", "test", "threading"]}], "capabilities",
     "wasm_plugin provider"},
    {"a duplicated payload format", [{:put, ["payload_formats"], ["json", "json"]}],
     "payload_formats", "more than once"},
    {"an unknown payload format", [{:put, ["payload_formats"], ["yaml"]}], "payload_formats",
     "is not one of"},
    {"a duplicated route", [{:put, ["routes"], ["control_plane", "control_plane"]}], "routes",
     "more than once"},
    {"the edge_agent route", [{:put, ["routes"], ["edge_agent"]}], "routes",
     "no plugin-backed edge execution path"},

    # --- request -------------------------------------------------------------
    {"a method outside the allowlist", [{:put, ["request", "method"], "GET"}], "request.method",
     "must be one of PATCH, POST, PUT"},
    {"a literal http:// url", [{:put, ["request", "url"], "http://hooks.example.com/x"}],
     "request.url", ":disallowed_scheme"},
    {"a url with no scheme at all", [{:put, ["request", "url"], "hooks.example.com/x"}],
     "request.url", "must begin with https://"},
    {"a url on a port the policy refuses",
     [{:put, ["request", "url"], "https://hooks.example.com:8443/x"}], "request.url",
     ":disallowed_port"},
    {"a json body written as a string",
     [{:put, ["request", "body"], ~s({"text": "{{ alert.title }}"})}], "request.body",
     "must be a JSON object or array"},
    {"a templated json body key",
     [{:put, ["request", "body"], %{"{{ alert.title }}" => "value"}}],
     "request.body.{{ alert.title }}", "keys must be literal"},
    {"a nested form body",
     [
       {:put, ["request", "body_format"], "form"},
       {:put, ["request", "headers"], %{"Content-Type" => "application/x-www-form-urlencoded"}},
       {:put, ["request", "body"], %{"payload" => %{"text" => "x"}}}
     ], "request.body.payload", "a form body is flat"},
    {"a text body that is not a string", [{:put, ["request", "body_format"], "text"}],
     "request.body", "must be a template string when body_format is text"},
    {"a header value with a newline", [{:put, ["request", "headers", "X-Trace"], "a\nb"}],
     "request.headers.x-trace", "a newline in a header value is injection"},
    {"a header name that is not a token", [{:put, ["request", "headers", "X Trace"], "a"}],
     "request.headers.x trace", "not a valid HTTP header name"},
    {"a literal credential in a header",
     [{:put, ["request", "headers", "Authorization"], "Bearer sk-live-abcdefghij"}],
     "request.headers.authorization", "must come from a secrets.* reference"},
    {"a content-type that contradicts body_format",
     [{:put, ["request", "headers", "Content-Type"], "text/plain"}],
     "request.headers.content-type", "request.body_format is json"},
    {"the same header under two spellings",
     [{:put, ["request", "headers", "content-type"], "application/json"}],
     "request.headers.content-type", "declared more than once"},

    # --- success / failure ---------------------------------------------------
    {"a status code that is not a number", [{:put, ["success", "status"], ["ok"]}],
     "success.status[0]", "is not a status code or a range"},
    {"a success status outside 2xx", [{:put, ["success", "status"], [200, 404]}],
     "success.status[1]", "outside 200-299"},
    {"an empty success status list", [{:put, ["success", "status"], []}], "success.status",
     "must list at least one status code"},
    {"a backwards range", [{:put, ["failure", "retryable_status"], ["599-500"]}],
     "failure.retryable_status[0]", "runs backwards"},
    {"a retryable status that covers a 2xx", [{:put, ["failure", "retryable_status"], [204]}],
     "failure.retryable_status", "retrying it would send the notification twice"},
    {"a retryable status that is also a success",
     [{:put, ["failure", "retryable_status"], [204]}], "failure.retryable_status",
     "overlaps success.status on 204"},
    {"a status covered twice", [{:put, ["failure", "retryable_status"], [503, "500-599"]}],
     "failure.retryable_status", "covers 503 more than once"},
    {"a retry_after_header that is not a header name",
     [{:put, ["failure", "retry_after_header"], "Retry After"}], "failure.retry_after_header",
     "not a valid HTTP header name"},

    # --- response ------------------------------------------------------------
    {"a body correlation with no path",
     [{:put, ["response", "external_correlation_id"], %{"from" => "body"}}],
     "response.external_correlation_id.path", "is required when from is body"},
    {"a header correlation that also names a path",
     [
       {:put, ["response", "external_correlation_id"],
        %{"from" => "header", "header" => "x-id", "path" => "id"}}
     ], "response.external_correlation_id.path", "does not apply when from is header"},
    {"a correlation source that is neither body nor header",
     [{:put, ["response", "external_correlation_id"], %{"from" => "trailer"}}],
     "response.external_correlation_id.from", "must be one of body, header"},
    {"an empty response section", [{:put, ["response"], %{}}], "response",
     "must declare external_correlation_id, or be omitted"},

    # --- identity fields -----------------------------------------------------
    {"a provider key that is not a key", [{:put, ["key"], "Mattermost!"}], "key",
     "lower-case provider key"},
    {"a blank display_name", [{:put, ["display_name"], "   "}], "display_name",
     "must not be blank"},
    {"an icon that smuggles markup", [{:put, ["icon"], "<svg/>"}], "icon", "never markup"},
    {"a timeout that is not a duration", [{:put, ["timeout_ms"], 0}], "timeout_ms",
     "positive integer number of milliseconds"}
  ]

  describe "a valid document" do
    test "parses from YAML into a struct the engine can render from" do
      assert {:ok, definition} = Definition.parse(@yaml)

      assert definition.schema_version == 1
      assert definition.key == "mattermost"
      assert definition.display_name == "Mattermost"
      assert definition.capabilities == [:send, :test]
      assert definition.payload_formats == [:markdown, :json]
      assert definition.routes == [:control_plane]

      assert %Request{
               method: :post,
               url: "{{ secrets.webhook_url }}",
               body_format: :json
             } = definition.request

      assert definition.request.headers == %{"content-type" => "application/json"}

      assert definition.request.body["text"] ==
               "**{{ alert.severity | upper }}** {{ alert.title }}"

      assert definition.success_status == [{200, 200}, {204, 204}]
      assert definition.retryable_status == [{429, 429}, {500, 599}]
      assert definition.retry_after_header == "retry-after"
      assert definition.correlation == %Correlation{from: :body, path: ["id"], header: nil}
    end

    test "parses the same document supplied as JSON" do
      assert {:ok, from_yaml} = Definition.parse(@yaml)
      json = from_yaml |> Definition.to_map() |> Jason.encode!()

      assert Definition.parse(json) == {:ok, from_yaml}
    end

    test "parses a map with atom keys, which is how the seeded catalog is written" do
      assert {:ok, from_yaml} = Definition.parse(@yaml)

      atom_keyed = %{
        schema_version: 1,
        key: "mattermost",
        display_name: "Mattermost",
        description: from_yaml.description,
        capabilities: [:send, :test],
        payload_formats: [:markdown, :json],
        routes: [:control_plane],
        config_schema: from_yaml.config_schema,
        request: %{
          method: "POST",
          url: "{{ secrets.webhook_url }}",
          headers: %{"Content-Type" => "application/json"},
          body_format: "json",
          body: from_yaml.request.body
        },
        success: %{status: [200, 204]},
        failure: %{retryable_status: [429, "500-599"], retry_after_header: "Retry-After"},
        response: %{external_correlation_id: %{from: "body", path: "id"}}
      }

      assert Definition.parse(atom_keyed) == {:ok, from_yaml}
    end

    test "round-trips through its canonical form" do
      assert {:ok, definition} = Definition.parse(@yaml)
      canonical = Definition.to_map(definition)

      assert Definition.parse(canonical) == {:ok, definition}
      assert canonical == canonical |> Jason.encode!() |> Jason.decode!()
      refute Map.has_key?(canonical, "icon")
      refute Map.has_key?(canonical, "timeout_ms")
    end

    test "validate/1 agrees with parse/1" do
      assert Definition.validate(@yaml) == :ok
    end

    test "admits a destination ServiceRadar has never shipped support for" do
      # The tier's whole claim (design D2): no compile-time allowlist, no
      # implementation module, no release. A provider key nobody has heard of
      # validates on the strength of the document alone.
      document =
        document([
          {:put, ["key"], "corporate-pager-9000"},
          {:put, ["display_name"], "Corporate Pager 9000"}
        ])

      assert {:ok, definition} = Definition.parse(document)
      assert definition.key == "corporate-pager-9000"
    end
  end

  describe "rejections" do
    for {name, mutations, path, message} <- @rejections do
      test "rejects #{name}" do
        assert_rejected(
          document(unquote(Macro.escape(mutations))),
          unquote(path),
          unquote(message)
        )
      end
    end

    test "reports every problem at once rather than one per submission" do
      document =
        document([
          {:put, ["extras"], "x"},
          {:put, ["request", "method"], "GET"},
          {:put, ["capabilities"], ["send"]}
        ])

      assert {:error, errors} = Definition.parse(document)
      paths = Enum.map(errors, & &1.path)

      assert "extras" in paths
      assert "request.method" in paths
      assert "capabilities" in paths
    end

    test "names the paths this document does declare when a template misses" do
      document = document([{:put, ["request", "body", "text"], "{{ config.nickname }}"}])

      assert {:error, [error]} = Definition.parse(document)

      assert error.message =~ "This document declares config.username, secrets.webhook_url."
    end

    test "explains that an object-valued config field cannot be substituted" do
      document =
        document([
          {:put, ["config_schema", "properties", "filters"],
           %{"type" => "object", "properties" => %{"only" => %{"type" => "string"}}}},
          {:put, ["request", "body", "text"], "{{ config.filters }}"}
        ])

      assert {:error, [error]} = Definition.parse(document)

      assert error.message =~
               "Fields declared as an object or an array cannot be substituted into a template"

      assert error.message =~ "config.filters"
    end

    test "errors are sorted by path and deduplicated" do
      document = document([{:put, ["request", "method"], "GET"}, {:put, ["key"], "NOPE"}])

      assert {:error, errors} = Definition.parse(document)
      assert Enum.map(errors, & &1.path) == ["key", "request.method"]
      assert errors == Enum.uniq(errors)
    end

    test "refuses a document that is not a mapping" do
      assert {:error, [error]} = Definition.parse(42)
      assert error.path == "document"
      assert error.message =~ "must be a mapping of keys to values"
    end

    test "refuses a YAML document whose top level is a list" do
      assert {:error, [error]} = Definition.parse("- one\n- two\n")
      assert error.message =~ "top level must be a mapping"
    end

    test "refuses unparsable YAML" do
      assert {:error, [error]} = Definition.parse("key: [unterminated\n")
      assert error.path == "document"
      assert error.message =~ "invalid YAML"
    end

    test "refuses unparsable JSON" do
      assert {:error, [error]} = Definition.from_json("{\"key\": ")
      assert error.message =~ "invalid JSON"
    end

    test "refuses a document larger than the input bound" do
      oversize = "key: " <> String.duplicate("a", 70_000)

      assert {:error, [error]} = Definition.parse(oversize)
      assert error.message =~ "is larger than"
    end

    test "refuses a document with more values than a provider document has" do
      document = document([{:put, ["request", "body", "items"], Enum.map(1..2100, &to_string/1)}])

      assert {:error, errors} = Definition.parse(document)
      assert Enum.any?(errors, &(&1.message =~ "more than 2000 values"))
    end

    test "refuses a document nested past the depth bound" do
      document = document([{:put, ["request", "body", "deep"], nest(14)}])

      assert {:error, errors} = Definition.parse(document)
      assert Enum.any?(errors, &(&1.message =~ "nested deeper than"))
    end
  end

  describe "classify_status/2" do
    setup do
      {:ok, definition} = Definition.parse(@yaml)
      %{definition: definition}
    end

    test "reads the document's own sets, not a hardcoded table", %{definition: definition} do
      assert Definition.classify_status(definition, 200) == :success
      assert Definition.classify_status(definition, 204) == :success
      assert Definition.classify_status(definition, 429) == :retryable
      assert Definition.classify_status(definition, 500) == :retryable
      assert Definition.classify_status(definition, 599) == :retryable
    end

    test "treats anything in neither set as terminal", %{definition: definition} do
      # The spec is explicit: not success and not retryable means terminal. A 403
      # is the case that matters, because burning five attempts on a rejected
      # credential only delays the operator learning about it.
      assert Definition.classify_status(definition, 403) == :permanent
      assert Definition.classify_status(definition, 201) == :permanent
      assert Definition.classify_status(definition, 302) == :permanent
      assert Definition.classify_status(definition, nil) == :permanent
    end
  end

  describe "extract_correlation_id/2" do
    test "reads a body field" do
      {:ok, definition} = Definition.parse(@yaml)

      assert Definition.extract_correlation_id(definition, %{
               status: 200,
               headers: %{},
               body: %{"id" => "abc123"}
             }) == "abc123"
    end

    test "reads a nested body field named by a dotted path" do
      {:ok, definition} =
        [
          {:put, ["response", "external_correlation_id"],
           %{"from" => "body", "path" => "data.id"}}
        ]
        |> document()
        |> Definition.parse()

      assert Definition.extract_correlation_id(definition, %{
               body: %{"data" => %{"id" => 4711}}
             }) == "4711"
    end

    test "reads a response header" do
      {:ok, definition} =
        [
          {:put, ["response", "external_correlation_id"],
           %{"from" => "header", "header" => "X-Message-Id"}}
        ]
        |> document()
        |> Definition.parse()

      assert Definition.extract_correlation_id(definition, %{
               headers: %{"x-message-id" => ["m-1"]}
             }) == "m-1"
    end

    test "answers nil when the document declares no correlation, or the field is absent" do
      {:ok, plain} = [{:delete, ["response"]}] |> document() |> Definition.parse()
      {:ok, declared} = Definition.parse(@yaml)

      assert Definition.extract_correlation_id(plain, %{body: %{"id" => "x"}}) == nil
      assert Definition.extract_correlation_id(declared, %{body: %{}}) == nil
      assert Definition.extract_correlation_id(declared, %{body: "not a map"}) == nil
      assert Definition.extract_correlation_id(declared, %{body: %{"id" => %{}}}) == nil
    end

    test "truncates what the destination writes onto the delivery row" do
      {:ok, definition} = Definition.parse(@yaml)
      hostile = String.duplicate("x", 5_000)

      extracted = Definition.extract_correlation_id(definition, %{body: %{"id" => hostile}})

      assert String.length(extracted) == 512
    end
  end

  describe "the published surface other tiers build on" do
    setup do
      {:ok, definition} = Definition.parse(@yaml)
      %{definition: definition}
    end

    test "config_paths/1 and secret_paths/1 stay disjoint", %{definition: definition} do
      assert Definition.config_paths(definition) == ["config.username"]
      assert Definition.secret_paths(definition) == ["secrets.webhook_url"]
    end

    test "templates/1 lists every template with its path", %{definition: definition} do
      assert Definition.templates(definition) == [
               {"request.url", "{{ secrets.webhook_url }}"},
               {"request.headers.content-type", "application/json"},
               {"request.body.text", "**{{ alert.severity | upper }}** {{ alert.title }}"},
               {"request.body.username", "{{ config.username | default: \"ServiceRadar\" }}"}
             ]
    end

    test "the forbidden key list is the manifest validator's nine" do
      assert Enum.sort(Definition.forbidden_keys()) ==
               Enum.sort(~w(
                 html raw_html javascript js component component_ref live_view react ui_code
               ))
    end
  end

  describe "destination payload keys inside request.body" do
    # The forbidden-key list guards ServiceRadar's own document structure so a
    # definition cannot smuggle UI. Inside `request.body` the keys are the
    # DESTINATION's API vocabulary, which ServiceRadar never interprets, so
    # refusing those names there protects nothing and makes the tier unable to
    # express real destinations. `component` is a PagerDuty Events API v2 field.
    #
    # The control that matters is unchanged and asserted below: a code
    # construct or an unknown variable path in a body VALUE is still refused.

    test "a destination field named component is accepted (PagerDuty Events API v2)" do
      document =
        document([
          {:put, ["request", "body"],
           %{"payload" => %{"component" => "db-01", "summary" => "{{ alert.title }}"}}}
        ])

      assert {:ok, _definition} = Definition.parse(document)
    end

    test "a destination field named html is accepted" do
      document = document([{:put, ["request", "body"], %{"html" => "{{ alert.title }}"}}])

      assert {:ok, _definition} = Definition.parse(document)
    end

    test "the exemption is scoped to the body and does not reach headers" do
      assert_rejected(
        document([{:put, ["request", "headers", "X-Meta"], %{"javascript" => "alert(1)"}}]),
        "request.headers.X-Meta.javascript",
        "never ships markup or code"
      )
    end

    test "a code construct in a body value is still refused" do
      assert_rejected(
        document([
          {:put, ["request", "body"], %{"summary" => "<%= File.read!(\"/etc/passwd\") %>"}}
        ]),
        "request.body.summary",
        "code"
      )
    end

    test "an unknown variable path in a body value is still refused" do
      assert_rejected(
        document([{:put, ["request", "body"], %{"summary" => "{{ alert.nope }}"}}]),
        "request.body.summary",
        "alert.nope"
      )
    end

    test "the tier declares only capabilities and routes it can honour" do
      assert Definition.allowed_capabilities() == [:send, :test, :rich_payload]
      assert Definition.allowed_routes() == [:control_plane]

      for required <- Transport.required_capabilities() do
        assert required in Definition.allowed_capabilities()
      end

      for capability <- Definition.allowed_capabilities() do
        assert capability in Transport.capabilities()
      end
    end

    test "methods and body formats are closed vocabularies" do
      assert Enum.sort(Definition.allowed_methods()) == ["PATCH", "POST", "PUT"]
      assert Enum.sort(Definition.allowed_body_formats()) == ["form", "json", "text"]
      assert Definition.supported_schema_versions() == [1]
    end

    test "describe_errors/1 renders a list into one sentence" do
      assert {:error, errors} = Definition.parse(document([{:put, ["key"], "NOPE"}]))
      assert Definition.describe_errors(errors) =~ "key must be a lower-case provider key"
    end
  end

  describe "the engine renders these templates with the one restricted engine" do
    test "config and secrets resolve through Renderer.render_string/4" do
      # This is the handoff the declarative execution engine builds on: the
      # document supplies the extra paths, the dispatcher supplies the values,
      # and `Notifications.Renderer` does the substitution. There is no second
      # templating engine to write.
      {:ok, definition} = Definition.parse(@yaml)
      extra = Definition.config_paths(definition) ++ Definition.secret_paths(definition)

      context = %{
        "alert" => %{"title" => "Disk full", "severity" => "critical"},
        "config" => %{"username" => "ServiceRadar"},
        "secrets" => %{"webhook_url" => "https://mm.example.com/hooks/abc"}
      }

      assert {:ok, url, []} =
               Renderer.render_string(definition.request.url, context, :plain, extra_paths: extra)

      assert url == "https://mm.example.com/hooks/abc"

      assert {:ok, text, []} =
               Renderer.render_string(definition.request.body["text"], context, :plain,
                 extra_paths: extra
               )

      assert text == "**CRITICAL** Disk full"
    end

    test "the renderer still refuses those paths when they are not supplied" do
      {:ok, definition} = Definition.parse(@yaml)

      assert {:error, {:invalid_template, %{message: message}}} =
               Renderer.render_string(definition.request.url, %{}, :plain)

      assert message =~ "unknown variable path \"secrets.webhook_url\""
    end
  end

  describe "the notification variable catalog is not weakened by this tier" do
    test "config.* and secrets.* are still refused for an ordinary template" do
      # `Template.Syntax.validate_template/1` is what `NotificationTemplate` and
      # the renderer use. The declarative tier passes its two extra namespaces as
      # `:extra_paths` for one call; if they had been added to the catalog or to
      # `open_namespaces/0` instead, a notification body could address a config
      # field that does not exist there and render an empty string during an
      # incident.
      assert {:error, message} = Syntax.validate_template("{{ config.username }}")
      assert message =~ "unknown variable path \"config.username\""

      assert {:error, _message} = Syntax.validate_template("{{ secrets.webhook_url }}")
    end

    test "extra_paths admits exactly what it is given and nothing adjacent" do
      opts = [extra_paths: ["config.username"]]

      assert Syntax.validate_template("{{ config.username }}", opts) == :ok
      assert {:error, _message} = Syntax.validate_template("{{ config.username.first }}", opts)
      assert {:error, _message} = Syntax.validate_template("{{ config.other }}", opts)
      assert Syntax.validate_template("{{ alert.title }}", opts) == :ok
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp assert_rejected(document, path, message) do
    assert {:error, errors} = Definition.parse(document)

    at_path = Enum.filter(errors, &(&1.path == path))

    assert at_path != [],
           "expected an error at #{inspect(path)}, got #{inspect(Enum.map(errors, & &1.path))}"

    assert Enum.any?(at_path, &String.contains?(&1.message, message)),
           "expected a message containing #{inspect(message)} at #{inspect(path)}, got " <>
             inspect(Enum.map(at_path, & &1.message))
  end

  defp document(mutations) do
    {:ok, definition} = Definition.parse(@yaml)

    definition
    |> Definition.to_map()
    |> Map.put("description", "Post alerts into a Mattermost channel via an incoming webhook.")
    |> Map.put("request", %{
      "method" => "POST",
      "url" => "{{ secrets.webhook_url }}",
      "headers" => %{"Content-Type" => "application/json"},
      "body_format" => "json",
      "body" => %{
        "text" => "**{{ alert.severity | upper }}** {{ alert.title }}",
        "username" => "{{ config.username | default: \"ServiceRadar\" }}"
      }
    })
    |> Map.put("failure", %{
      "retryable_status" => [429, "500-599"],
      "retry_after_header" => "Retry-After"
    })
    |> Map.put("response", %{"external_correlation_id" => %{"from" => "body", "path" => "id"}})
    |> apply_mutations(mutations)
  end

  defp apply_mutations(document, mutations) do
    Enum.reduce(mutations, document, fn
      {:put, path, value}, acc -> put_path(acc, path, value)
      {:delete, path}, acc -> delete_path(acc, path)
    end)
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    Map.put(map, key, put_path(Map.get(map, key, %{}), rest, value))
  end

  defp delete_path(map, [key]), do: Map.delete(map, key)

  defp delete_path(map, [key | rest]) do
    Map.put(map, key, delete_path(Map.get(map, key, %{}), rest))
  end

  defp nest(0), do: "leaf"
  defp nest(depth), do: %{"level" => nest(depth - 1)}
end

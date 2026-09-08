defmodule ServiceRadar.Notifications.Transports.DeclarativeTest do
  @moduledoc """
  Golden-request tests for the declarative execution engine (tasks 2.2.1-2.2.4,
  2.5.2).

  The tier's claim is that an operator adds a destination by uploading a
  document. What makes that claim true at run time is that this engine renders
  the document and nothing else - so the tests that matter assert the EXACT bytes
  three differently shaped documents put on the wire: method, path, headers, and
  body. A templating regression then shows up as a diff on a line an operator
  wrote, rather than as "delivery failed".

  Three shapes, because each exercises a different half of the engine:

  | Document | Shape | What only it covers |
  | --- | --- | --- |
  | `@mattermost` (YAML, as uploaded) | `POST`, `json` body, secret in the URL | a JSON document whose leaves are templates; correlation id from a body field |
  | `@opsgenie` (map, as stored in `jsonb`) | `PUT`, `form` body, credential header | a credential reaching a header and nothing else; a document-declared retryable 409; a non-standard `retry_after_header`; correlation id from a response header |
  | `@gotify` | `PATCH`, `text` body, host from config | the URL being assembled from channel configuration, which is why the outbound policy has to run after substitution |

  `async: true`, no database, no network. The destination is a function plug
  injected through `opts[:req_options]`, which is also how each test asserts what
  was actually sent - the plug forwards the request it received to the test
  process. The URLs are public IP literals so the outbound policy never needs
  DNS; see `ServiceRadar.Notifications.Transports.HTTPTest` for why.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Notifications.Declarative.Definition
  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.Declarative
  alias ServiceRadar.Notifications.Transports.Registry

  # Every non-delivered result is logged, redacted, which is most of this file.
  # The tests that assert on the log contents capture explicitly.
  @moduletag :capture_log

  @host "93.184.216.34"
  @webhook_url "https://#{@host}/hooks/9f2b1c7a4e5d6082"
  @api_url "https://#{@host}"
  @secret "gk-live-9a8b7c6d5e4f3g2h1i0j"

  @mattermost """
  schema_version: 1
  key: mattermost
  display_name: Mattermost
  capabilities: [send, test]
  payload_formats: [markdown, json]
  config_schema:
    type: object
    properties:
      webhook_url:
        type: string
        secretRef: true
        credentialKind: api_token
      username:
        type: string
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
      props:
        card: "{{ alert.message | truncate: 20 }}"
        muted: false
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

  @opsgenie %{
    "schema_version" => 1,
    "key" => "opsgenie",
    "display_name" => "Opsgenie",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["json"],
    "config_schema" => %{
      "type" => "object",
      "properties" => %{
        "api_url" => %{"type" => "string"},
        "responder" => %{"type" => "string"},
        "api_token" => %{"type" => "string", "secretRef" => true}
      },
      "required" => ["api_url", "api_token"]
    },
    "request" => %{
      "method" => "PUT",
      "url" => "{{ config.api_url }}/v2/alerts",
      "headers" => %{
        "Authorization" => "GenieKey {{ secrets.api_token }}",
        "X-Responder" => "{{ config.responder | default: \"oncall\" }}"
      },
      "body_format" => "form",
      "body" => %{
        "message" => "{{ alert.title }}",
        "priority" => "{{ alert.severity | upper }}",
        "retries" => 3
      }
    },
    "success" => %{"status" => [200, 202]},
    "failure" => %{
      "retryable_status" => [409, "500-599"],
      "retry_after_header" => "X-Retry-After"
    },
    "response" => %{
      "external_correlation_id" => %{"from" => "header", "header" => "X-Request-Id"}
    }
  }

  @gotify %{
    "schema_version" => 1,
    "key" => "gotify",
    "display_name" => "Gotify",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["plain"],
    "config_schema" => %{
      "type" => "object",
      "properties" => %{
        "host" => %{"type" => "string"},
        "topic" => %{"type" => "string"}
      },
      "required" => ["host", "topic"]
    },
    "request" => %{
      "method" => "PATCH",
      "url" => "https://{{ config.host }}/topic/{{ config.topic | url_encode }}",
      "headers" => %{"X-Title" => "{{ alert.title }}"},
      "body_format" => "text",
      "body" => "{{ alert.severity | upper }}: {{ alert.message }}"
    },
    "success" => %{"status" => [204]},
    "failure" => %{"retryable_status" => [503]}
  }

  @alert %{
    "id" => "44444444-4444-4444-4444-444444444444",
    "title" => "Disk 92% on db-01",
    "message" => "threshold breached on the primary volume",
    "severity" => "critical"
  }

  @context %{"alert" => @alert}

  describe "contract" do
    test "conforms to the Transport behaviour, so the tier is invisible downstream" do
      assert Registry.conformance(Declarative) == :ok

      # And is deliberately NOT on the native allowlist: `implementation_module`
      # is NULL for a declarative provider, and the dispatcher reaches this
      # module through `provider_type` instead. An entry here would be a second,
      # contradictory way to select the tier.
      refute Registry.allowed?("ServiceRadar.Notifications.Transports.Declarative")
    end

    test "declares both required capabilities, and only what a template engine can honour" do
      assert :send in Declarative.capabilities()
      assert :test in Declarative.capabilities()
      assert Declarative.capabilities() == Definition.allowed_capabilities()
    end
  end

  describe "golden request: a JSON document (Mattermost shape)" do
    test "renders every leaf and POSTs the document the operator drew" do
      result =
        deliver(mattermost(),
          secrets: %{"webhook_url" => @webhook_url},
          config: %{"username" => "ServiceRadar Bot"},
          plug: json_plug(200, %{"id" => "post-42"})
        )

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == "post-42"
      assert result.result_summary == %{"http_status" => 200}
      assert Result.outcome(result, true) == :sent

      assert_received {:sent, sent}
      assert sent.method == "POST"
      assert sent.path == "/hooks/9f2b1c7a4e5d6082"
      assert header(sent, "content-type") =~ "application/json"

      assert Jason.decode!(sent.body) == %{
               "text" => "**CRITICAL** Disk 92% on db-01",
               "username" => "ServiceRadar Bot",
               "props" => %{"card" => "threshold breache...", "muted" => false}
             }
    end

    test "a default: filter supplies the leaf the channel left unset" do
      deliver(mattermost(),
        secrets: %{"webhook_url" => @webhook_url},
        plug: json_plug(200, %{})
      )

      assert_received {:sent, sent}
      assert Jason.decode!(sent.body)["username"] == "ServiceRadar"
    end

    test "the same document read back from jsonb renders identically" do
      # `to_map/1` is what `NotificationProvider.definition` stores, so this is
      # the round trip every delivery after the first one actually takes.
      stored = Definition.to_map(mattermost())

      deliver(stored, secrets: %{"webhook_url" => @webhook_url}, plug: json_plug(200, %{}))

      assert_received {:sent, sent}

      assert Jason.decode!(sent.body)["text"] == "**CRITICAL** Disk 92% on db-01"
    end

    test "the definition may also arrive on the request, for a caller that has only that" do
      request =
        request(
          secrets: %{"webhook_url" => @webhook_url},
          metadata: %{
            "definition" => Definition.to_map(mattermost()),
            "template_context" => @context
          }
        )

      assert %Result{disposition: :delivered} =
               Declarative.deliver(request, req_options: [plug: json_plug(200, %{})])

      assert_received {:sent, sent}
      assert Jason.decode!(sent.body)["text"] == "**CRITICAL** Disk 92% on db-01"
    end
  end

  describe "golden request: a form document with a credential header (Opsgenie shape)" do
    test "PUTs the form body and writes the resolved secret to the declared header" do
      result =
        deliver(@opsgenie,
          config: %{"api_url" => @api_url, "responder" => "network-team"},
          secrets: %{"api_token" => @secret},
          plug: form_plug(202, [{"x-request-id", "req-7"}])
        )

      assert %Result{disposition: :delivered} = result
      assert result.external_correlation_id == "req-7"

      assert_received {:sent, sent}
      assert sent.method == "PUT"
      assert sent.path == "/v2/alerts"
      assert header(sent, "authorization") == "GenieKey " <> @secret
      assert header(sent, "x-responder") == "network-team"
      assert header(sent, "content-type") =~ "application/x-www-form-urlencoded"

      assert URI.decode_query(sent.body) == %{
               "message" => "Disk 92% on db-01",
               "priority" => "CRITICAL",
               "retries" => "3"
             }
    end

    test "the credential is nowhere except the header it was declared in" do
      deliver(@opsgenie,
        config: %{"api_url" => @api_url},
        secrets: %{"api_token" => @secret},
        plug: form_plug(202)
      )

      assert_received {:sent, sent}
      refute sent.body =~ @secret
      refute sent.path =~ @secret
      assert header(sent, "x-responder") == "oncall"
    end
  end

  describe "golden request: a text document whose URL comes from config (Gotify shape)" do
    test "PATCHes the rendered path with the substituted, url-encoded segment" do
      result =
        deliver(@gotify,
          config: %{"host" => @host, "topic" => "ops alerts"},
          plug: text_plug(204)
        )

      assert %Result{disposition: :delivered} = result

      assert_received {:sent, sent}
      assert sent.method == "PATCH"
      assert sent.path == "/topic/ops+alerts"
      assert header(sent, "x-title") == "Disk 92% on db-01"
      assert sent.body == "CRITICAL: threshold breached on the primary volume"
    end
  end

  describe "the document decides what the answer means" do
    test "a 200 the document does not list as success is NOT a delivery" do
      # Some destinations answer 200 with an error body. Recording that as
      # `:sent` is precisely the silent failure this platform exists to prevent.
      result = deliver(@gotify, config: gotify_config(), plug: text_plug(200))

      assert %Result{disposition: :permanent_failure, error_class: "http_200"} = result
      assert result.error_message =~ "does not list in success.status"
      assert Result.outcome(result, true) == :failed
    end

    test "a status the document calls retryable is retryable even though 4xx normally is not" do
      # The built-in classifier calls 409 permanent. The document overrules it,
      # which is the whole point of `failure.retryable_status`.
      result =
        deliver(@opsgenie,
          config: opsgenie_config(),
          secrets: %{"api_token" => @secret},
          plug: form_plug(409)
        )

      assert %Result{disposition: :retryable_failure, error_class: "http_409"} = result
      assert Result.outcome(result, true) == :retry
      assert Result.outcome(result, false) == :failed
    end

    test "a status in neither set is terminal" do
      result =
        deliver(@opsgenie,
          config: opsgenie_config(),
          secrets: %{"api_token" => @secret},
          plug: form_plug(403)
        )

      assert %Result{disposition: :permanent_failure, error_class: "http_403"} = result
      assert Result.outcome(result, true) == :failed
    end

    test "a 5xx range entry covers every code inside it" do
      result =
        deliver(mattermost(), secrets: mattermost_secrets(), plug: json_plug(503, %{"e" => 1}))

      assert %Result{disposition: :retryable_failure, error_class: "http_503"} = result
      assert result.error_message =~ "HTTP 503"
    end

    test "the retry hint is read from the header the document names" do
      result =
        deliver(@opsgenie,
          config: opsgenie_config(),
          secrets: %{"api_token" => @secret},
          plug: form_plug(409, [{"x-retry-after", "12"}])
        )

      assert result.retry_after_ms == 12_000
    end

    test "a Retry-After the document does not name is ignored rather than guessed" do
      result =
        deliver(@opsgenie,
          config: opsgenie_config(),
          secrets: %{"api_token" => @secret},
          plug: form_plug(409, [{"retry-after", "12"}])
        )

      assert result.retry_after_ms == nil
    end

    test "a far-future hint is clamped rather than trusted" do
      result =
        deliver(mattermost(),
          secrets: mattermost_secrets(),
          plug: json_plug(429, %{}, [{"retry-after", "99999"}])
        )

      assert result.retry_after_ms == 3_600_000
    end

    test "the correlation id is only read from an answer the document calls success" do
      result =
        deliver(mattermost(),
          secrets: mattermost_secrets(),
          plug: json_plug(500, %{"id" => "post-42"})
        )

      assert result.external_correlation_id == nil
    end
  end

  describe "an unresolved variable" do
    test "in config refuses the delivery and sends nothing" do
      result =
        deliver(@opsgenie,
          config: %{},
          secrets: %{"api_token" => @secret},
          plug: form_plug(202)
        )

      assert %Result{disposition: :permanent_failure, error_class: "invalid_config"} = result
      assert result.error_message =~ "config.api_url"
      assert result.error_message =~ "which this channel does not supply"
      refute_received {:sent, _sent}
    end

    test "in secrets names the channel column an operator has to edit" do
      result = deliver(@opsgenie, config: opsgenie_config(), plug: form_plug(202))

      assert %Result{disposition: :permanent_failure, error_class: "invalid_config"} = result
      assert result.error_message =~ "secret_refs.api_token"
      assert result.result_summary == %{"config_errors" => ["secret_refs.api_token"]}
      refute_received {:sent, _sent}
    end

    test "in the url refuses the delivery, because a URL with a hole is a different URL" do
      definition = put_in(@opsgenie, ["request", "url"], "{{ config.api_url }}/v2/{{ alert.id }}")

      result =
        deliver(definition,
          config: opsgenie_config(),
          secrets: %{"api_token" => @secret},
          context: %{"alert" => Map.delete(@alert, "id")},
          plug: form_plug(202)
        )

      assert %Result{disposition: :permanent_failure, error_class: "invalid_url"} = result
      assert result.error_message =~ "alert.id"
      refute_received {:sent, _sent}
    end

    test "in a body still sends: an alert may genuinely not carry a device" do
      result =
        deliver(mattermost(),
          secrets: mattermost_secrets(),
          context: %{"alert" => Map.delete(@alert, "message")},
          plug: json_plug(200, %{})
        )

      assert %Result{disposition: :delivered} = result
      assert result.result_summary["unresolved"] == ["alert.message"]

      assert_received {:sent, sent}
      assert Jason.decode!(sent.body)["props"]["card"] == ""
    end
  end

  describe "the outbound URL policy runs on the rendered URL" do
    test "a config value that resolves to a private address is refused, and nothing is sent" do
      for host <- ["localhost", "127.0.0.1", "10.1.2.3", "169.254.169.254"] do
        result =
          deliver(@gotify,
            config: %{"host" => host, "topic" => "ops"},
            plug: text_plug(204)
          )

        assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
        assert result.error_message =~ "policy"
      end

      refute_received {:sent, _sent}
    end

    test "a template that looked public does not bypass the check" do
      result =
        deliver(@opsgenie,
          config: %{"api_url" => "http://#{@host}"},
          secrets: %{"api_token" => @secret},
          plug: form_plug(202)
        )

      assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      refute_received {:sent, _sent}
    end

    test "a substituted value that is not URL-safe is a configuration defect, not a timeout" do
      definition =
        put_in(@opsgenie, ["request", "url"], "{{ config.api_url }}/v2/{{ alert.title }}")

      result =
        deliver(definition,
          config: opsgenie_config(),
          secrets: %{"api_token" => @secret},
          plug: form_plug(202)
        )

      assert %Result{disposition: :permanent_failure, error_class: "invalid_url"} = result
      assert result.error_message =~ "url_encode"
      refute_received {:sent, _sent}
    end
  end

  describe "transport-level failures are classified once, in Transports.HTTP" do
    test "a timeout is retryable" do
      result =
        deliver(mattermost(), secrets: mattermost_secrets(), adapter: failing(:timeout))

      assert %Result{disposition: :retryable_failure, error_class: "timeout"} = result
    end

    test "a destination that raises becomes a result, never an exception out of deliver/2" do
      result =
        deliver(mattermost(),
          secrets: mattermost_secrets(),
          plug: fn _conn -> raise "destination exploded" end
        )

      assert %Result{disposition: :retryable_failure, error_class: "unknown"} = result
    end

    test "anything that is not a Request is a permanent failure rather than a crash" do
      assert %Result{disposition: :permanent_failure, error_class: "invalid_request"} =
               Declarative.deliver(%{not: :a_request}, [])
    end
  end

  describe "the definition itself" do
    test "a missing one is refused with a sentence that says what is missing" do
      assert %Result{disposition: :permanent_failure, error_class: "missing_definition"} =
               Declarative.deliver(request(secrets: mattermost_secrets()), [])
    end

    test "a stored document that no longer validates cannot deliver" do
      broken = Map.put(@gotify, "ui_code", "render()")

      result = deliver(broken, config: gotify_config(), plug: text_plug(204))

      assert %Result{disposition: :permanent_failure, error_class: "invalid_definition"} = result
      assert result.error_message =~ "never ships markup or code"
      refute_received {:sent, _sent}
    end
  end

  describe "secrets never leak" do
    test "not into the result, and not into the log line" do
      plug = json_plug(400, %{"message" => "rejected credential #{@secret}"})

      log =
        capture_log(fn ->
          result =
            deliver(@opsgenie,
              config: opsgenie_config(),
              secrets: %{"api_token" => @secret},
              plug: plug
            )

          refute inspect(result) =~ @secret
          assert result.error_message =~ "[REDACTED]"
        end)

      refute log =~ @secret
    end

    test "not into a transport error message, where the URL itself carries the credential" do
      result =
        deliver(mattermost(), secrets: mattermost_secrets(), adapter: failing(:econnrefused))

      assert %Result{disposition: :retryable_failure} = result
      refute inspect(result) =~ @webhook_url
    end
  end

  describe "a substituted value cannot inject a header" do
    test "line breaks in an alert title are collapsed rather than sent" do
      deliver(@gotify,
        config: gotify_config(),
        context: %{"alert" => Map.put(@alert, "title", "Disk full\r\nX-Evil: 1")},
        plug: text_plug(204)
      )

      assert_received {:sent, sent}
      assert header(sent, "x-title") == "Disk full X-Evil: 1"
      assert header(sent, "x-evil") == nil
    end
  end

  describe "test/2" do
    test "takes the same path as deliver/2, so a passing test is evidence the channel works" do
      request = request(secrets: mattermost_secrets(), is_test: true)

      result =
        Declarative.test(request,
          definition: mattermost(),
          context: @context,
          req_options: [plug: json_plug(200, %{"id" => "post-1"})]
        )

      assert %Result{disposition: :delivered, external_correlation_id: "post-1"} = result

      assert_received {:sent, sent}
      assert Jason.decode!(sent.body)["text"] == "**CRITICAL** Disk 92% on db-01"
    end

    test "exercises the real credential, so a missing one fails the test send" do
      result =
        Declarative.test(request(secrets: %{}),
          definition: mattermost(),
          context: @context,
          req_options: [plug: json_plug(200, %{})]
        )

      assert %Result{disposition: :permanent_failure, error_class: "invalid_config"} = result
      refute_received {:sent, _sent}
    end
  end

  describe "render_request/2" do
    test "renders without issuing anything, which is what the upload UI previews" do
      context = Map.merge(@context, %{"config" => gotify_config(), "secrets" => %{}})

      assert {:ok, rendered} = Declarative.render_request(parse(@gotify), context)

      assert rendered.method == :patch
      assert rendered.url == "https://#{@host}/topic/ops+alerts"
      assert rendered.headers == %{"x-title" => "Disk 92% on db-01"}
      assert rendered.body == "CRITICAL: threshold breached on the primary volume"
      assert rendered.unresolved == []
      refute_received {:sent, _sent}
    end

    test "reports every gap a preview has to show the operator, not only the first" do
      context = %{"alert" => @alert, "config" => %{}, "secrets" => %{}}

      assert {:error, errors} = Declarative.render_request(parse(@gotify), context)
      assert Enum.map(errors, & &1.field) == ["config.host", "config.topic"]

      assert Enum.at(errors, 0).message =~ "request.url substitutes {{ config.host }}"
    end
  end

  describe "validate_config/2" do
    test "accepts a configuration the document's schema declares" do
      assert :ok = Declarative.validate_config(gotify_config(), definition: parse(@gotify))
    end

    test "rejects a configuration missing a field the document requires" do
      assert {:error, [%{field: "config", message: message}]} =
               Declarative.validate_config(%{"host" => @host}, definition: parse(@gotify))

      assert message =~ "topic"
    end

    test "does not demand the secret fields, which live on secret_refs and not on config" do
      # `api_token` is `required` in the document and is a `secretRef`, so a
      # correctly configured channel does NOT carry it in `config`. Requiring it
      # here would reject every one of them.
      assert :ok = Declarative.validate_config(opsgenie_config(), definition: @opsgenie)
    end

    test "rejects a configuration that is not a map" do
      assert {:error, [%{field: nil}]} =
               Declarative.validate_config("https://example.com", definition: parse(@gotify))
    end

    test "the behaviour callback reports the missing definition rather than passing silently" do
      assert {:error, [%{field: nil, message: message}]} =
               Declarative.validate_config(gotify_config())

      assert message =~ "validate_config/2"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp mattermost, do: parse(@mattermost)

  defp parse(document) do
    {:ok, definition} = Definition.parse(document)
    definition
  end

  defp mattermost_secrets, do: %{"webhook_url" => @webhook_url}

  defp opsgenie_config, do: %{"api_url" => @api_url}

  defp gotify_config, do: %{"host" => @host, "topic" => "ops alerts"}

  defp deliver(definition, opts) do
    opts
    |> request()
    |> Declarative.deliver(
      definition: definition,
      context: Keyword.get(opts, :context, @context),
      req_options: Enum.filter(opts, fn {key, _value} -> key in [:plug, :adapter] end)
    )
  end

  defp request(opts) do
    struct!(
      %Request{
        delivery_id: "11111111-1111-1111-1111-111111111111",
        alert_id: "44444444-4444-4444-4444-444444444444",
        channel_id: "22222222-2222-2222-2222-222222222222",
        provider_key: "declarative-under-test",
        payload_format: :json,
        payload: %{"subject" => "Disk 92% on db-01"},
        config: Keyword.get(opts, :config, %{}),
        secrets: Keyword.get(opts, :secrets, %{})
      },
      Keyword.take(opts, [:metadata, :is_test])
    )
  end

  defp json_plug(status, body, resp_headers \\ []) do
    respond(status, resp_headers, Jason.encode!(body), "application/json")
  end

  defp form_plug(status, resp_headers \\ []) do
    respond(status, resp_headers, "{}", "application/json")
  end

  defp text_plug(status, resp_headers \\ []) do
    respond(status, resp_headers, "", "text/plain")
  end

  defp respond(status, resp_headers, body, content_type) do
    test_pid = self()

    fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:sent,
         %{
           method: conn.method,
           path: conn.request_path,
           query: conn.query_string,
           headers: conn.req_headers,
           body: request_body
         }}
      )

      resp_headers
      |> Enum.reduce(conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.resp(status, body)
    end
  end

  defp failing(reason) do
    fn request -> {request, %Req.TransportError{reason: reason}} end
  end

  defp header(sent, name) do
    Enum.find_value(sent.headers, fn {key, value} -> if key == name, do: value end)
  end
end

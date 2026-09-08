defmodule ServiceRadar.Notifications.Transports.GenericWebhookTest do
  @moduledoc """
  The replacement for `ServiceRadar.Monitoring.WebhookNotifier`.

  `async: true`, no database, no network. The destination is a function plug
  injected through `opts[:req_options]`, which is also how the tests assert what
  was actually sent - the request the plug receives is forwarded to the test
  process.

  The URL is a public IP literal so the outbound policy never needs DNS; see
  `ServiceRadar.Notifications.Transports.HTTPTest` for why.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Notifications.Transport.Request
  alias ServiceRadar.Notifications.Transport.Result
  alias ServiceRadar.Notifications.Transports.GenericWebhook
  alias ServiceRadar.Notifications.Transports.HTTP
  alias ServiceRadar.Notifications.Transports.Registry

  # This transport logs a redacted warning on every non-delivered result, which
  # is most of this file. Capturing keeps the suite output readable; the tests
  # that assert on the log contents capture explicitly.
  @moduletag :capture_log

  @url "https://93.184.216.34/hooks/9f2b1c7a4e5d6082"
  @secret "wh-live-9a8b7c6d5e4f3g2h1i0j"
  @payload %{
    "subject" => "Disk 92% on db-01",
    "body" => "threshold breached",
    "severity" => "warning"
  }

  describe "contract" do
    test "conforms to the Transport behaviour and is on the registry allowlist" do
      assert Registry.conforms?(GenericWebhook)
      assert Registry.allowed?("ServiceRadar.Notifications.Transports.GenericWebhook")
    end

    test "declares both required capabilities" do
      assert :send in GenericWebhook.capabilities()
      assert :test in GenericWebhook.capabilities()
    end
  end

  describe "deliver/2 happy path" do
    test "POSTs the rendered payload as JSON and reports delivered" do
      result = deliver(%{"url" => @url}, plug: json_plug(200, %{"ok" => true}))

      assert %Result{disposition: :delivered} = result
      assert result.result_summary["http_status"] == 200
      assert Result.outcome(result, true) == :sent

      assert_received {:webhook_request, request}
      assert request.method == "POST"
      assert Jason.decode!(request.body) == @payload
    end

    test "honours a configured method" do
      deliver(%{"url" => @url, "method" => "PUT"}, plug: json_plug(200, %{}))

      assert_received {:webhook_request, request}
      assert request.method == "PUT"
    end

    test "sends operator headers" do
      deliver(%{"url" => @url, "headers" => %{"X-Source" => "serviceradar"}},
        plug: json_plug(200, %{})
      )

      assert_received {:webhook_request, request}
      assert header(request, "x-source") == "serviceradar"
    end

    test "test/2 takes the same path as deliver/2, so a passing test is evidence" do
      request = request(%{"url" => @url}, is_test: true)
      result = GenericWebhook.test(request, req_options: [plug: json_plug(200, %{})])

      assert %Result{disposition: :delivered} = result
      assert_received {:webhook_request, sent}
      assert Jason.decode!(sent.body) == @payload
    end
  end

  describe "deliver/2 authentication" do
    test "bearer mode sends the resolved token and never puts it in the config column" do
      deliver(%{"url" => @url, "auth_mode" => "bearer"},
        plug: json_plug(200, %{}),
        secrets: %{"token" => @secret}
      )

      assert_received {:webhook_request, request}
      assert header(request, "authorization") == "Bearer " <> @secret
    end

    test "basic mode sends username from config and password from secrets" do
      config = %{"url" => @url, "auth_mode" => "basic", "username" => "svc-notify"}
      deliver(config, plug: json_plug(200, %{}), secrets: %{"password" => @secret})

      assert_received {:webhook_request, request}

      assert header(request, "authorization") ==
               "Basic " <> Base.encode64("svc-notify:" <> @secret)
    end

    test "header mode writes the token to the configured header" do
      config = %{"url" => @url, "auth_mode" => "header", "auth_header_name" => "X-API-Key"}
      deliver(config, plug: json_plug(200, %{}), secrets: %{"token" => @secret})

      assert_received {:webhook_request, request}
      assert header(request, "x-api-key") == @secret
    end

    test "an unresolved secret fails permanently and sends nothing" do
      result = deliver(%{"url" => @url, "auth_mode" => "bearer"}, plug: json_plug(200, %{}))

      assert %Result{disposition: :permanent_failure, error_class: "invalid_config"} = result
      assert result.error_message =~ "secret_refs.token"
      refute_received {:webhook_request, _request}
    end
  end

  describe "deliver/2 external_correlation_id" do
    test "is taken from a JSON id in a 2xx body" do
      result = deliver(%{"url" => @url}, plug: json_plug(201, %{"id" => "msg-42"}))

      assert result.external_correlation_id == "msg-42"
    end

    test "falls back to a request-id response header" do
      plug = json_plug(200, %{"ok" => true}, [{"x-request-id", "req-abc"}])
      result = deliver(%{"url" => @url}, plug: plug)

      assert result.external_correlation_id == "req-abc"
    end

    test "is nil when the receiver returns no handle, which is normal for a webhook" do
      result = deliver(%{"url" => @url}, plug: json_plug(204, %{}))

      assert %Result{disposition: :delivered, external_correlation_id: nil} = result
    end

    test "is not taken from a non-2xx body" do
      result = deliver(%{"url" => @url}, plug: json_plug(500, %{"id" => "msg-42"}))

      assert result.external_correlation_id == nil
    end
  end

  describe "deliver/2 failure classification" do
    test "5xx is retryable, so the delivery stays pending while attempts remain" do
      result = deliver(%{"url" => @url}, plug: json_plug(503, %{"error" => "unavailable"}))

      assert %Result{disposition: :retryable_failure, error_class: "http_503"} = result
      assert Result.outcome(result, true) == :retry
      assert Result.outcome(result, false) == :failed
    end

    test "429 is retryable and carries the Retry-After hint" do
      plug = json_plug(429, %{}, [{"retry-after", "12"}])
      result = deliver(%{"url" => @url}, plug: plug)

      assert %Result{disposition: :retryable_failure, error_class: "http_429"} = result
      assert result.retry_after_ms == 12_000
    end

    test "400 is permanent, so a payload that will never be accepted stops costing attempts" do
      result = deliver(%{"url" => @url}, plug: json_plug(400, %{"error" => "unknown field"}))

      assert %Result{disposition: :permanent_failure, error_class: "http_400"} = result
      assert Result.outcome(result, true) == :failed
    end

    test "a timeout is retryable" do
      result = deliver(%{"url" => @url}, adapter: failing(:timeout))

      assert %Result{disposition: :retryable_failure, error_class: "timeout"} = result
    end

    test "a refused connection is retryable" do
      result = deliver(%{"url" => @url}, adapter: failing(:econnrefused))

      assert %Result{disposition: :retryable_failure, error_class: "econnrefused"} = result
    end

    test "a raising destination becomes a result, never an exception out of deliver/2" do
      plug = fn _conn -> raise "destination exploded" end
      result = deliver(%{"url" => @url}, plug: plug)

      assert %Result{disposition: :retryable_failure, error_class: "unknown"} = result
    end

    test "anything that is not a Request is a permanent failure rather than a crash" do
      assert %Result{disposition: :permanent_failure, error_class: "invalid_request"} =
               GenericWebhook.deliver(%{not: :a_request}, [])
    end
  end

  describe "deliver/2 SSRF guard" do
    test "refuses http://, localhost, and private addresses without sending anything" do
      for url <- [
            "http://93.184.216.34/hook",
            "https://localhost/hook",
            "https://127.0.0.1/hook",
            "https://10.1.2.3/hook",
            "https://169.254.169.254/latest/meta-data/"
          ] do
        result = deliver(%{"url" => url}, plug: json_plug(200, %{}))

        assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
        assert result.error_message =~ "policy"
      end

      refute_received {:webhook_request, _request}
    end

    test "a missing url is refused before any request" do
      result = deliver(%{}, plug: json_plug(200, %{}))

      assert %Result{disposition: :permanent_failure, error_class: "blocked_url"} = result
      refute_received {:webhook_request, _request}
    end

    test "an unresolvable host is retryable, so a DNS blip does not discard a page" do
      assert %Result{disposition: :retryable_failure, error_class: "dns_resolution_failed"} =
               HTTP.to_result({:error, {:blocked_url, :dns_resolution_failed}})
    end
  end

  describe "validate_config/1" do
    test "accepts a minimal configuration" do
      assert :ok = GenericWebhook.validate_config(%{"url" => @url})
    end

    test "requires a url" do
      assert {:error, errors} = GenericWebhook.validate_config(%{})
      assert %{field: "url", message: "is required"} in errors
    end

    test "rejects http, private hosts, and non-443 ports at save time" do
      assert {:error, [%{field: "url", message: message}]} =
               GenericWebhook.validate_config(%{"url" => "http://93.184.216.34/hook"})

      assert message =~ "https"

      assert {:error, [%{field: "url"}]} =
               GenericWebhook.validate_config(%{"url" => "https://10.0.0.5/hook"})

      assert {:error, [%{field: "url"}]} =
               GenericWebhook.validate_config(%{"url" => "https://93.184.216.34:9443/x"})
    end

    test "rejects an unsupported method" do
      assert {:error, errors} =
               GenericWebhook.validate_config(%{"url" => @url, "method" => "DELETE"})

      assert Enum.any?(errors, &(&1.field == "method"))
    end

    test "rejects a credential-bearing header, because config is not a sensitive column" do
      assert {:error, errors} =
               GenericWebhook.validate_config(%{
                 "url" => @url,
                 "headers" => %{"Authorization" => "Bearer abc"}
               })

      assert [%{field: "headers.authorization", message: message}] = errors
      assert message =~ "auth_mode"
    end

    test "rejects a header value that could inject a second header" do
      assert {:error, [%{field: "headers.x-source"}]} =
               GenericWebhook.validate_config(%{
                 "url" => @url,
                 "headers" => %{"X-Source" => "a\r\nX-Evil: b"}
               })
    end

    test "rejects an unknown auth mode" do
      assert {:error, [%{field: "auth_mode"}]} =
               GenericWebhook.validate_config(%{"url" => @url, "auth_mode" => "oauth2"})
    end

    test "header auth mode requires a valid header name" do
      assert {:error, [%{field: "auth_header_name"}]} =
               GenericWebhook.validate_config(%{"url" => @url, "auth_mode" => "header"})

      assert {:error, [%{field: "auth_header_name"}]} =
               GenericWebhook.validate_config(%{
                 "url" => @url,
                 "auth_mode" => "header",
                 "auth_header_name" => "bad name"
               })
    end

    test "basic auth mode requires a username" do
      assert {:error, [%{field: "username"}]} =
               GenericWebhook.validate_config(%{"url" => @url, "auth_mode" => "basic"})
    end

    test "rejects a non-positive timeout" do
      assert {:error, [%{field: "timeout_ms"}]} =
               GenericWebhook.validate_config(%{"url" => @url, "timeout_ms" => 0})
    end

    test "rejects a configuration that is not a map" do
      assert {:error, [%{field: nil}]} = GenericWebhook.validate_config("https://example.com")
    end

    test "accepts atom keys, so a hand-built config is not silently treated as empty" do
      assert :ok = GenericWebhook.validate_config(%{"url" => @url})

      assert %Result{disposition: :delivered} =
               deliver_with_config(%{url: @url, auth_mode: :none}, plug: json_plug(200, %{}))
    end
  end

  describe "secrets never leak" do
    test "not into the result, and not into the log line" do
      plug = json_plug(400, %{"error" => "rejected token #{@secret}"})

      log =
        capture_log(fn ->
          result =
            deliver(%{"url" => @url, "auth_mode" => "bearer"},
              plug: plug,
              secrets: %{"token" => @secret}
            )

          refute inspect(result) =~ @secret
          assert result.error_message =~ "[REDACTED]"
        end)

      refute log =~ @secret
    end

    test "not into a transport error message" do
      result =
        deliver(%{"url" => @url, "auth_mode" => "bearer"},
          adapter: failing(:timeout),
          secrets: %{"token" => @secret}
        )

      refute inspect(result) =~ @secret
    end
  end

  # --- helpers --------------------------------------------------------------

  defp deliver(config, opts) do
    config
    |> request(secrets: Keyword.get(opts, :secrets, %{}))
    |> GenericWebhook.deliver(req_options: req_options(opts))
  end

  defp deliver_with_config(config, opts) do
    GenericWebhook.deliver(
      %Request{
        delivery_id: "11111111-1111-1111-1111-111111111111",
        channel_id: "22222222-2222-2222-2222-222222222222",
        payload_format: :json,
        payload: @payload,
        config: config
      },
      req_options: req_options(opts)
    )
  end

  defp req_options(opts) do
    Enum.filter(opts, fn {key, _value} -> key in [:plug, :adapter] end)
  end

  defp request(config, overrides) do
    struct!(
      %Request{
        delivery_id: "11111111-1111-1111-1111-111111111111",
        alert_id: "33333333-3333-3333-3333-333333333333",
        channel_id: "22222222-2222-2222-2222-222222222222",
        provider_key: "webhook",
        payload_format: :json,
        payload: @payload,
        config: config
      },
      overrides
    )
  end

  defp json_plug(status, body, resp_headers \\ []) do
    test_pid = self()
    encoded = Jason.encode!(body)

    fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:webhook_request, %{method: conn.method, headers: conn.req_headers, body: request_body}}
      )

      resp_headers
      |> Enum.reduce(conn, fn {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
      end)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, encoded)
    end
  end

  defp failing(reason) do
    fn request -> {request, %Req.TransportError{reason: reason}} end
  end

  defp header(request, name) do
    Enum.find_value(request.headers, fn {key, value} -> if key == name, do: value end)
  end
end

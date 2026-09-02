defmodule ServiceRadar.Plugins.ManifestNotificationsTest do
  @moduledoc """
  The `notifications:` manifest block (design D2, tasks 3.1.1, 3.1.1a).

  These are the assertions that keep the manifest block a CONTRACT rather than a
  suggestion: the key set is closed, the two near-miss spellings that were
  rejected during design stay rejected, and a notifier cannot ship without the
  capability that makes it runnable.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Plugins.Manifest

  @notifier_entry %{
    "key" => "pagerduty",
    "display_name" => "PagerDuty Events v2",
    "description" => "Routes alerts to a PagerDuty Events v2 integration key",
    "entrypoint" => "notify_pagerduty",
    "capabilities" => ["send", "test", "resolve_update"],
    "payload_formats" => ["pagerduty_v2", "json"],
    "routes" => ["control_plane", "edge_agent"]
  }

  @base_manifest %{
    "id" => "acme-notifier",
    "name" => "Acme Notifier",
    "version" => "1.0.0",
    "entrypoint" => "run_check",
    "runtime" => "wasi-preview1",
    "outputs" => "serviceradar.plugin_result.v1",
    "capabilities" => ["get_config", "log", "http_request", "notify:v1"],
    "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 5000}
  }

  defp manifest(entries) when is_list(entries) do
    Map.put(@base_manifest, "notifications", entries)
  end

  defp manifest(entry) when is_map(entry), do: manifest([entry])

  defp errors(map) do
    {:error, errors} = Manifest.from_map(map)
    errors
  end

  defp notifier(overrides), do: Map.merge(@notifier_entry, overrides)

  describe "normalization" do
    test "a valid entry parses and fills its defaults" do
      assert {:ok, parsed} = Manifest.from_map(manifest(@notifier_entry))

      assert [entry] = parsed.notifications
      assert entry["key"] == "pagerduty"
      assert entry["display_name"] == "PagerDuty Events v2"
      assert entry["entrypoint"] == "notify_pagerduty"
      assert entry["capabilities"] == ["send", "test", "resolve_update"]
      assert entry["payload_formats"] == ["pagerduty_v2", "json"]
      assert entry["routes"] == ["control_plane", "edge_agent"]

      # Unset optional keys normalize rather than disappear, so a consumer never
      # has to distinguish "absent" from "empty".
      assert entry["config_schema"] == %{}
      assert entry["credential_requirements"] == %{}
      assert entry["inbound"]["enabled"] == false
    end

    test "routes default to the control plane, which is the documented recommendation" do
      assert {:ok, parsed} =
               Manifest.from_map(manifest(Map.delete(@notifier_entry, "routes")))

      assert [%{"routes" => ["control_plane"]}] = parsed.notifications
    end

    test "a manifest with no notifications block parses with an empty list" do
      assert {:ok, parsed} =
               Manifest.from_map(%{
                 @base_manifest
                 | "capabilities" => ["get_config", "log", "http_request"]
               })

      assert parsed.notifications == []
    end
  end

  describe "the key set is closed" do
    test "provider_key is rejected; the entry key is spelled key" do
      assert "notifications[1].provider_key is not allowed" in errors(
               manifest(notifier(%{"provider_key" => "pagerduty"}))
             )
    end

    test "inbound_callback is rejected; the block is spelled inbound" do
      assert "notifications[1].inbound_callback is not allowed" in errors(
               manifest(notifier(%{"inbound_callback" => %{"enabled" => true}}))
             )
    end

    test "provider-owned UI markup keys are rejected like they are on actions" do
      for key <- ~w(html javascript component live_view ui_code) do
        assert "notifications[1].#{key} is not allowed" in errors(
                 manifest(notifier(%{key => "<div/>"}))
               )
      end
    end
  end

  describe "capabilities" do
    test "an entry missing send is rejected and the message names it" do
      assert "notifications[1].capabilities must include send and test; missing send" in errors(
               manifest(notifier(%{"capabilities" => ["test"]}))
             )
    end

    test "an entry missing test is rejected and the message names it" do
      assert "notifications[1].capabilities must include send and test; missing test" in errors(
               manifest(notifier(%{"capabilities" => ["send"]}))
             )
    end

    test "an undeclared capability is rejected" do
      assert "notifications[1].capabilities contains unsupported entries: telepathy" in errors(
               manifest(notifier(%{"capabilities" => ["send", "test", "telepathy"]}))
             )
    end

    test "capabilities must be a non-empty list" do
      assert "notifications[1].capabilities must be a non-empty list of strings" in errors(
               manifest(notifier(%{"capabilities" => []}))
             )
    end
  end

  describe "payload formats and routes" do
    test "an unsupported payload format is rejected" do
      assert "notifications[1].payload_formats contains unsupported entries: smoke_signal" in errors(
               manifest(notifier(%{"payload_formats" => ["smoke_signal"]}))
             )
    end

    test "a notifier that can render nothing is rejected" do
      assert "notifications[1].payload_formats must be a non-empty list of strings" in errors(
               manifest(notifier(%{"payload_formats" => []}))
             )
    end

    test "an unsupported execution route is rejected" do
      assert "notifications[1].routes contains unsupported entries: carrier_pigeon" in errors(
               manifest(notifier(%{"routes" => ["carrier_pigeon"]}))
             )
    end
  end

  describe "notify:v1 coherence" do
    test "notifier entries without the notify:v1 capability are rejected" do
      map = manifest(@notifier_entry)
      map = %{map | "capabilities" => ["get_config", "log", "http_request"]}

      assert errors(map) == ["notifications requires the notify:v1 capability to be declared"]
    end

    test "notify:v1 without notifier entries is rejected" do
      assert errors(@base_manifest) == [
               "capabilities declare notify:v1 but the manifest has no notifications entries"
             ]
    end

    test "a broken entry reports its own error, not a phantom missing block" do
      # Regression guard: a failed entry is dropped from the normalized list, so
      # keying the coherence check on the normalized list would bury the real
      # error under "the manifest has no notifications entries".
      assert errors(manifest(notifier(%{"capabilities" => ["send"]}))) == [
               "notifications[1].capabilities must include send and test; missing test"
             ]
    end
  end

  describe "keys" do
    test "a duplicate key is rejected because action_key resolution would be ambiguous" do
      assert "notifications key pagerduty is declared more than once" in errors(
               manifest([@notifier_entry, notifier(%{"display_name" => "Second"})])
             )
    end

    test "an upper-case or spaced key is rejected" do
      assert "notifications[1].key must use lowercase letters, numbers, dots, underscores, or hyphens" in errors(
               manifest(notifier(%{"key" => "PagerDuty Events"}))
             )
    end

    test "notification_keys/1 returns declared keys in order" do
      map = manifest([@notifier_entry, notifier(%{"key" => "opsgenie"})])
      assert {:ok, ["pagerduty", "opsgenie"]} = Manifest.notification_keys(map)
    end

    test "notification_keys/1 distinguishes no notifiers from a broken block" do
      assert {:ok, []} = Manifest.notification_keys(%{})
      assert {:error, [_ | _]} = Manifest.notification_keys(manifest(%{"key" => "x"}))
    end
  end

  describe "credential requirements" do
    @valid_requirements %{
      "http_header" => %{
        "injection_mode" => "http_header",
        "name" => "X-API-Key"
      },
      "bearer_token" => %{"injection_mode" => "bearer_token"},
      "basic_auth" => %{"injection_mode" => "basic_auth"},
      "query" => %{"injection_mode" => "query", "name" => "api_key"},
      "form_urlencoded" => %{
        "injection_mode" => "form_urlencoded",
        "method" => "POST",
        "host" => "identity.example.test",
        "port" => 443,
        "path" => "/oauth/token",
        "field_username" => "username"
      },
      "oauth2_password_bearer" => %{
        "injection_mode" => "oauth2_password_bearer",
        "method" => "POST",
        "host" => "api.example.test",
        "port" => 443,
        "path" => "/incidents",
        "token_method" => "POST",
        "token_host" => "identity.example.test",
        "token_port" => 443,
        "token_path" => "/oauth/token",
        "field_username" => "username",
        "field_password" => "password",
        "fixed_grant_type" => "password"
      },
      "oauth2_client_credentials" => %{
        "injection_mode" => "oauth2_client_credentials",
        "method" => "GET",
        "host" => "clearpass.example.test",
        "port" => 443,
        "path" => "/api/session",
        "token_method" => "POST",
        "token_host" => "clearpass.example.test",
        "token_port" => 443,
        "token_path" => "/api/oauth",
        "field_client_id" => "client_id",
        "field_client_secret" => "client_secret",
        "fixed_grant_type" => "client_credentials"
      }
    }

    test "each canonical injection mode is accepted only with its complete typed contract" do
      assert Enum.sort(Map.keys(@valid_requirements)) ==
               Enum.sort(Manifest.allowed_credential_injection_modes())

      for {mode, requirement} <- @valid_requirements do
        entry = notifier(%{"credential_requirements" => %{"token" => requirement}})

        assert {:ok, parsed} = Manifest.from_map(manifest(entry)), mode
        assert [normalized] = parsed.notifications
        assert normalized["credential_requirements"]["token"]["injection_mode"] == mode
      end
    end

    test "bearer injection normalizes the host defaults explicitly" do
      entry =
        notifier(%{
          "credential_requirements" => %{
            "token" => @valid_requirements["bearer_token"]
          }
        })

      assert {:ok, parsed} = Manifest.from_map(manifest(entry))
      assert [normalized] = parsed.notifications
      requirement = normalized["credential_requirements"]["token"]
      assert requirement["name"] == "Authorization"
      assert requirement["scheme"] == "Bearer"
    end

    test "http_header and query require the injection name at import" do
      for mode <- ~w(http_header query) do
        entry =
          notifier(%{
            "credential_requirements" => %{
              "token" => %{"injection_mode" => mode}
            }
          })

        assert Enum.any?(
                 errors(manifest(entry)),
                 &String.contains?(&1, "credential_requirements.token.name is required")
               ),
               mode
      end
    end

    test "form injection requires an exact target and at least one material-field mapping" do
      entry =
        notifier(%{
          "credential_requirements" => %{
            "token" => %{"injection_mode" => "form_urlencoded"}
          }
        })

      reported = errors(manifest(entry))

      for field <- ~w(method host port path) do
        assert Enum.any?(
                 reported,
                 &String.contains?(&1, "credential_requirements.token.#{field}")
               )
      end

      assert Enum.any?(reported, &String.contains?(&1, "at least one field_ mapping"))
    end

    test "oauth password injection requires complete token and upstream targets" do
      entry =
        notifier(%{
          "credential_requirements" => %{
            "token" => %{"injection_mode" => "oauth2_password_bearer"}
          }
        })

      reported = errors(manifest(entry))

      for field <- ~w(method host port path token_method token_host token_port token_path) do
        assert Enum.any?(
                 reported,
                 &String.contains?(&1, "credential_requirements.token.#{field}")
               )
      end

      assert Enum.any?(reported, &String.contains?(&1, "field mapping to username"))
      assert Enum.any?(reported, &String.contains?(&1, "field mapping to password"))
      assert Enum.any?(reported, &String.contains?(&1, "fixed_grant_type must equal password"))
    end

    test "oauth client-credentials injection requires its own grant fields, not the password grant's" do
      entry =
        notifier(%{
          "credential_requirements" => %{
            "token" => %{"injection_mode" => "oauth2_client_credentials"}
          }
        })

      reported = errors(manifest(entry))

      for field <- ~w(method host port path token_method token_host token_port token_path) do
        assert Enum.any?(
                 reported,
                 &String.contains?(&1, "credential_requirements.token.#{field}")
               )
      end

      assert Enum.any?(reported, &String.contains?(&1, "field mapping to client_id"))
      assert Enum.any?(reported, &String.contains?(&1, "field mapping to client_secret"))

      assert Enum.any?(
               reported,
               &String.contains?(&1, "fixed_grant_type must equal client_credentials")
             )
    end

    # The two OAuth2 modes share an exchange, so the manifest is the only place
    # that can stop one being declared with the other's credential fields. A
    # client-credentials requirement carrying username/password mappings passes
    # every generic check - the mappings are well-formed and the grant type is
    # self-consistent - so only the per-mode required-field list refuses it.
    test "an oauth mode does not accept the other oauth mode's credential fields" do
      swapped = %{
        "oauth2_client_credentials" =>
          @valid_requirements["oauth2_client_credentials"]
          |> Map.drop(~w(field_client_id field_client_secret))
          |> Map.merge(%{"field_username" => "username", "field_password" => "password"}),
        "oauth2_password_bearer" =>
          @valid_requirements["oauth2_password_bearer"]
          |> Map.drop(~w(field_username field_password))
          |> Map.merge(%{
            "field_client_id" => "client_id",
            "field_client_secret" => "client_secret"
          })
      }

      for {mode, requirement} <- swapped do
        reported =
          errors(manifest(notifier(%{"credential_requirements" => %{"token" => requirement}})))

        assert Enum.any?(reported, &String.contains?(&1, "must declare a field mapping to")),
               "#{mode} accepted the other grant's credential fields: #{inspect(reported)}"
      end
    end

    test "ports and mapping values stay typed instead of being stringified implicitly" do
      requirement =
        @valid_requirements["oauth2_password_bearer"]
        |> Map.put("port", "443")
        |> Map.put("token_port", "443")
        |> Map.put("field_username", true)

      entry = notifier(%{"credential_requirements" => %{"token" => requirement}})
      reported = errors(manifest(entry))

      assert Enum.any?(
               reported,
               &String.contains?(&1, "credential_requirements.token.port must be an integer")
             )

      assert Enum.any?(
               reported,
               &String.contains?(
                 &1,
                 "credential_requirements.token.token_port must be an integer"
               )
             )

      assert Enum.any?(
               reported,
               &String.contains?(
                 &1,
                 "credential_requirements.token.field_username must be a string"
               )
             )
    end

    test "unknown or nested raw inject fields are rejected at import" do
      entry =
        notifier(%{
          "credential_requirements" => %{
            "token" => %{
              "injection_mode" => "bearer_token",
              "inject" => %{"type" => "query", "name" => true},
              "allowed_hosts" => ["chat.example.test"],
              "surprise" => "value"
            }
          }
        })

      reported = errors(manifest(entry))

      assert Enum.any?(
               reported,
               &String.contains?(&1, "credential_requirements.token.inject is not allowed")
             )

      assert Enum.any?(
               reported,
               &String.contains?(&1, "credential_requirements.token.surprise is not allowed")
             )

      assert Enum.any?(
               reported,
               &String.contains?(&1, "credential_requirements.token.allowed_hosts is not allowed")
             )
    end

    test "the optional allow scope is closed and typed" do
      requirement = %{
        "injection_mode" => "bearer_token",
        "allow" => %{
          "hosts" => [true],
          "ports" => ["443"],
          "surprise" => ["value"]
        }
      }

      entry = notifier(%{"credential_requirements" => %{"token" => requirement}})
      reported = errors(manifest(entry))

      assert Enum.any?(reported, &String.contains?(&1, ".allow.hosts must contain only strings"))

      assert Enum.any?(
               reported,
               &String.contains?(&1, ".allow.ports must contain only integer ports")
             )

      assert Enum.any?(reported, &String.contains?(&1, ".allow.surprise is not allowed"))
    end

    test "manifest literals cannot masquerade as fixed credential fields" do
      requirement =
        Map.put(@valid_requirements["form_urlencoded"], "fixed_api_key", "manifest-secret")

      entry = notifier(%{"credential_requirements" => %{"token" => requirement}})

      assert Enum.any?(
               errors(manifest(entry)),
               &String.contains?(&1, "credential_requirements.token.fixed_api_key is not allowed")
             )
    end

    test "a requirement without an injection mode is rejected at import" do
      entry = notifier(%{"credential_requirements" => %{"token" => %{"required" => true}}})

      assert Enum.any?(
               errors(manifest(entry)),
               &String.contains?(&1, "credential_requirements.token.injection_mode is required")
             )
    end

    test "a shorthand injection mode is rejected rather than silently accepted" do
      # `IntegrationDescriptor` accepts these aliases; the notifications block
      # deliberately does not, so an author never learns a spelling one surface
      # takes and another refuses (tasks 3.2.4).
      for shorthand <- ~w(header http_basic_auth query_param http_query bearer basic form) do
        entry =
          notifier(%{"credential_requirements" => %{"token" => %{"injection_mode" => shorthand}}})

        assert Enum.any?(
                 errors(manifest(entry)),
                 &String.starts_with?(
                   &1,
                   "notifications[1].credential_requirements.token.injection_mode must be one of:"
                 )
               ),
               "shorthand #{shorthand} was accepted"
      end
    end

    test "no injection mode rewrites a URL path" do
      # Slack and Discord incoming-webhook URLs carry the secret in the PATH.
      # Adding a mode here without adding it to the host would make the manifest
      # promise something no runtime performs.
      refute "url_path" in Manifest.allowed_credential_injection_modes()

      entry =
        notifier(%{
          "credential_requirements" => %{"webhook" => %{"injection_mode" => "url_path"}}
        })

      assert Enum.any?(errors(manifest(entry)), &String.contains?(&1, "injection_mode"))
    end

    test "a non-map requirement is rejected" do
      assert "notifications[1].credential_requirements.token must be a map" in errors(
               manifest(notifier(%{"credential_requirements" => %{"token" => "secret"}}))
             )
    end
  end

  describe "inbound" do
    test "an enabled callback must declare a signature, its header, and a path" do
      entry =
        notifier(%{
          "capabilities" => ["send", "test", "inbound_callback"],
          "inbound" => %{"enabled" => true}
        })

      reported = errors(manifest(entry))

      assert "notifications[1].inbound.signature must be hmac_sha256 when inbound is enabled" in reported

      assert "notifications[1].inbound.path_suffix is required when inbound is enabled" in reported
    end

    test "a fully declared callback parses" do
      entry =
        notifier(%{
          "capabilities" => ["send", "test", "inbound_callback"],
          "inbound" => %{
            "enabled" => true,
            "signature" => "hmac_sha256",
            "signature_header" => "X-Acme-Signature",
            "timestamp_header" => "X-Acme-Timestamp",
            "tolerance_seconds" => 300,
            "path_suffix" => "acme"
          }
        })

      assert {:ok, parsed} = Manifest.from_map(manifest(entry))
      assert [%{"inbound" => inbound}] = parsed.notifications
      assert inbound["enabled"] == true
      assert inbound["signature"] == "hmac_sha256"
      assert inbound["path_suffix"] == "acme"
      assert inbound["tolerance_seconds"] == 300
    end

    test "an enabled callback without the inbound_callback capability is rejected" do
      entry =
        notifier(%{
          "inbound" => %{
            "enabled" => true,
            "signature" => "hmac_sha256",
            "signature_header" => "X-Acme-Signature",
            "path_suffix" => "acme"
          }
        })

      assert "notifications[1].inbound requires the inbound_callback capability" in errors(
               manifest(entry)
             )
    end

    test "the inbound_callback capability without an enabled callback is rejected" do
      entry = notifier(%{"capabilities" => ["send", "test", "inbound_callback"]})

      assert "notifications[1].capabilities declare inbound_callback but inbound is not enabled" in errors(
               manifest(entry)
             )
    end

    test "an unbounded replay window is rejected" do
      entry =
        notifier(%{
          "capabilities" => ["send", "test", "inbound_callback"],
          "inbound" => %{
            "enabled" => true,
            "signature" => "hmac_sha256",
            "signature_header" => "X-Acme-Signature",
            "path_suffix" => "acme",
            "tolerance_seconds" => 86_400
          }
        })

      assert Enum.any?(errors(manifest(entry)), &String.contains?(&1, "tolerance_seconds"))
    end

    test "an unknown inbound key is rejected" do
      entry =
        notifier(%{
          "capabilities" => ["send", "test", "inbound_callback"],
          "inbound" => %{"enabled" => true, "secret" => "hunter2"}
        })

      assert "notifications[1].inbound.secret is not allowed" in errors(manifest(entry))
    end
  end

  describe "config schema" do
    test "a schema outside the supported JSON Schema subset is rejected" do
      entry = notifier(%{"config_schema" => %{"type" => "sonnet"}})
      reported = errors(manifest(entry))

      assert Enum.any?(reported, &String.starts_with?(&1, "notifications[1].config_schema:"))
    end

    test "a supported schema parses" do
      entry =
        notifier(%{
          "config_schema" => %{
            "type" => "object",
            "properties" => %{"routing_key" => %{"type" => "string"}}
          }
        })

      assert {:ok, parsed} = Manifest.from_map(manifest(entry))
      assert [%{"config_schema" => %{"type" => "object"}}] = parsed.notifications
    end
  end

  describe "vocabulary agreement with NotificationProvider" do
    # `Plugins.Manifest` cannot name `Notifications.NotificationProvider`: the
    # provider belongs_to `Plugins.PluginPackage`, whose validation calls back
    # into the manifest validator, so the reference would close a compile cycle.
    # The vocabularies are therefore two literal lists, and these are the tests
    # that stop them drifting. Drift is not cosmetic: a capability a manifest
    # accepts and a provider row cannot store produces a package that imports
    # and a provider that cannot be created from it.
    test "capabilities agree" do
      assert Enum.sort(Manifest.allowed_notification_capabilities()) ==
               NotificationProvider.capabilities() |> Enum.map(&to_string/1) |> Enum.sort()
    end

    test "payload formats agree" do
      assert Enum.sort(Manifest.allowed_notification_payload_formats()) ==
               NotificationProvider.payload_formats() |> Enum.map(&to_string/1) |> Enum.sort()
    end

    test "execution routes agree" do
      assert Enum.sort(Manifest.allowed_notification_routes()) ==
               NotificationProvider.execution_routes() |> Enum.map(&to_string/1) |> Enum.sort()
    end
  end

  describe "yaml" do
    test "the block parses from plugin.yaml, not only from a map" do
      yaml = """
      id: acme-notifier
      name: Acme Notifier
      version: 1.0.0
      entrypoint: run_check
      runtime: wasi-preview1
      outputs: serviceradar.plugin_result.v1
      capabilities:
        - get_config
        - log
        - http_request
        - notify:v1
      resources:
        requested_memory_mb: 32
        requested_cpu_ms: 5000
      notifications:
        - key: pagerduty
          display_name: PagerDuty Events v2
          entrypoint: notify_pagerduty
          capabilities:
            - send
            - test
          payload_formats:
            - pagerduty_v2
          routes:
            - control_plane
          credential_requirements:
            routing_key:
              injection_mode: http_header
              name: Authorization
              scheme: Bearer
      """

      assert {:ok, parsed} = Manifest.from_yaml(yaml)
      assert [entry] = parsed.notifications
      assert entry["key"] == "pagerduty"
      assert entry["credential_requirements"]["routing_key"]["injection_mode"] == "http_header"
      assert entry["credential_requirements"]["routing_key"]["name"] == "Authorization"
    end
  end
end

defmodule ServiceRadar.Notifications.DedupeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.Dedupe
  alias ServiceRadar.Notifications.MatchExpression.Fields
  alias ServiceRadar.Observability.StatefulAlertEngine.Record

  @now ~U[2026-08-09 12:00:00.000000Z]

  defp alert(overrides) do
    Map.merge(
      %{
        id: "alert-1",
        title: "Interface flapping",
        severity: :critical,
        status: :pending,
        device_uid: "device-abc",
        tags: ["prod"],
        metadata: %{
          "incident_rule_id" => "rule-1",
          "incident_group_key" => "device_id=abc|severity=high",
          "incident_occurrence_count" => 4
        }
      },
      overrides
    )
  end

  defp alert, do: alert(%{})

  defp route(overrides), do: Map.merge(%{id: "route-1", dedupe_key_template: nil}, overrides)

  describe "incident identity" do
    test "is the composite the alert lifecycle wrote into metadata" do
      assert Dedupe.incident_identity(alert()) ==
               {:ok, {:incident, "rule-1", "device_id=abc|severity=high"}}
    end

    test "reads atom-keyed metadata as well as string-keyed" do
      alert = alert(%{metadata: %{incident_rule_id: "rule-9", incident_group_key: "a=b"}})
      assert Dedupe.incident_identity(alert) == {:ok, {:incident, "rule-9", "a=b"}}
    end

    test "falls back to a rule_id carried directly on the alert" do
      alert = alert(%{metadata: %{}, rule_id: "rule-direct", group_key: "k=v"})
      assert Dedupe.incident_identity(alert) == {:ok, {:incident, "rule-direct", "k=v"}}
    end

    test "uses the global group key when the rule declares no group_by" do
      alert = alert(%{metadata: %{"incident_rule_id" => "rule-1"}})
      assert Dedupe.incident_identity(alert) == {:ok, {:incident, "rule-1", "global"}}
      assert Dedupe.global_group_key() == "global"
    end

    test "is the alert itself for a path that bypasses the stateful engine" do
      alert = alert(%{metadata: %{}})
      assert Dedupe.incident_identity(alert) == {:ok, {:alert, "alert-1"}}
    end

    test "is an error rather than a guess when nothing identifies the incident" do
      assert Dedupe.incident_identity(%{metadata: %{}}) == {:error, :no_incident_identity}

      assert Dedupe.incident_identity(%{id: "  ", metadata: %{}}) ==
               {:error, :no_incident_identity}

      assert Dedupe.incident_identity(:not_a_map) == {:error, :no_incident_identity}
    end

    test "ignores a blank or non-binary identifier" do
      assert Dedupe.incident_identity(alert(%{metadata: %{"incident_rule_id" => ""}})) ==
               {:ok, {:alert, "alert-1"}}

      assert Dedupe.incident_identity(alert(%{metadata: %{"incident_rule_id" => 17}})) ==
               {:ok, {:alert, "alert-1"}}
    end
  end

  describe "default key format" do
    test "embeds the group key verbatim in the field=value convention" do
      assert Dedupe.default_key({:incident, "rule-1", "device_id=abc|severity=high"}) ==
               "rule=rule-1|group=device_id=abc|severity=high"

      assert Dedupe.default_key({:alert, "alert-1"}) == "alert=alert-1"
    end

    test "embeds exactly the group key StatefulAlertEngine.Record builds" do
      record = %{attributes: %{"device_id" => "abc", "severity" => "high"}}

      assert {:ok, group_key, _values} =
               Record.build_group(["device_id", "severity"], record)

      alert =
        alert(%{metadata: %{"incident_rule_id" => "rule-1", "incident_group_key" => group_key}})

      assert {:ok, key} = Dedupe.dedupe_key(alert)
      assert key == "rule=rule-1|group=" <> group_key
      assert String.ends_with?(key, "|group=device_id=abc|severity=high")
    end

    test "matches the group key Record builds for a rule with no group_by" do
      assert Record.build_group(nil, %{}) == {:ok, Dedupe.global_group_key(), %{}}
      assert Record.build_group([], %{}) == {:ok, Dedupe.global_group_key(), %{}}
    end
  end

  describe "dedupe_key/3 default path" do
    test "derives the key from the incident identity" do
      assert Dedupe.dedupe_key(alert()) ==
               {:ok, "rule=rule-1|group=device_id=abc|severity=high"}
    end

    test "is stable across repeated calls" do
      keys = for _repeat <- 1..50, do: Dedupe.dedupe_key(alert())
      assert Enum.uniq(keys) == [{:ok, "rule=rule-1|group=device_id=abc|severity=high"}]
    end

    test "is identical for two alerts that share an incident identity" do
      first = alert(%{id: "alert-1", title: "first sighting"})
      second = alert(%{id: "alert-2", title: "second sighting", severity: :emergency})

      assert Dedupe.dedupe_key(first) == Dedupe.dedupe_key(second)
    end

    test "differs when the group key differs" do
      other = alert(%{metadata: %{"incident_rule_id" => "rule-1", "incident_group_key" => "d=x"}})
      assert Dedupe.dedupe_key(alert()) != Dedupe.dedupe_key(other)
    end

    test "differs when the rule differs" do
      other =
        alert(%{
          metadata: %{
            "incident_rule_id" => "rule-2",
            "incident_group_key" => "device_id=abc|severity=high"
          }
        })

      assert Dedupe.dedupe_key(alert()) != Dedupe.dedupe_key(other)
    end

    test "propagates the missing-identity error" do
      assert Dedupe.dedupe_key(%{metadata: %{}}) == {:error, :no_incident_identity}
    end

    test "a route with no template uses the default identity" do
      assert Dedupe.dedupe_key(alert(), route(%{})) == Dedupe.dedupe_key(alert())
      assert Dedupe.dedupe_key(alert(), nil) == Dedupe.dedupe_key(alert())
    end

    test "a blank template is treated as absent, not as an empty key" do
      assert Dedupe.dedupe_key(alert(), route(%{dedupe_key_template: "   "})) ==
               Dedupe.dedupe_key(alert())

      assert Dedupe.dedupe_key(alert(), route(%{dedupe_key_template: ""})) ==
               Dedupe.dedupe_key(alert())
    end
  end

  describe "dedupe_key/3 route template override" do
    test "renders a catalog path" do
      route = route(%{dedupe_key_template: "device:{{ device.uid }}"})

      subject = %{"device" => %{"uid" => "device-abc"}}

      assert Dedupe.dedupe_key(alert(), route, subject: subject) == {:ok, "device:device-abc"}
    end

    test "resolves the incident identity through the default subject" do
      route = route(%{dedupe_key_template: "{{ alert.rule_id }}::{{ alert.group_key }}"})

      assert Dedupe.dedupe_key(alert(), route) ==
               {:ok, "rule-1::device_id=abc|severity=high"}
    end

    test "resolves ordinary alert attributes through the default subject" do
      route = route(%{dedupe_key_template: "{{ alert.severity }}/{{ alert.id }}"})
      assert Dedupe.dedupe_key(alert(), route) == {:ok, "critical/alert-1"}
    end

    test "resolves an open-namespace metadata path" do
      route = route(%{dedupe_key_template: "{{ alert.metadata.incident_occurrence_count }}"})
      assert Dedupe.dedupe_key(alert(), route) == {:ok, "4"}
    end

    test "applies the fixed filter set" do
      cases = [
        {"{{ alert.severity | upper }}", "CRITICAL"},
        {"{{ alert.title | lower }}", "interface flapping"},
        # truncate is the shared renderer's, ellipsis and all, because a dedupe
        # key and a notification body must not disagree about what a filter means
        {"{{ alert.title | truncate: 9 }}", "Interf..."},
        {"{{ alert.title | truncate: 40 }}", "Interface flapping"},
        {"{{ alert.title | url_encode }}", "Interface+flapping"},
        {"{{ alert.severity | upper | lower }}", "critical"}
      ]

      for {template, expected} <- cases do
        assert Dedupe.dedupe_key(alert(), route(%{dedupe_key_template: template})) ==
                 {:ok, expected},
               "template #{template} did not render #{expected}"
      end
    end

    test "default fills in for a missing or empty value" do
      route = route(%{dedupe_key_template: ~s({{ alert.acknowledged_by | default: "nobody" }})})
      assert Dedupe.dedupe_key(alert(), route) == {:ok, "nobody"}

      present = alert(%{acknowledged_by: "root"})
      assert Dedupe.dedupe_key(present, route) == {:ok, "root"}
    end

    test "json and iso8601 render structured and temporal values" do
      alert =
        alert(%{
          first_seen_at: ~U[2026-08-09 11:00:00Z],
          metadata: %{
            "incident_rule_id" => "rule-1",
            "incident_group_key" => "device_id=abc",
            "incident_group_values" => %{"device_id" => "abc"}
          }
        })

      assert Dedupe.dedupe_key(
               alert,
               route(%{dedupe_key_template: "{{ alert.first_seen_at | iso8601 }}"})
             ) == {:ok, "2026-08-09T11:00:00Z"}

      assert Dedupe.dedupe_key(
               alert,
               route(%{dedupe_key_template: "{{ alert.metadata.incident_group_values | json }}"})
             ) == {:ok, ~s({"device_id":"abc"})}
    end

    test "renders literal text around the substitutions" do
      route = route(%{dedupe_key_template: "svc/{{ alert.severity }}/{{ alert.id }}/end"})
      assert Dedupe.dedupe_key(alert(), route) == {:ok, "svc/critical/alert-1/end"}
    end

    # The route MATCH allow-list and the TEMPLATE variable catalog are different
    # surfaces on purpose: a route matches alert attributes, while a template
    # renders a wider context in which the device is its own namespace. Pinning
    # the asymmetry here keeps a future reader from "fixing" one to look like
    # the other, and shows that the mismatch surfaces as an actionable save-time
    # error rather than as a key that renders blank.
    test "a matchable field is not automatically a renderable one" do
      assert "alert.device_uid" in Fields.route_fields()

      assert {:error, {:invalid_template, message}} =
               Dedupe.dedupe_key(alert(), route(%{dedupe_key_template: "{{ alert.device_uid }}"}))

      assert message =~ "unknown variable path"

      assert Dedupe.dedupe_key(alert(), route(%{dedupe_key_template: "{{ device.uid }}"}),
               subject: %{"device" => %{"uid" => "device-abc"}}
             ) == {:ok, "device-abc"}
    end

    test "is stable across repeated calls" do
      route = route(%{dedupe_key_template: "{{ alert.rule_id }}::{{ alert.group_key }}"})
      keys = for _repeat <- 1..50, do: Dedupe.dedupe_key(alert(), route)
      assert length(Enum.uniq(keys)) == 1
    end

    test "an unknown variable path is rejected by the grammar, not rendered blank" do
      route = route(%{dedupe_key_template: "{{ alert.serverity }}"})

      assert {:error, {:invalid_template, message}} = Dedupe.dedupe_key(alert(), route)
      assert message =~ "unknown variable path"
    end

    test "an unknown filter is rejected" do
      route = route(%{dedupe_key_template: "{{ alert.severity | reverse }}"})

      assert {:error, {:invalid_template, message}} = Dedupe.dedupe_key(alert(), route)
      assert message =~ "unknown filter"
    end

    test "a code construct is rejected" do
      route = route(%{dedupe_key_template: "<%= alert.severity %>"})

      assert {:error, {:invalid_template, message}} = Dedupe.dedupe_key(alert(), route)
      assert message =~ "restricted substitution"
    end

    test "a template that renders to nothing is an error, never an empty key" do
      route = route(%{dedupe_key_template: "{{ alert.acknowledged_by }}"})
      assert Dedupe.dedupe_key(alert(), route) == {:error, :empty_dedupe_key}
    end

    test "only the route that carries the template deviates" do
      templated = route(%{id: "a", dedupe_key_template: "{{ alert.id }}"})
      plain = route(%{id: "b"})

      assert Dedupe.dedupe_key(alert(), templated) == {:ok, "alert-1"}
      assert Dedupe.dedupe_key(alert(), plain) == Dedupe.dedupe_key(alert())
    end

    test "a template works for an alert with no incident identity" do
      alert = alert(%{metadata: %{}})
      route = route(%{dedupe_key_template: "{{ alert.id }}"})

      assert Dedupe.dedupe_key(alert, route) == {:ok, "alert-1"}
    end
  end

  describe "key bounds" do
    test "a very long key is fingerprinted rather than merely cut" do
      long = String.duplicate("k=v|", 400)
      alert = alert(%{metadata: %{"incident_rule_id" => "rule-1", "incident_group_key" => long}})

      other_long = long <> "extra=1"

      other =
        alert(%{metadata: %{"incident_rule_id" => "rule-1", "incident_group_key" => other_long}})

      assert {:ok, key} = Dedupe.dedupe_key(alert)
      assert {:ok, other_key} = Dedupe.dedupe_key(other)

      assert byte_size(key) <= 512
      assert byte_size(other_key) <= 512
      assert key != other_key
      assert String.valid?(key)
      assert Dedupe.dedupe_key(alert) == {:ok, key}
    end

    test "a key inside the bound is untouched" do
      assert {:ok, key} = Dedupe.dedupe_key(alert())
      refute String.contains?(key, "#")
    end

    test "a multibyte key stays valid utf8 after bounding" do
      long = String.duplicate("gruppe=uber-lang-", 40)
      alert = alert(%{metadata: %{"incident_rule_id" => "rule-1", "incident_group_key" => long}})

      assert {:ok, key} = Dedupe.dedupe_key(alert)
      assert String.valid?(key)
    end
  end

  describe "subject/1" do
    test "overlays the incident identity onto the published catalog paths" do
      assert %{"alert" => alert_subject} = Dedupe.subject(alert())

      assert alert_subject["rule_id"] == "rule-1"
      assert alert_subject["group_key"] == "device_id=abc|severity=high"
      assert alert_subject[:severity] == :critical
    end

    test "reports the global group key when the rule has no grouping" do
      assert %{"alert" => alert_subject} = Dedupe.subject(alert(%{metadata: %{}}))

      assert alert_subject["rule_id"] == nil
      assert alert_subject["group_key"] == "global"
    end
  end

  describe "routing_request_key/1" do
    test "is keyed by alert, lifecycle reason, step, and dedupe key" do
      request = %{
        alert_id: "alert-1",
        lifecycle_reason: :fire,
        step_number: 1,
        dedupe_key: "rule=rule-1|group=device_id=abc"
      }

      assert Dedupe.routing_request_key(request) ==
               {:ok, "alert=alert-1|reason=fire|step=1|dedupe=rule=rule-1|group=device_id=abc"}
    end

    test "re-emitting the same request resolves to the same key" do
      request = %{alert_id: "a", lifecycle_reason: "renotify", step_number: 2, dedupe_key: "k"}
      keys = for _repeat <- 1..25, do: Dedupe.routing_request_key(request)
      assert length(Enum.uniq(keys)) == 1
    end

    test "a first notification with no step renders a placeholder" do
      request = %{alert_id: "a", lifecycle_reason: :fire, dedupe_key: "k"}
      assert Dedupe.routing_request_key(request) == {:ok, "alert=a|reason=fire|step=-|dedupe=k"}
    end

    test "distinguishes the reason, the step, and the dedupe key" do
      base = %{alert_id: "a", lifecycle_reason: :fire, step_number: 1, dedupe_key: "k"}

      variants = [
        base,
        %{base | lifecycle_reason: :escalate},
        %{base | step_number: 2},
        %{base | dedupe_key: "other"},
        %{base | alert_id: "b"}
      ]

      keys = Enum.map(variants, &Dedupe.routing_request_key/1)
      assert length(Enum.uniq(keys)) == length(variants)
    end

    test "refuses a request with a hole in it rather than colliding two of them" do
      assert Dedupe.routing_request_key(%{lifecycle_reason: :fire, dedupe_key: "k"}) ==
               {:error, :incomplete_routing_request}

      assert Dedupe.routing_request_key(%{alert_id: "a", dedupe_key: "k"}) ==
               {:error, :incomplete_routing_request}

      assert Dedupe.routing_request_key(%{alert_id: "a", lifecycle_reason: :fire}) ==
               {:error, :incomplete_routing_request}

      assert Dedupe.routing_request_key(:not_a_map) == {:error, :incomplete_routing_request}
    end

    test "reads string keys as well as atom keys" do
      request = %{
        "alert_id" => "a",
        "lifecycle_reason" => "fire",
        "step_number" => 3,
        "dedupe_key" => "k"
      }

      assert Dedupe.routing_request_key(request) == {:ok, "alert=a|reason=fire|step=3|dedupe=k"}
    end
  end

  describe "effective cadence" do
    test "is the maximum of every present knob, so configuration can only be quieter" do
      assert Dedupe.effective_cadence_seconds(%{
               cooldown_seconds: 300,
               renotify_seconds: 21_600,
               throttle_seconds: 60,
               repeat_interval_seconds: 900
             }) == 21_600
    end

    test "a route throttle below the rule floor cannot widen the cadence" do
      floor = %{renotify_seconds: 21_600}

      assert Dedupe.effective_cadence_seconds(Map.put(floor, :throttle_seconds, 60)) ==
               Dedupe.effective_cadence_seconds(floor)
    end

    test "a policy repeat interval above the floor lengthens the cadence" do
      assert Dedupe.effective_cadence_seconds(%{
               renotify_seconds: 21_600,
               repeat_interval_seconds: 43_200
             }) == 43_200
    end

    test "treats missing, nil, zero, negative, and non-integer values as no constraint" do
      assert Dedupe.effective_cadence_seconds(%{}) == 0
      assert Dedupe.effective_cadence_seconds(%{renotify_seconds: nil}) == 0
      assert Dedupe.effective_cadence_seconds(%{renotify_seconds: 0}) == 0
      assert Dedupe.effective_cadence_seconds(%{renotify_seconds: -5}) == 0
      assert Dedupe.effective_cadence_seconds(%{renotify_seconds: "600"}) == 0
      assert Dedupe.effective_cadence_seconds(:not_a_map) == 0
    end

    test "reads string keys as well as atom keys" do
      assert Dedupe.effective_cadence_seconds(%{"renotify_seconds" => 900}) == 900
    end
  end

  describe "renotify_due?/3" do
    test "an incident that has never notified is always due" do
      assert Dedupe.renotify_due?(nil, 21_600, @now)
      assert Dedupe.next_eligible_at(nil, 21_600) == nil
    end

    test "is false before the cadence elapses" do
      last = DateTime.add(@now, -120, :second)
      refute Dedupe.renotify_due?(last, 600, @now)
    end

    test "is true exactly on the boundary" do
      last = DateTime.add(@now, -600, :second)
      assert Dedupe.renotify_due?(last, 600, @now)
    end

    test "is true after the cadence elapses" do
      last = DateTime.add(@now, -601, :second)
      assert Dedupe.renotify_due?(last, 600, @now)
    end

    test "a zero or nil cadence makes every repeat due" do
      last = DateTime.add(@now, -1, :second)
      assert Dedupe.renotify_due?(last, 0, @now)
      assert Dedupe.renotify_due?(last, nil, @now)
    end

    test "reports the instant a repeat becomes eligible" do
      last = ~U[2026-08-09 06:00:00.000000Z]
      assert Dedupe.next_eligible_at(last, 21_600) == ~U[2026-08-09 12:00:00.000000Z]
    end
  end

  describe "evaluate_cadence/2" do
    test "withholds inside the rule cooldown and names the throttled reason" do
      cadence = %{
        last_notified_at: DateTime.add(@now, -120, :second),
        cooldown_seconds: 600
      }

      assert {:withheld, :throttled, details} = Dedupe.evaluate_cadence(cadence, @now)
      assert details.effective_seconds == 600
      assert details.next_eligible_at == DateTime.add(@now, 480, :second)
    end

    test "is due once the renotify interval elapses and reuses no other knob" do
      cadence = %{
        last_notified_at: DateTime.add(@now, -21_600, :second),
        renotify_seconds: 21_600
      }

      assert {:due, details} = Dedupe.evaluate_cadence(cadence, @now)
      assert details.effective_seconds == 21_600
    end

    test "is due when the incident has never notified" do
      assert {:due, details} = Dedupe.evaluate_cadence(%{renotify_seconds: 600}, @now)
      assert details.next_eligible_at == nil
    end

    test "a notification-layer knob cannot page more often than the rule allows" do
      cadence = %{
        last_notified_at: DateTime.add(@now, -400, :second),
        cooldown_seconds: 600,
        throttle_seconds: 60
      }

      assert {:withheld, :throttled, details} = Dedupe.evaluate_cadence(cadence, @now)
      assert details.effective_seconds == 600
    end

    test "is deterministic for the same inputs" do
      cadence = %{last_notified_at: DateTime.add(@now, -120, :second), cooldown_seconds: 600}
      decisions = for _repeat <- 1..25, do: Dedupe.evaluate_cadence(cadence, @now)
      assert length(Enum.uniq(decisions)) == 1
    end
  end

  describe "check_cadence_floor/2" do
    test "rejects a configured cadence below the rule floor" do
      assert Dedupe.check_cadence_floor(21_600, 900) ==
               {:error, {:below_cadence_floor, %{floor: 21_600, configured: 900}}}
    end

    test "accepts a cadence at or above the floor" do
      assert Dedupe.check_cadence_floor(21_600, 21_600) == :ok
      assert Dedupe.check_cadence_floor(21_600, 43_200) == :ok
    end

    test "has nothing to enforce when either side is absent" do
      assert Dedupe.check_cadence_floor(nil, 900) == :ok
      assert Dedupe.check_cadence_floor(21_600, nil) == :ok
      assert Dedupe.check_cadence_floor(nil, nil) == :ok
    end
  end
end

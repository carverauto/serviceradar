defmodule ServiceRadar.Observability.Zen.RuleBundleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.Zen.RuleBundle

  # rust/zen-normalize/src/tests.rs accepts bundles with these digests for the
  # same content, so a change to the framing fails on one side or the other.
  @first {"first", ~s({"nodes":[],"edges":[]})}
  @second {"second", ~s({"edges":[],"nodes":[]})}
  @two_rule_digest "sha256:578cb4621ff7758cbcec93bfcb0208ddce0a52cb01011eb5b28f15332d4d70b4"
  @empty_digest "sha256:11f468c88fd9041ba1b94ae65bbb4b04cf2d8f690b8d1d62f99f4689ccfc961b"

  test "the digest covers the ordered rule text" do
    assert RuleBundle.digest("events", "logs.syslog", [@first, @second]) == @two_rule_digest
    assert RuleBundle.digest("events", "logs.syslog", []) == @empty_digest

    refute RuleBundle.digest("events", "logs.syslog", [@second, @first]) == @two_rule_digest
    refute RuleBundle.digest("events", "logs.snmp", [@first, @second]) == @two_rule_digest
  end

  test "the document carries each rule as JDM text under the digest of its content" do
    assert {:ok, document} = RuleBundle.encode("events", "logs.syslog", [@first, @second])

    assert Jason.decode!(document) == %{
             "schema" => "serviceradar.zen.ruleset.v1",
             "stream_name" => "events",
             "subject" => "logs.syslog",
             "rules" => [
               %{"key" => "first", "jdm" => ~s({"nodes":[],"edges":[]})},
               %{"key" => "second", "jdm" => ~s({"edges":[],"nodes":[]})}
             ],
             "digest" => @two_rule_digest
           }
  end

  test "a bundle key names its stream and subject; other keys name none" do
    assert RuleBundle.parse_kv_key("zen/rulesets/events/logs.syslog.json") ==
             {:ok, {"events", "logs.syslog"}}

    assert RuleBundle.parse_kv_key("zen/rulesets/events/logs.otel.json") ==
             {:ok, {"events", "logs.otel"}}

    assert RuleBundle.parse_kv_key("zen/rulesets/events/logs.syslog") == :error
    assert RuleBundle.parse_kv_key("zen/rulesets/events/.json") == :error
    assert RuleBundle.parse_kv_key("zen/rulesets//logs.syslog.json") == :error
    assert RuleBundle.parse_kv_key("zen/rulesets/a/b/logs.syslog.json") == :error
    assert RuleBundle.parse_kv_key("agents/agent01/events/logs.syslog/_rules.json") == :error
  end
end

defmodule ServiceRadarWebNGWeb.Channels.RemoteAccessHostKeyFailureTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Channels.RemoteAccessHostKeyFailure

  @moduletag :db_free

  @unknown "ssh: handshake failed: ssh host key is not trusted: 192.0.2.10:22 offered " <>
             "ssh-ed25519 SHA256:AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK and the agent " <>
             "known-hosts store has no entry for it; review the fingerprint, then reconnect " <>
             "with the trust-on-first-use host key policy to pin it"

  @mismatch "ssh: handshake failed: ssh host key does not match the trusted entry: " <>
              "192.0.2.10:22 offered ssh-rsa SHA256:ZZZZYYYYXXXXWWWWVVVVUUUUTTTTSSSSRRR but the " <>
              "agent known-hosts store holds a different key for it; verify the change out of " <>
              "band before trusting this host again"

  test "a first contact with an unenrolled host is enrollable" do
    assert %{
             state: "unknown",
             reviewable: true,
             target: "192.0.2.10:22",
             algorithm: "ssh-ed25519",
             fingerprint: "SHA256:AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK"
           } = RemoteAccessHostKeyFailure.classify(@unknown)
  end

  test "a host that changed its key is a mismatch, not a first contact" do
    assert %{
             state: "mismatch",
             reviewable: true,
             target: "192.0.2.10:22",
             algorithm: "ssh-rsa",
             fingerprint: "SHA256:ZZZZYYYYXXXXWWWWVVVVUUUUTTTTSSSSRRR"
           } = RemoteAccessHostKeyFailure.classify(@mismatch)
  end

  test "close reasons that are not host-key failures classify to nil" do
    for reason <- [
          "closed",
          "agent closed",
          "ssh: handshake failed: ssh: unable to authenticate",
          "context canceled",
          nil,
          :normal
        ] do
      assert RemoteAccessHostKeyFailure.classify(reason) == nil
    end
  end

  # A reason whose target could not be rendered (the agent falls back to a
  # two-word placeholder) declines to match rather than reporting a fabricated
  # target back to the operator.
  test "a reason with no rendered target is not classified" do
    assert RemoteAccessHostKeyFailure.classify(
             "ssh: handshake failed: ssh host key is not trusted: the target offered ssh-ed25519 " <>
               "SHA256:AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK and the agent known-hosts " <>
               "store has no entry for it"
           ) == nil
  end

  # Agents older than 1.4.52 report this and nothing else. It carries neither
  # the target nor the key, so the decision it produces is unreviewable: the
  # console may still offer trust-on-first-use, but it must never present a
  # fingerprint the agent did not send.
  test "a pre-1.4.52 first contact is an unreviewable unknown key" do
    assert %{
             state: "unknown",
             reviewable: false,
             target: nil,
             algorithm: nil,
             fingerprint: nil
           } = RemoteAccessHostKeyFailure.classify("ssh: handshake failed: knownhosts: key is unknown")
  end

  test "a pre-1.4.52 changed key is an unreviewable mismatch, not a first contact" do
    assert %{
             state: "mismatch",
             reviewable: false,
             target: nil,
             algorithm: nil,
             fingerprint: nil
           } = RemoteAccessHostKeyFailure.classify("ssh: handshake failed: knownhosts: key mismatch")
  end

  # A revoked key is never offerable, from any agent version, so it stays
  # unclassified and reaches the console as the hard close it is.
  test "a revoked key is not a trust decision" do
    assert RemoteAccessHostKeyFailure.classify("ssh: handshake failed: knownhosts: key is revoked") == nil
  end
end

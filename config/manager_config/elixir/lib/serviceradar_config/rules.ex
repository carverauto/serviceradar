defmodule ServiceradarConfig.Rules do
  @moduledoc """
  The committed rule set, embedded in the release.

  It is NOT a parameter. The rule set does not vary by environment, by component or by
  deployment -- it is one committed artifact that every implementation reads. Taking it as an
  argument said otherwise, and that claim is what dragged it into the dependency graph of every
  call site: a service had to obtain the rules before it could obtain its configuration, and the
  only mechanism available was runfiles, which a release does not have.

  Embedded rather than read beside the instance, deliberately: the instance is read from a mount
  at runtime -- untrusted, and the thing being verified. Reading the rules from that same mount
  would let whatever supplied a bad instance supply the rules that bless it. Embedding puts them
  on the trusted side of the boundary, fixed when the release is built.

  Read at COMPILE time into a module attribute, so a release carries no dependency on a file
  being present at runtime. `@external_resource` is what makes a change to the artifact
  recompile this module rather than leaving a stale copy baked in.

  The copy lives here rather than being shared with Rust and Go because Go's `go:embed` cannot
  reach outside its own package -- exactly like the generated protobuf bindings, and guarded the
  same way by `//config/manager_config/elixir:ruleset_drift_test`.
  """

  alias Serviceradar.Config.V1.RuleSet

  @ruleset_path Path.join(__DIR__, "../../priv/ruleset.binpb") |> Path.expand()
  @external_resource @ruleset_path
  @ruleset_bytes File.read!(@ruleset_path)

  @doc """
  The rule set every `ServiceradarConfig.Manager.load/3` validates against.

  Decoding raises rather than returning an error tuple: the bytes are a build input of this very
  release, so a failure means the artifact that shipped is broken, not that a caller did anything
  wrong.
  """
  @spec embedded() :: RuleSet.t()
  def embedded, do: RuleSet.decode(@ruleset_bytes)
end

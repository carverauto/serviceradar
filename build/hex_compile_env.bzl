"""Compile-time application config that Hex dependencies must be compiled against.

`Application.compile_env/3` bakes a value into a module attribute at compile time and
records what it saw. At boot, `Config.Provider` compares every recorded value against the
release's `sys.config` and refuses to start if they disagree:

    ERROR! the application :ash has a different value set for key
    :include_embedded_source_by_default? during runtime compared to compile time.

Mix satisfies that invariant for free, because one `mix compile` evaluates the project's
root config once and every dependency is compiled under it. Here each Hex package is its
own `mix_app` target compiled in its own sandbox, so a dependency that reads a key with
`compile_env` sees only its own default -- while the assembled release still applies our
`config/config.exs` at runtime. The two disagree and the release will not boot.

Anything in this list is appended to `config/config.exs` inside every Hex package's compile
action, so dependencies record the same value the release will later supply. A key belongs
here when BOTH are true:

  * our `config/config.exs` sets it, and
  * a Hex dependency reads it through `Application.compile_env/2,3`

Suppressing the check with `validate_compile_env: false` is not an equivalent fix. It would
let the release boot while the dependency keeps its own compiled-in default -- for the entry
below, `ash` would behave as `true` when we mean `false`. That converts a loud boot failure
into a silent behavioural change, which is strictly worse.

Keep this list short. Every entry invalidates the cached build of every Mix-built Hex
package, so it is a shared rebuild cost rather than a free abstraction.
"""

HEX_COMPILE_ENV_CONFIG = [
    # Ash 3.x defaults this to `true` (`deps/ash/lib/ash/embeddable_type.ex`, also read in
    # `lib/ash/type/union.ex`); 4.x will default to `false`, and `mix ash.install` writes
    # `false` into generated config. Our config/config.exs sets `false`, so `ash` and
    # `ash_phoenix` have to be compiled knowing that or the release aborts during boot.
    "config :ash, include_embedded_source_by_default?: false",
]

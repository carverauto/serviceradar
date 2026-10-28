[
  import_deps: [
    :ash,
    :ash_postgres,
    :ash_oban,
    :ash_state_machine,
    :ash_json_api,
    :ash_paper_trail,
    :ecto,
    :ecto_sql
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Styler, Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "bench/exposure_compaction_capacity_test.exs",
    "bench/ownership_replay_spike_test.exs"
  ]
]

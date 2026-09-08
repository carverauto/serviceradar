# A dedicated helper, and NOT test/test_helper.exs.
#
# That helper excludes `:benchmark` in every one of its branches. Driving these benches through
# it would skip every test in the file and report the target as passing -- a green benchmark
# target that ran no benchmark, which is the exact defect this driver exists to catch, one level
# up. The driver therefore starts ExUnit itself, with no exclusions.
#
# Nothing here starts the application or a Repo. Both benches this drives are pure: the metric
# profile decodes protobufs off disk, and the pull/buffering bench exercises EventWriter's
# buffering logic in-process. `metric_fixture_cnpg_insert.exs` is the one that needs a database,
# and it is deliberately not driven here.
Application.ensure_all_started(:telemetry)
ExUnit.start()

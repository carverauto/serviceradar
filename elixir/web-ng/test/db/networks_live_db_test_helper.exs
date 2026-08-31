# This focused target reuses the already-provisioned serial_0 integration database after the
# core lanes finish. Keep one ExUnit case active so its application-global setup cannot overlap.
Code.require_file("../test_helper.exs", __DIR__)
ExUnit.configure(max_cases: 1)

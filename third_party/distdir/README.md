# Bazel distdir

Place pre-downloaded archives here to avoid repeated downloads during Bazel
repository fetches. Bazel will reuse files that match the archive basename.

Examples (current tooling):
- v1.19.4.tar.gz (Elixir)
- otp_src_28.1.tar.gz (Erlang/OTP)

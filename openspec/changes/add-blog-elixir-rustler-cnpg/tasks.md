## 1. Content
- [x] 1.1 Draft the blog post at `docs/blog/2025-12-16-simplifying-observability-elixir-rustler-cnpg.mdx` with frontmatter (slug/title/date/authors/tags/description).
- [x] 1.2 Cover shipped staging architecture: Phoenix LiveView UI, Rustler-based SRQL NIF, direct CNPG (Timescale + AGE) access, Go core orchestration/ingest.
- [x] 1.3 Present pg_notify-powered LiveView streaming as implemented in staging and headed for the next release.
- [x] 1.4 Add concrete examples from staging (SRQL NIF path, AGE graph readiness task, Repo usage) to make the post actionable.

## 2. Validation
- [x] 2.1 Run `openspec validate add-blog-elixir-rustler-cnpg --strict`.
- [x] 2.2 Proofread for accuracy against `origin/staging` (represent pg_notify streaming as implemented in staging and release-bound).

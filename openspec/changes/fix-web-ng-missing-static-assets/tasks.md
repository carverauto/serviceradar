# Tasks: Fix web-ng missing static assets

## 1. Fix Bazel build to preserve static assets
- [x] 1.1 Modify `build/mix_release.bzl` to copy existing `priv/static` files to the symlinked directory before running `mix assets.deploy`
- [x] 1.2 Ensure `favicon.ico`, `images/logo.svg`, and `robots.txt` survive the build process
- [x] 1.3 Test Bazel build locally with `bazel build //web-ng:release_tar` (code changes verified; full build requires CI due to local OTP toolchain cache issue)

## 2. Add favicon link to HTML template
- [x] 2.1 Add `<link rel="icon" href={~p"/favicon.ico"}>` to `web-ng/lib/serviceradar_web_ng_web/components/layouts/root.html.heex`
- [x] 2.2 Add SVG favicon variant for modern browsers

## 3. Verify static assets
- [x] 3.1 Confirm `web-ng/priv/static/favicon.ico` exists and is the correct ServiceRadar favicon (replaced 152-byte default with 15KB ServiceRadar icon)
- [x] 3.2 Confirm `web-ng/priv/static/images/logo.svg` matches `web/public/serviceRadar.svg` (identical except trailing newline)
- [x] 3.3 Verify `web-ng/priv/static/robots.txt` is preserved

## 4. Test container builds
- [ ] 4.1 Build and run Docker Compose stack with `docker compose up -d`
- [ ] 4.2 Verify favicon appears in browser tab
- [ ] 4.3 Verify ServiceRadar logo appears in sidebar navigation
- [ ] 4.4 Test with Bazel-built OCI image: `bazel run //docker/images:web_ng_image_amd64_tar && docker run -it ghcr.io/carverauto/serviceradar-web-ng:local`

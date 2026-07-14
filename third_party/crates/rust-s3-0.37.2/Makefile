# Main targets - fmt and clippy first, then tests
ci: fmt-check clippy-all test-not-ignored
test-all: fmt-check clippy-all test-all-features

# Formatting check
fmt-check:
	cargo fmt --all -- --check

# Run clippy for all feature combinations
clippy-all: tokio-clippy async-std-clippy sync-clippy

# Test targets
test-not-ignored: tokio-test-not-ignored async-std-test-not-ignored
test-all-features: async-all sync-all

# Runtime-specific test groupings
async-all: tokio async-std
sync-all: sync-nativetls sync-rustlstls sync-nossl

# Clippy targets grouped by runtime
clippy: clippy-all
tokio-clippy: tokio-nativetls-clippy tokio-nossl-clippy tokio-rustlstls-clippy
async-std-clippy: async-std-clippy-base async-std-clippy-native-tls async-std-clippy-rustls-tls
sync-clippy: sync-nativetls-clippy sync-nossl-clippy sync-rustlstls-clippy

# tokio test targets (no longer include clippy as dependency)
tokio: tokio-nativetls-test tokio-nossl-test tokio-rustlstls-test
tokio-test-not-ignored: tokio-nativetls-test-not-ignored tokio-nossl-test-not-ignored tokio-rustlstls-test-not-ignored

tokio-nativetls-test: tokio-nativetls-test-not-ignored tokio-nativetls-test-ignored tokio-nativetls-blocking-test-ignored
tokio-nativetls-clippy:
	cargo clippy -- -D warnings
tokio-nativetls-test-not-ignored:
	cargo test
tokio-nativetls-test-ignored:
	cargo test -- --ignored
tokio-nativetls-blocking-test-ignored:
	cargo test --features blocking -- --ignored

tokio-nossl-test: tokio-nossl-test-not-ignored
tokio-nossl-clippy:
	cargo clippy --no-default-features --features with-tokio --features aws-creds/http-credentials -- -D warnings
tokio-nossl-test-not-ignored:
	cargo test --no-default-features --features with-tokio --features aws-creds/http-credentials

tokio-rustlstls-test: tokio-rustlstls-test-not-ignored tokio-rustlstls-test-ignored
tokio-rustlstls-clippy:
	cargo clippy --no-default-features --features with-tokio --features tokio-rustls-tls --features aws-creds/http-credentials -- -D warnings
tokio-rustlstls-test-not-ignored:
	cargo test --no-default-features --features with-tokio --features tokio-rustls-tls --features aws-creds/http-credentials
tokio-rustlstls-test-ignored:
	cargo test --no-default-features --features with-tokio --features tokio-rustls-tls --features aws-creds/http-credentials -- --ignored

# async-std test targets
async-std: async-std-test async-std-native-tls-test async-std-rustls-tls-test
async-std-test-not-ignored: async-std-test-not-ignored-base async-std-test-not-ignored-native-tls async-std-test-not-ignored-rustls-tls
async-std-clippy-base:
	cargo clippy --no-default-features --features with-async-std-hyper --features aws-creds/http-credentials -- -D warnings
async-std-test: async-std-test-not-ignored-base async-std-test-ignored async-std-test-blocking-ignored
async-std-test-not-ignored-base:
	cargo test --no-default-features --features with-async-std-hyper --features aws-creds/http-credentials
async-std-test-ignored:
	cargo test --no-default-features --features with-async-std-hyper --features aws-creds/http-credentials -- --ignored
async-std-test-blocking-ignored:
	cargo test --no-default-features --features with-async-std-hyper --features blocking --features aws-creds/http-credentials -- --ignored

async-std-native-tls-test: async-std-test-not-ignored-native-tls async-std-test-ignored-native-tls async-std-test-blocking-ignored-native-tls
async-std-clippy-native-tls:
	cargo clippy --no-default-features --features async-std-native-tls --features aws-creds/http-credentials -- -D warnings
async-std-test-not-ignored-native-tls:
	cargo test --no-default-features --features async-std-native-tls --features aws-creds/http-credentials
async-std-test-ignored-native-tls:
	cargo test --no-default-features --features async-std-native-tls --features aws-creds/http-credentials -- --ignored
async-std-test-blocking-ignored-native-tls:
	cargo test --no-default-features --features async-std-native-tls --features blocking --features aws-creds/http-credentials -- --ignored

async-std-rustls-tls-test: async-std-test-not-ignored-rustls-tls async-std-test-ignored-rustls-tls async-std-test-blocking-ignored-rustls-tls
async-std-clippy-rustls-tls:
	cargo clippy --no-default-features --features async-std-rustls-tls --features aws-creds/http-credentials -- -D warnings
async-std-test-not-ignored-rustls-tls:
	cargo test --no-default-features --features async-std-rustls-tls --features aws-creds/http-credentials
async-std-test-ignored-rustls-tls:
	cargo test --no-default-features --features async-std-rustls-tls --features aws-creds/http-credentials -- --ignored
async-std-test-blocking-ignored-rustls-tls:
	cargo test --no-default-features --features async-std-rustls-tls --features blocking --features aws-creds/http-credentials -- --ignored




# sync test targets
sync-nativetls: sync-nativetls-test
sync-nativetls-clippy:
	cargo clippy --no-default-features --features sync --features sync-native-tls --features aws-creds/http-credentials -- -D warnings
sync-nativetls-test: sync-nativetls-test-ignored
sync-nativetls-test-ignored:
	cargo test --no-default-features --features sync --features sync-native-tls --features aws-creds/http-credentials -- --ignored

sync-rustlstls: sync-rustlstls-test
sync-rustlstls-clippy:
	cargo clippy --no-default-features --features sync --features sync-rustls-tls --features aws-creds/http-credentials -- -D warnings
sync-rustlstls-test: sync-rustlstls-test-ignored
sync-rustlstls-test-ignored:
	cargo test --no-default-features --features sync --features sync-rustls-tls --features aws-creds/http-credentials  -- --ignored

sync-nossl: sync-nossl-test
sync-nossl-clippy:
	cargo clippy --no-default-features --features sync --features aws-creds/http-credentials -- -D warnings
sync-nossl-test:
	@echo "No tests for sync-nossl configuration"

fmt:
	cargo fmt



all:
  @echo "Select target"

test:
  cargo test -F full
  clippy -F full

bump:
  cargo bump

pub:
  cargo publish

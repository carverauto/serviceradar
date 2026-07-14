// bad sync condition
#[maybe_async::test(unknown(feature="async", async_std::test))]
async fn test_async_fn() {}

fn main() {

}
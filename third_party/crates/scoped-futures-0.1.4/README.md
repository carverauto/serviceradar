# scoped-futures

A utility crate for imposing upper bounds on `Future` lifetimes. This is especially useful for callbacks that use higher-ranked lifetimes in their return type,
where it can prevent `'static` bounds from being placed on a returned `Future`.

This crate is effectively a port of Sabrina Jewson's [better alternative to lifetime GATs](https://sabrinajewson.org/blog/the-better-alternative-to-lifetime-gats)
for Futures.

## Example
```rust
use core::pin::Pin;
use scoped_futures::{ScopedBoxFuture, ScopedFutureExt};

pub struct Db {
    count: u8,
}

impl Db {
    async fn transaction<'a, F, T, E>(&mut self, callback: F) -> Result<T, E>
    where
        // ScopedBoxFuture imposes a lifetime bound on 'b which prevents the hrtb below needing
        // to be satisfied for all lifetimes (including 'static) and instead only lifetimes
        // which live at most as long as 'a
        F: for<'b /* where 'a: 'b */> FnOnce(&'b mut Self) -> ScopedBoxFuture<'a, 'b, Result<T, E>> + Send + 'a,
        T: 'a,
        E: 'a,
    {
        callback(self).await
    }
}`

pub async fn test_transaction<'a, 'b>(
    db: &mut Db,
    ok: &'a str,
    err: &'b str,
    is_ok: bool,
) -> Result<&'a str, &'b str> {
    // note the lack of `move` or any cloning in front of the closure
    db.transaction(|db| async move {
        db.count += 1;
        if is_ok {
            Ok(ok)
        } else {
            Err(err)
        }
    }.scope_boxed()).await?;

    // note that `async` can be used instead of `async move` since the callback param is unused
    db.transaction(|_| async {
        if is_ok {
            Ok(ok)
        } else {
            Err(err)
        }
    }.scope_boxed()).await
}

#[test]
fn test_transaction_works() {
    futures::executor::block_on(async {
        let mut db = Db { count: 0 };
        let ok = String::from("ok");
        let err = String::from("err");
        let result = test_transaction(&mut db, &ok, &err, true).await;
        assert_eq!(ok, result.unwrap());
        assert_eq!(1, db.count);
    })
}
```

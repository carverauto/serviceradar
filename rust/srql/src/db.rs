use crate::config::AppConfig;
use anyhow::Result;
use diesel_async::{
    pooled_connection::bb8::Pool, pooled_connection::AsyncDieselConnectionManager,
    AsyncPgConnection,
};

pub type PgPool = Pool<AsyncPgConnection>;

pub async fn connect_pool(config: &AppConfig) -> Result<PgPool> {
    let manager = AsyncDieselConnectionManager::new(&config.database_url);
    let pool = Pool::builder()
        .max_size(config.max_pool_size)
        .build(manager)
        .await
        .map_err(|err| anyhow::anyhow!(err))?;

    Ok(pool)
}

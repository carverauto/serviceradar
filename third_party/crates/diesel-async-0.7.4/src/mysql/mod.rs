use crate::stmt_cache::{CallbackHelper, QueryFragmentHelper};
use crate::{AnsiTransactionManager, AsyncConnection, AsyncConnectionCore, SimpleAsyncConnection};
use diesel::connection::statement_cache::{
    MaybeCached, QueryFragmentForCachedStatement, StatementCache,
};
use diesel::connection::StrQueryHelper;
use diesel::connection::{CacheSize, Instrumentation};
use diesel::connection::{DynInstrumentation, InstrumentationEvent};
use diesel::mysql::{Mysql, MysqlQueryBuilder, MysqlType};
use diesel::query_builder::QueryBuilder;
use diesel::query_builder::{bind_collector::RawBytesBindCollector, QueryFragment, QueryId};
use diesel::result::{ConnectionError, ConnectionResult};
use diesel::QueryResult;
use futures_core::future::BoxFuture;
use futures_core::stream::BoxStream;
use futures_core::Stream;
use futures_util::{FutureExt, StreamExt, TryStreamExt};
use mysql_async::prelude::Queryable;
use mysql_async::{Opts, OptsBuilder, Statement};
use std::future::Future;

mod cancel_token;
mod error_helper;
mod row;
mod serialize;

pub use self::cancel_token::MysqlCancelToken;
use self::error_helper::ErrorHelper;
use self::row::MysqlRow;
use self::serialize::ToSqlHelper;

/// A connection to a MySQL database. Connection URLs should be in the form
/// `mysql://[user[:password]@]host/database_name`
pub struct AsyncMysqlConnection {
    conn: mysql_async::Conn,
    stmt_cache: StatementCache<Mysql, Statement>,
    transaction_manager: AnsiTransactionManager,
    instrumentation: DynInstrumentation,
    stmt_to_free: Vec<mysql_async::Statement>,
}

impl SimpleAsyncConnection for AsyncMysqlConnection {
    async fn batch_execute(&mut self, query: &str) -> diesel::QueryResult<()> {
        self.instrumentation()
            .on_connection_event(InstrumentationEvent::start_query(&StrQueryHelper::new(
                query,
            )));
        let result = self
            .conn
            .query_drop(query)
            .await
            .map_err(ErrorHelper)
            .map_err(Into::into);
        self.instrumentation()
            .on_connection_event(InstrumentationEvent::finish_query(
                &StrQueryHelper::new(query),
                result.as_ref().err(),
            ));
        result
    }
}

const CONNECTION_SETUP_QUERIES: &[&str] = &[
    "SET time_zone = '+00:00';",
    "SET character_set_client = 'utf8mb4'",
    "SET character_set_connection = 'utf8mb4'",
    "SET character_set_results = 'utf8mb4'",
];

impl AsyncConnectionCore for AsyncMysqlConnection {
    type ExecuteFuture<'conn, 'query> = BoxFuture<'conn, QueryResult<usize>>;
    type LoadFuture<'conn, 'query> = BoxFuture<'conn, QueryResult<Self::Stream<'conn, 'query>>>;
    type Stream<'conn, 'query> = BoxStream<'conn, QueryResult<Self::Row<'conn, 'query>>>;
    type Row<'conn, 'query> = MysqlRow;
    type Backend = Mysql;

    fn load<'conn, 'query, T>(&'conn mut self, source: T) -> Self::LoadFuture<'conn, 'query>
    where
        T: diesel::query_builder::AsQuery,
        T::Query: diesel::query_builder::QueryFragment<Self::Backend>
            + diesel::query_builder::QueryId
            + 'query,
    {
        self.with_prepared_statement(source.as_query(), |conn, stmt, binds| async move {
            Ok(Self::poll_result_stream(conn, stmt, binds).await?.boxed())
        })
        .boxed()
    }

    fn execute_returning_count<'conn, 'query, T>(
        &'conn mut self,
        source: T,
    ) -> Self::ExecuteFuture<'conn, 'query>
    where
        T: diesel::query_builder::QueryFragment<Self::Backend>
            + diesel::query_builder::QueryId
            + 'query,
    {
        self.with_prepared_statement(source, |conn, stmt, binds| async move {
            let params = mysql_async::Params::try_from(binds)?;
            conn.exec_drop(&*stmt, params).await.map_err(ErrorHelper)?;
            conn.affected_rows()
                .try_into()
                .map_err(|e| diesel::result::Error::DeserializationError(Box::new(e)))
        })
    }
}

impl AsyncConnection for AsyncMysqlConnection {
    type TransactionManager = AnsiTransactionManager;

    async fn establish(database_url: &str) -> diesel::ConnectionResult<Self> {
        let mut instrumentation = DynInstrumentation::default_instrumentation();
        instrumentation.on_connection_event(InstrumentationEvent::start_establish_connection(
            database_url,
        ));
        let r = Self::establish_connection_inner(database_url).await;
        instrumentation.on_connection_event(InstrumentationEvent::finish_establish_connection(
            database_url,
            r.as_ref().err(),
        ));
        let mut conn = r?;
        conn.instrumentation = instrumentation;
        Ok(conn)
    }

    fn transaction_state(&mut self) -> &mut AnsiTransactionManager {
        &mut self.transaction_manager
    }

    fn instrumentation(&mut self) -> &mut dyn Instrumentation {
        &mut *self.instrumentation
    }

    fn set_instrumentation(&mut self, instrumentation: impl Instrumentation) {
        self.instrumentation = instrumentation.into();
    }

    fn set_prepared_statement_cache_size(&mut self, size: CacheSize) {
        self.stmt_cache.set_cache_size(size);
    }
}

#[inline(always)]
fn update_transaction_manager_status<T>(
    query_result: QueryResult<T>,
    transaction_manager: &mut AnsiTransactionManager,
) -> QueryResult<T> {
    if let Err(diesel::result::Error::DatabaseError(
        diesel::result::DatabaseErrorKind::SerializationFailure,
        _,
    )) = query_result
    {
        transaction_manager
            .status
            .set_requires_rollback_maybe_up_to_top_level(true)
    }
    query_result
}

fn prepare_statement_helper<'a>(
    conn: &'a mut mysql_async::Conn,
    sql: &str,
    _is_for_cache: diesel::connection::statement_cache::PrepareForCache,
    _metadata: &[MysqlType],
) -> CallbackHelper<impl Future<Output = QueryResult<(Statement, &'a mut mysql_async::Conn)>> + Send>
{
    // ideally we wouldn't clone the SQL string here
    // but as we usually cache statements anyway
    // this is a fixed one time const
    //
    // The probleme with not cloning it is that we then cannot express
    // the right result lifetime anymore (at least not easily)
    let sql = sql.to_owned();
    CallbackHelper(async move {
        let s = conn.prep(sql).await.map_err(ErrorHelper)?;
        Ok((s, conn))
    })
}

impl AsyncMysqlConnection {
    /// Wrap an existing [`mysql_async::Conn`] into a async diesel mysql connection
    ///
    /// This function constructs a new `AsyncMysqlConnection` based on an existing
    /// [`mysql_async::Conn]`.
    pub async fn try_from(conn: mysql_async::Conn) -> ConnectionResult<Self> {
        use crate::run_query_dsl::RunQueryDsl;
        let mut conn = AsyncMysqlConnection {
            conn,
            stmt_cache: StatementCache::new(),
            transaction_manager: AnsiTransactionManager::default(),
            instrumentation: DynInstrumentation::default_instrumentation(),
            stmt_to_free: Vec::new(),
        };

        for stmt in CONNECTION_SETUP_QUERIES {
            diesel::sql_query(*stmt)
                .execute(&mut conn)
                .await
                .map_err(ConnectionError::CouldntSetupConfiguration)?;
        }

        Ok(conn)
    }

    /// Constructs a cancellation token that can later be used to request cancellation of a query running on the connection associated with this client.
    pub fn cancel_token(&self) -> MysqlCancelToken {
        let kill_id = self.conn.id();
        let opts = self.conn.opts().clone();

        MysqlCancelToken { kill_id, opts }
    }

    fn with_prepared_statement<'conn, T, F, R>(
        &'conn mut self,
        query: T,
        callback: impl (FnOnce(&'conn mut mysql_async::Conn, MaybeCached<'conn, Statement>, ToSqlHelper) -> F)
            + Send
            + 'conn,
    ) -> BoxFuture<'conn, QueryResult<R>>
    where
        R: Send + 'conn,
        T: QueryFragment<Mysql> + QueryId,
        F: Future<Output = QueryResult<R>> + Send,
    {
        self.instrumentation()
            .on_connection_event(InstrumentationEvent::start_query(&diesel::debug_query(
                &query,
            )));
        let mut bind_collector = RawBytesBindCollector::<Mysql>::new();
        let bind_collector = query
            .collect_binds(&mut bind_collector, &mut (), &Mysql)
            .map(|()| bind_collector);

        let AsyncMysqlConnection {
            ref mut conn,
            ref mut stmt_cache,
            ref mut transaction_manager,
            ref mut instrumentation,
            ref mut stmt_to_free,
            ..
        } = self;

        let is_safe_to_cache_prepared = query.is_safe_to_cache_prepared(&Mysql);
        let mut qb = MysqlQueryBuilder::new();
        let sql = query.to_sql(&mut qb, &Mysql).map(|()| qb.finish());
        let query_id = T::query_id();

        async move {
            // We need to close any non-cached statement explicitly here as otherwise
            // we might error out on too many open statements. See https://github.com/weiznich/diesel_async/issues/26
            // and https://github.com/weiznich/diesel_async/issues/269 for details
            //
            // We remember these statements from the last run as there is currenly no relaible way to
            // run this as destruction step after the execution finished. Users might abort polling the future, etc
            //
            // The overhead for this is keeping one additional statement open until the connection is used
            // next, so you would need to have `max_prepared_stmt_count - 1` other statements open for this to cause issues.
            // This is hopefully not a problem in practice
            for stmt in std::mem::take(stmt_to_free) {
                conn.close(stmt).await.map_err(ErrorHelper)?;
            }
            let RawBytesBindCollector {
                metadata, binds, ..
            } = bind_collector?;
            let is_safe_to_cache_prepared = is_safe_to_cache_prepared?;
            let sql = sql?;
            let helper = QueryFragmentHelper {
                sql,
                safe_to_cache: is_safe_to_cache_prepared,
            };
            let inner = async {
                let (stmt, conn) = stmt_cache
                    .cached_statement_non_generic(
                        query_id,
                        &helper,
                        &Mysql,
                        &metadata,
                        conn,
                        prepare_statement_helper,
                        &mut **instrumentation,
                    )
                    .await?;
                // for any not cached statement we need to remember to close them on the next connection usage
                if let MaybeCached::CannotCache(stmt) = &stmt {
                    stmt_to_free.push(stmt.clone());
                }
                callback(conn, stmt, ToSqlHelper { metadata, binds }).await
            };
            let r = update_transaction_manager_status(inner.await, transaction_manager);
            instrumentation.on_connection_event(InstrumentationEvent::finish_query(
                &StrQueryHelper::new(&helper.sql),
                r.as_ref().err(),
            ));
            r
        }
        .boxed()
    }

    async fn poll_result_stream<'conn>(
        conn: &'conn mut mysql_async::Conn,
        stmt: MaybeCached<'_, mysql_async::Statement>,
        binds: ToSqlHelper,
    ) -> QueryResult<impl Stream<Item = QueryResult<MysqlRow>> + Send + use<'conn>> {
        let params = mysql_async::Params::try_from(binds)?;
        let stmt_for_exec = match stmt {
                MaybeCached::Cached(ref s) => {
                    (*s).clone()
                },
                MaybeCached::CannotCache(ref s) => {
                    s.clone()
                },
                _ => unreachable!(
                    "Diesel has only two variants here at the time of writing.\n\
                     If you ever see this error message please open in issue in the diesel-async issue tracker"
                ),
            };

        let res = conn
            .exec_iter(stmt_for_exec, params)
            .await
            .map_err(ErrorHelper)?;

        let stream = res
            .stream_and_drop::<MysqlRow>()
            .await
            .map_err(ErrorHelper)?
            .ok_or_else(|| {
                diesel::result::Error::DeserializationError(Box::new(
                    diesel::result::UnexpectedEndOfRow,
                ))
            })?
            .map_err(|e| diesel::result::Error::from(ErrorHelper(e)));

        Ok(stream)
    }

    async fn establish_connection_inner(
        database_url: &str,
    ) -> Result<AsyncMysqlConnection, ConnectionError> {
        let opts = Opts::from_url(database_url)
            .map_err(|e| diesel::result::ConnectionError::InvalidConnectionUrl(e.to_string()))?;
        let builder = OptsBuilder::from_opts(opts)
            .init(CONNECTION_SETUP_QUERIES.to_vec())
            .stmt_cache_size(0) // We have our own cache
            .client_found_rows(true); // This allows a consistent behavior between MariaDB/MySQL and PostgreSQL (and is already set in `diesel`)

        let conn = mysql_async::Conn::new(builder).await.map_err(ErrorHelper)?;

        Ok(AsyncMysqlConnection {
            conn,
            stmt_cache: StatementCache::new(),
            transaction_manager: AnsiTransactionManager::default(),
            instrumentation: DynInstrumentation::none(),
            stmt_to_free: Vec::new(),
        })
    }
}

#[cfg(any(
    feature = "deadpool",
    feature = "bb8",
    feature = "mobc",
    feature = "r2d2"
))]
impl crate::pooled_connection::PoolableConnection for AsyncMysqlConnection {}

#[cfg(test)]
mod tests {
    use crate::RunQueryDsl;
    mod diesel_async {
        pub use crate::*;
    }
    include!("../doctest_setup.rs");

    const STMT_COUNT: usize = 16382 + 1000;

    #[derive(Queryable)]
    #[expect(dead_code, reason = "used for the test as loading target")]
    struct User {
        id: i32,
        name: String,
    }

    #[tokio::test]
    async fn check_cached_statements_are_dropped() {
        use self::schema::users;

        let mut conn = establish_connection().await;

        for _i in 0..STMT_COUNT {
            users::table
                .select(users::id)
                .load::<i32>(&mut conn)
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn check_uncached_statements_are_dropped() {
        use self::schema::users;

        let mut conn = establish_connection().await;

        for _i in 0..STMT_COUNT {
            users::table
                .filter(users::dsl::id.eq_any(&[1, 2]))
                .load::<User>(&mut conn)
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn check_cached_statements_are_dropped_get_result() {
        use self::schema::users;
        use diesel::OptionalExtension;

        let mut conn = establish_connection().await;

        for _i in 0..STMT_COUNT {
            users::table
                .select(users::id)
                .get_result::<i32>(&mut conn)
                .await
                .optional()
                .unwrap();
        }
    }

    #[tokio::test]
    async fn check_uncached_statements_are_dropped_get_result() {
        use self::schema::users;
        use diesel::OptionalExtension;

        let mut conn = establish_connection().await;

        for _i in 0..STMT_COUNT {
            users::table
                .filter(users::dsl::id.eq_any(&[1, 2]))
                .get_result::<User>(&mut conn)
                .await
                .optional()
                .unwrap();
        }
    }
}

impl QueryFragmentForCachedStatement<Mysql> for QueryFragmentHelper {
    fn construct_sql(&self, _backend: &Mysql) -> QueryResult<String> {
        Ok(self.sql.clone())
    }

    fn is_safe_to_cache_prepared(&self, _backend: &Mysql) -> QueryResult<bool> {
        Ok(self.safe_to_cache)
    }
}

use diesel::{result::DatabaseErrorKind, ConnectionError};
use mysql_async::Error;

pub(super) struct ErrorHelper(pub(super) Error);

impl From<ErrorHelper> for diesel::result::Error {
    fn from(ErrorHelper(e): ErrorHelper) -> Self {
        match e {
            Error::Server(e) => {
                let kind = match e.code {
                    1062 | 1586 | 1859 => DatabaseErrorKind::UniqueViolation,
                    1216 | 1217 | 1451 | 1452 | 1830 | 1834 => {
                        DatabaseErrorKind::ForeignKeyViolation
                    }
                    1792 => DatabaseErrorKind::ReadOnlyTransaction,
                    1048 | 1364 => DatabaseErrorKind::NotNullViolation,
                    3819 => DatabaseErrorKind::CheckViolation,
                    _ => DatabaseErrorKind::Unknown,
                };
                diesel::result::Error::DatabaseError(kind, Box::new(e.message) as _)
            }
            e => diesel::result::Error::DatabaseError(
                DatabaseErrorKind::Unknown,
                Box::new(e.to_string()) as _,
            ),
        }
    }
}

impl From<ErrorHelper> for diesel::result::ConnectionError {
    fn from(ErrorHelper(e): ErrorHelper) -> Self {
        match e {
            Error::Driver(e) => ConnectionError::BadConnection(e.to_string()),
            Error::Io(e) => ConnectionError::BadConnection(e.to_string()),
            Error::Other(e) => ConnectionError::BadConnection(e.to_string()),
            Error::Server(_) => ConnectionError::CouldntSetupConfiguration(ErrorHelper(e).into()),
            Error::Url(e) => ConnectionError::InvalidConnectionUrl(e.to_string()),
        }
    }
}

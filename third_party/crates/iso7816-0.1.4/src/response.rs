pub mod status;
pub use status::Status;

use crate::Data;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Response<const S: usize> {
    Data(Data<S>),
    Status(Status),
}

impl<const S: usize> Default for Response<S> {
    fn default() -> Self {
        Self::Status(Default::default())
    }
}

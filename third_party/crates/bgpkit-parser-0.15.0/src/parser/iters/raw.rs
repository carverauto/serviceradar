/*!
The RawMrtRecord Iterator module provides functionality for iterating over raw MRT records
from a BGP data source. This iterator is responsible for:

* Reading and parsing raw MRT records sequentially from an input stream
* Handling parsing errors and warnings appropriately
* Providing a clean interface for processing MRT records one at a time

The iterator implements error recovery strategies, allowing it to skip malformed records
when possible and continue processing the remaining data. It also supports configurable
warning messages and core dump generation for debugging purposes.
*/

use crate::{chunk_mrt_record, BgpkitParser, ParserError, RawMrtRecord};
use log::{error, warn};
use std::io::Read;

pub struct RawRecordIterator<R> {
    parser: BgpkitParser<R>,
    count: u64,
}

impl<R> RawRecordIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        RawRecordIterator { parser, count: 0 }
    }
}

impl<R: Read> Iterator for RawRecordIterator<R> {
    type Item = RawMrtRecord;

    fn next(&mut self) -> Option<RawMrtRecord> {
        self.count += 1;
        match chunk_mrt_record(&mut self.parser.reader) {
            Ok(raw_record) => Some(raw_record),
            Err(e) => {
                match e.error {
                    ParserError::TruncatedMsg(err_str) | ParserError::Unsupported(err_str) => {
                        if self.parser.options.show_warnings {
                            warn!("parser warn: {}", err_str);
                        }
                        if let Some(bytes) = e.bytes {
                            std::fs::write("mrt_core_dump", bytes)
                                .expect("Unable to write to mrt_core_dump");
                        }
                        // skip this record and try next
                        self.next()
                    }
                    ParserError::ParseError(err_str) => {
                        error!("parser error: {}", err_str);
                        if self.parser.core_dump {
                            if let Some(bytes) = e.bytes {
                                std::fs::write("mrt_core_dump", bytes)
                                    .expect("Unable to write to mrt_core_dump");
                            }
                            None
                        } else {
                            // skip this record and try next
                            self.next()
                        }
                    }
                    ParserError::EofExpected => {
                        // normal end of file
                        None
                    }
                    ParserError::IoError(err) | ParserError::EofError(err) => {
                        // when reaching IO error, stop iterating
                        error!("{:?}", err);
                        if self.parser.core_dump {
                            if let Some(bytes) = e.bytes {
                                std::fs::write("mrt_core_dump", bytes)
                                    .expect("Unable to write to mrt_core_dump");
                            }
                        }
                        None
                    }
                    #[cfg(feature = "oneio")]
                    ParserError::OneIoError(_) => None,
                    ParserError::FilterError(_) => {
                        // this should not happen at this stage
                        None
                    }
                }
            }
        }
    }
}

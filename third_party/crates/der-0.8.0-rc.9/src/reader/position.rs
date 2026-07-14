//! Position tracking for processing nested input messages using only the stack.

use crate::{Error, ErrorKind, Length, Result};

/// State tracker for the current position in the input.
#[derive(Clone, Debug)]
pub(super) struct Position {
    /// Input length (in bytes after Base64 decoding).
    input_len: Length,

    /// Position in the input buffer (in bytes after Base64 decoding).
    position: Length,
}

impl Position {
    /// Create a new position tracker with the given overall length.
    pub(super) fn new(input_len: Length) -> Self {
        Self {
            input_len,
            position: Length::ZERO,
        }
    }

    /// Get the input length.
    pub(super) fn input_len(&self) -> Length {
        self.input_len
    }

    /// Get the current position.
    pub(super) fn current(&self) -> Length {
        self.position
    }

    /// Advance the current position by the given amount.
    ///
    /// # Returns
    ///
    /// The new current position.
    pub(super) fn advance(&mut self, amount: Length) -> Result<Length> {
        let new_position = (self.position + amount)?;

        if new_position > self.input_len {
            return Err(ErrorKind::Incomplete {
                expected_len: new_position,
                actual_len: self.input_len,
            }
            .at(self.position));
        }

        self.position = new_position;
        Ok(new_position)
    }

    /// Split a nested position tracker of the given size.
    ///
    /// # Returns
    ///
    /// A [`Resumption`] value which can be used to continue parsing the outer message.
    pub(super) fn split_nested(&mut self, len: Length) -> Result<Resumption> {
        let nested_input_len = (self.position + len)?;

        if nested_input_len > self.input_len {
            return Err(Error::incomplete(self.input_len));
        }

        let resumption = Resumption {
            input_len: self.input_len,
        };
        self.input_len = nested_input_len;
        Ok(resumption)
    }

    /// Resume processing the rest of a message after processing a nested inner portion.
    pub(super) fn resume_nested(&mut self, resumption: Resumption) {
        self.input_len = resumption.input_len;
    }
}

/// Resumption state needed to continue processing a message after handling a nested inner portion.
#[derive(Debug)]
pub(super) struct Resumption {
    /// Outer input length.
    input_len: Length,
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::Position;
    use crate::{ErrorKind, Length};

    const EXAMPLE_LEN: Length = match Length::new_usize(42) {
        Ok(len) => len,
        Err(_) => panic!("invalid example len"),
    };

    #[test]
    fn initial_state() {
        let pos = Position::new(EXAMPLE_LEN);
        assert_eq!(pos.input_len(), EXAMPLE_LEN);
        assert_eq!(pos.current(), Length::ZERO);
    }

    #[test]
    fn advance() {
        let mut pos = Position::new(EXAMPLE_LEN);

        // advance 1 byte: success
        let new_pos = pos.advance(Length::ONE).unwrap();
        assert_eq!(new_pos, Length::ONE);
        assert_eq!(pos.current(), Length::ONE);

        // advance to end: success
        let end_pos = pos.advance((EXAMPLE_LEN - Length::ONE).unwrap()).unwrap();
        assert_eq!(end_pos, EXAMPLE_LEN);
        assert_eq!(pos.current(), EXAMPLE_LEN);

        // advance one byte past end: error
        let err = pos.advance(Length::ONE).unwrap_err();
        assert!(matches!(err.kind(), ErrorKind::Incomplete { .. }));
    }

    #[test]
    fn nested() {
        let mut pos = Position::new(EXAMPLE_LEN);

        // split first byte
        let resumption = pos.split_nested(Length::ONE).unwrap();
        assert_eq!(pos.current(), Length::ZERO);
        assert_eq!(pos.input_len(), Length::ONE);

        // advance one byte
        assert_eq!(pos.advance(Length::ONE).unwrap(), Length::ONE);

        // can't advance two bytes
        let err = pos.advance(Length::ONE).unwrap_err();
        assert!(matches!(err.kind(), ErrorKind::Incomplete { .. }));

        // resume processing the rest of the message
        // TODO(tarcieri): should we fail here if we previously failed reading a nested message?
        pos.resume_nested(resumption);

        assert_eq!(pos.current(), Length::ONE);
        assert_eq!(pos.input_len(), EXAMPLE_LEN);

        // try to split one byte past end: error
        let err = pos.split_nested(EXAMPLE_LEN).unwrap_err();
        assert!(matches!(err.kind(), ErrorKind::Incomplete { .. }));
    }
}

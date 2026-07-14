use super::FlowSpecError;

/// Numeric operator for Flow-Spec components (RFC 8955 Section 4.2.1)
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct NumericOperator {
    /// End-of-list flag (bit 7)
    pub end_of_list: bool,
    /// AND flag - true=AND with next, false=OR with next (bit 6)
    pub and_with_next: bool,
    /// Value length in octets (bits 5-4): 00=1, 01=2, 10=4, 11=8
    pub value_length: u8,
    /// Less-than comparison (bit 2)
    pub less_than: bool,
    /// Greater-than comparison (bit 1)
    pub greater_than: bool,
    /// Equal comparison (bit 0)
    pub equal: bool,
    /// The comparison value
    pub value: u64,
}

/// Bitmask operator for Flow-Spec components (RFC 8955 Section 4.2.2)
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BitmaskOperator {
    /// End-of-list flag (bit 7)
    pub end_of_list: bool,
    /// AND flag - true=AND with next, false=OR with next (bit 6)
    pub and_with_next: bool,
    /// Value length in octets (bits 5-4): 00=1, 01=2, 10=4, 11=8
    pub value_length: u8,
    /// NOT flag - logical negation (bit 1)
    pub not: bool,
    /// Match flag - true=partial match, false=exact match (bit 0)
    pub match_flag: bool,
    /// The bitmask value
    pub bitmask: u64,
}

impl NumericOperator {
    /// Create a new numeric operator from raw byte and value
    pub fn from_byte_and_value(operator_byte: u8, value: u64) -> Result<Self, FlowSpecError> {
        let value_length = match (operator_byte >> 4) & 0x03 {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            _ => return Err(FlowSpecError::InvalidOperator(operator_byte)),
        };

        // Bit 3 must be 0 for numeric operators
        if (operator_byte & 0x08) != 0 {
            return Err(FlowSpecError::InvalidOperator(operator_byte));
        }

        Ok(NumericOperator {
            end_of_list: (operator_byte & 0x80) != 0,
            and_with_next: (operator_byte & 0x40) != 0,
            value_length,
            less_than: (operator_byte & 0x04) != 0,
            greater_than: (operator_byte & 0x02) != 0,
            equal: (operator_byte & 0x01) != 0,
            value,
        })
    }

    /// Convert to byte representation
    pub fn to_byte(&self) -> u8 {
        let mut byte = 0u8;

        if self.end_of_list {
            byte |= 0x80;
        }
        if self.and_with_next {
            byte |= 0x40;
        }

        // Encode length
        let len_bits = match self.value_length {
            1 => 0x00,
            2 => 0x10,
            4 => 0x20,
            8 => 0x30,
            _ => 0x00, // Default to 1 byte
        };
        byte |= len_bits;

        // Bit 3 is reserved (0)

        if self.less_than {
            byte |= 0x04;
        }
        if self.greater_than {
            byte |= 0x02;
        }
        if self.equal {
            byte |= 0x01;
        }

        byte
    }

    /// Create equality operator
    pub fn equal_to(value: u64) -> Self {
        let value_length = if value <= 0xFF {
            1
        } else if value <= 0xFFFF {
            2
        } else if value <= 0xFFFFFFFF {
            4
        } else {
            8
        };

        NumericOperator {
            end_of_list: true,
            and_with_next: false,
            value_length,
            less_than: false,
            greater_than: false,
            equal: true,
            value,
        }
    }

    /// Create range operator (greater than or equal)
    pub fn greater_than_or_equal(value: u64) -> Self {
        let value_length = if value <= 0xFF {
            1
        } else if value <= 0xFFFF {
            2
        } else if value <= 0xFFFFFFFF {
            4
        } else {
            8
        };

        NumericOperator {
            end_of_list: true,
            and_with_next: false,
            value_length,
            less_than: false,
            greater_than: true,
            equal: true,
            value,
        }
    }
}

impl BitmaskOperator {
    /// Create a new bitmask operator from raw byte and value
    pub fn from_byte_and_value(operator_byte: u8, bitmask: u64) -> Result<Self, FlowSpecError> {
        let value_length = match (operator_byte >> 4) & 0x03 {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            _ => return Err(FlowSpecError::InvalidOperator(operator_byte)),
        };

        // Bits 3 and 2 must be 0 for bitmask operators
        if (operator_byte & 0x0C) != 0 {
            return Err(FlowSpecError::InvalidOperator(operator_byte));
        }

        Ok(BitmaskOperator {
            end_of_list: (operator_byte & 0x80) != 0,
            and_with_next: (operator_byte & 0x40) != 0,
            value_length,
            not: (operator_byte & 0x02) != 0,
            match_flag: (operator_byte & 0x01) != 0,
            bitmask,
        })
    }

    /// Convert to byte representation
    pub fn to_byte(&self) -> u8 {
        let mut byte = 0u8;

        if self.end_of_list {
            byte |= 0x80;
        }
        if self.and_with_next {
            byte |= 0x40;
        }

        // Encode length
        let len_bits = match self.value_length {
            1 => 0x00,
            2 => 0x10,
            4 => 0x20,
            8 => 0x30,
            _ => 0x00, // Default to 1 byte
        };
        byte |= len_bits;

        // Bits 3 and 2 are reserved (0)

        if self.not {
            byte |= 0x02;
        }
        if self.match_flag {
            byte |= 0x01;
        }

        byte
    }

    /// Create exact match operator
    pub fn exact_match(bitmask: u64) -> Self {
        let value_length = if bitmask <= 0xFF {
            1
        } else if bitmask <= 0xFFFF {
            2
        } else if bitmask <= 0xFFFFFFFF {
            4
        } else {
            8
        };

        BitmaskOperator {
            end_of_list: true,
            and_with_next: false,
            value_length,
            not: false,
            match_flag: false,
            bitmask,
        }
    }

    /// Create partial match operator
    pub fn partial_match(bitmask: u64) -> Self {
        let value_length = if bitmask <= 0xFF {
            1
        } else if bitmask <= 0xFFFF {
            2
        } else if bitmask <= 0xFFFFFFFF {
            4
        } else {
            8
        };

        BitmaskOperator {
            end_of_list: true,
            and_with_next: false,
            value_length,
            not: false,
            match_flag: true,
            bitmask,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_numeric_operator_creation() {
        let op = NumericOperator::equal_to(25);
        assert!(op.equal);
        assert!(!op.less_than);
        assert!(!op.greater_than);
        assert_eq!(op.value, 25);
        assert_eq!(op.value_length, 1);
    }

    #[test]
    fn test_numeric_operator_byte_conversion() {
        let op = NumericOperator {
            end_of_list: true,
            and_with_next: false,
            value_length: 1,
            less_than: false,
            greater_than: false,
            equal: true,
            value: 25,
        };

        let byte = op.to_byte();
        assert_eq!(byte, 0x81); // 10000001: end_of_list=1, len=00, eq=1

        let parsed_op = NumericOperator::from_byte_and_value(byte, 25).unwrap();
        assert_eq!(parsed_op.end_of_list, op.end_of_list);
        assert_eq!(parsed_op.equal, op.equal);
        assert_eq!(parsed_op.value, op.value);
    }

    #[test]
    fn test_bitmask_operator_creation() {
        let op = BitmaskOperator::exact_match(0x06); // TCP SYN+FIN flags
        assert!(!op.match_flag);
        assert!(!op.not);
        assert_eq!(op.bitmask, 0x06);
        assert_eq!(op.value_length, 1);
    }

    #[test]
    fn test_invalid_operator_byte() {
        // Bit 3 should be 0 for numeric operators
        let result = NumericOperator::from_byte_and_value(0x08, 25);
        assert!(matches!(result, Err(FlowSpecError::InvalidOperator(0x08))));

        // Bits 3 and 2 should be 0 for bitmask operators
        let result = BitmaskOperator::from_byte_and_value(0x0C, 25);
        assert!(matches!(result, Err(FlowSpecError::InvalidOperator(0x0C))));
    }

    #[test]
    fn test_numeric_operator_various_lengths() {
        // Test 1-byte value
        let op1 = NumericOperator::equal_to(255);
        assert_eq!(op1.value_length, 1);
        assert_eq!(op1.value, 255);

        // Test 2-byte value
        let op2 = NumericOperator::equal_to(256);
        assert_eq!(op2.value_length, 2);
        assert_eq!(op2.value, 256);

        // Test 4-byte value
        let op4 = NumericOperator::equal_to(0x10000);
        assert_eq!(op4.value_length, 4);
        assert_eq!(op4.value, 0x10000);

        // Test 8-byte value
        let op8 = NumericOperator::equal_to(0x100000000);
        assert_eq!(op8.value_length, 8);
        assert_eq!(op8.value, 0x100000000);
    }

    #[test]
    fn test_bitmask_operator_various_lengths() {
        // Test 1-byte value
        let op1 = BitmaskOperator::exact_match(255);
        assert_eq!(op1.value_length, 1);
        assert_eq!(op1.bitmask, 255);

        // Test 2-byte value
        let op2 = BitmaskOperator::exact_match(256);
        assert_eq!(op2.value_length, 2);
        assert_eq!(op2.bitmask, 256);

        // Test 4-byte value
        let op4 = BitmaskOperator::exact_match(0x10000);
        assert_eq!(op4.value_length, 4);
        assert_eq!(op4.bitmask, 0x10000);

        // Test 8-byte value
        let op8 = BitmaskOperator::exact_match(0x100000000);
        assert_eq!(op8.value_length, 8);
        assert_eq!(op8.bitmask, 0x100000000);
    }

    #[test]
    fn test_numeric_operator_greater_than_or_equal() {
        let op = NumericOperator::greater_than_or_equal(1000);
        assert!(op.greater_than);
        assert!(op.equal);
        assert!(!op.less_than);
        assert!(op.end_of_list);
        assert!(!op.and_with_next);
        assert_eq!(op.value, 1000);
        assert_eq!(op.value_length, 2);
    }

    #[test]
    fn test_bitmask_operator_partial_match() {
        let op = BitmaskOperator::partial_match(0x06);
        assert!(op.match_flag);
        assert!(!op.not);
        assert!(op.end_of_list);
        assert!(!op.and_with_next);
        assert_eq!(op.bitmask, 0x06);
        assert_eq!(op.value_length, 1);
    }

    #[test]
    fn test_numeric_operator_complex_byte_encoding() {
        // Test complex operator: not end of list, AND with next, 2-byte length, less than + equal
        let op = NumericOperator {
            end_of_list: false,
            and_with_next: true,
            value_length: 2,
            less_than: true,
            greater_than: false,
            equal: true,
            value: 443,
        };

        let byte = op.to_byte();
        // Expected: 0101 0101 = 0x55 (not_end=0, and=1, len=01, reserved=0, lt=1, gt=0, eq=1)
        assert_eq!(byte, 0x55);

        let parsed_op = NumericOperator::from_byte_and_value(byte, 443).unwrap();
        assert_eq!(parsed_op.end_of_list, op.end_of_list);
        assert_eq!(parsed_op.and_with_next, op.and_with_next);
        assert_eq!(parsed_op.value_length, op.value_length);
        assert_eq!(parsed_op.less_than, op.less_than);
        assert_eq!(parsed_op.greater_than, op.greater_than);
        assert_eq!(parsed_op.equal, op.equal);
        assert_eq!(parsed_op.value, op.value);
    }

    #[test]
    fn test_bitmask_operator_complex_byte_encoding() {
        // Test complex operator: not end of list, AND with next, 4-byte length, NOT, partial match
        let op = BitmaskOperator {
            end_of_list: false,
            and_with_next: true,
            value_length: 4,
            not: true,
            match_flag: true,
            bitmask: 0xFF000000,
        };

        let byte = op.to_byte();
        // Expected: 0110 0011 = 0x63 (not_end=0, and=1, len=10, reserved=00, not=1, match=1)
        assert_eq!(byte, 0x63);

        let parsed_op = BitmaskOperator::from_byte_and_value(byte, 0xFF000000).unwrap();
        assert_eq!(parsed_op.end_of_list, op.end_of_list);
        assert_eq!(parsed_op.and_with_next, op.and_with_next);
        assert_eq!(parsed_op.value_length, op.value_length);
        assert_eq!(parsed_op.not, op.not);
        assert_eq!(parsed_op.match_flag, op.match_flag);
        assert_eq!(parsed_op.bitmask, op.bitmask);
    }

    #[test]
    fn test_operator_invalid_length_defaults() {
        // Test that invalid value lengths default to 1 byte in to_byte()
        let mut op = NumericOperator::equal_to(25);
        op.value_length = 7; // Invalid length
        let byte = op.to_byte();
        // Should default to 1-byte encoding (len bits = 00)
        assert_eq!(byte & 0x30, 0x00);

        let mut bm_op = BitmaskOperator::exact_match(25);
        bm_op.value_length = 9; // Invalid length
        let byte = bm_op.to_byte();
        // Should default to 1-byte encoding (len bits = 00)
        assert_eq!(byte & 0x30, 0x00);
    }

    #[test]
    fn test_numeric_operator_all_comparison_flags() {
        // Test operator with all comparison flags set
        let op = NumericOperator {
            end_of_list: true,
            and_with_next: false,
            value_length: 1,
            less_than: true,
            greater_than: true,
            equal: true,
            value: 100,
        };

        let byte = op.to_byte();
        assert_eq!(byte, 0x87); // 10000111: end=1, len=00, lt=1, gt=1, eq=1

        let parsed_op = NumericOperator::from_byte_and_value(byte, 100).unwrap();
        assert!(parsed_op.less_than);
        assert!(parsed_op.greater_than);
        assert!(parsed_op.equal);
    }

    #[test]
    fn test_bitmask_operator_edge_cases() {
        // Test various combinations of NOT and match flags
        let op_not_exact = BitmaskOperator {
            end_of_list: true,
            and_with_next: false,
            value_length: 1,
            not: true,
            match_flag: false,
            bitmask: 0x42,
        };

        let byte = op_not_exact.to_byte();
        assert_eq!(byte, 0x82); // 10000010: end=1, len=00, not=1, match=0

        let parsed_op = BitmaskOperator::from_byte_and_value(byte, 0x42).unwrap();
        assert!(parsed_op.not);
        assert!(!parsed_op.match_flag);
    }

    #[test]
    fn test_operator_length_encoding_all_values() {
        // Test all valid length encodings for numeric operators
        for (expected_len, len_bits) in [(1, 0x00), (2, 0x10), (4, 0x20), (8, 0x30)] {
            let op = NumericOperator {
                end_of_list: true,
                and_with_next: false,
                value_length: expected_len,
                less_than: false,
                greater_than: false,
                equal: true,
                value: 42,
            };

            let byte = op.to_byte();
            assert_eq!(byte & 0x30, len_bits);

            let parsed_op = NumericOperator::from_byte_and_value(byte, 42).unwrap();
            assert_eq!(parsed_op.value_length, expected_len);
        }

        // Test all valid length encodings for bitmask operators
        for (expected_len, len_bits) in [(1, 0x00), (2, 0x10), (4, 0x20), (8, 0x30)] {
            let op = BitmaskOperator {
                end_of_list: true,
                and_with_next: false,
                value_length: expected_len,
                not: false,
                match_flag: true,
                bitmask: 42,
            };

            let byte = op.to_byte();
            assert_eq!(byte & 0x30, len_bits);

            let parsed_op = BitmaskOperator::from_byte_and_value(byte, 42).unwrap();
            assert_eq!(parsed_op.value_length, expected_len);
        }
    }
}

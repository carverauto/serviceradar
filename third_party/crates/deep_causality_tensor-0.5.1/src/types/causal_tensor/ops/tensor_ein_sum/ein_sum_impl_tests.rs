/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// The implementation is all module private thus tests can only be within the same module.

mod tests {
    #![allow(unused_imports)]
    use crate::*;

    #[test]
    fn test_get_binary_operands_success() {
        let lhs_tensor = utils_tests::scalar_tensor(1.0);
        let rhs_tensor = utils_tests::scalar_tensor(2.0);
        let lhs_ast = EinSumOp::tensor_source(lhs_tensor.clone());
        let rhs_ast = EinSumOp::tensor_source(rhs_tensor.clone());
        let children = vec![lhs_ast, rhs_ast];

        let (res_lhs, res_rhs) = CausalTensor::get_binary_operands(&children).unwrap();
        assert_eq!(res_lhs, lhs_tensor);
        assert_eq!(res_rhs, rhs_tensor);
    }

    #[test]
    fn test_get_binary_operands_invalid_children_count() {
        let lhs_tensor = utils_tests::scalar_tensor(1.0);
        let lhs_ast = EinSumOp::tensor_source(lhs_tensor.clone());
        let children = vec![lhs_ast]; // Only one child

        let err = CausalTensor::get_binary_operands(&children).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidNumberOfChildren {
                expected: 2,
                found: 1
            })
        ));
    }

    #[test]
    fn test_get_unary_operand_success() {
        let operand_tensor = utils_tests::scalar_tensor(1.0);
        let operand_ast = EinSumOp::tensor_source(operand_tensor.clone());
        let children = vec![operand_ast];

        let res_operand = CausalTensor::get_unary_operand(&children).unwrap();
        assert_eq!(res_operand, operand_tensor);
    }

    #[test]
    fn test_get_unary_operand_invalid_children_count() {
        let lhs_tensor = utils_tests::scalar_tensor(1.0);
        let rhs_tensor = utils_tests::scalar_tensor(2.0);
        let lhs_ast = EinSumOp::tensor_source(lhs_tensor.clone());
        let rhs_ast = EinSumOp::tensor_source(rhs_tensor.clone());
        let children = vec![lhs_ast, rhs_ast]; // Two children

        let err = CausalTensor::get_unary_operand(&children).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidNumberOfChildren {
                expected: 1,
                found: 2
            })
        ));
    }

    #[test]
    fn test_mat_mul_2d_success() {
        let lhs = utils_tests::matrix_tensor(vec![1.0, 2.0, 3.0, 4.0], 2, 2);
        let rhs = utils_tests::matrix_tensor(vec![5.0, 6.0, 7.0, 8.0], 2, 2);
        let expected = utils_tests::matrix_tensor(vec![19.0, 22.0, 43.0, 50.0], 2, 2);

        let result = CausalTensor::mat_mul_2d(&lhs, &rhs).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_mat_mul_2d_rank_mismatch() {
        let lhs = utils_tests::vector_tensor(vec![1.0, 2.0]);
        let rhs = utils_tests::matrix_tensor(vec![5.0, 6.0, 7.0, 8.0], 2, 2);

        let err = CausalTensor::mat_mul_2d(&lhs, &rhs).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::RankMismatch {
                expected: 2,
                found: 1
            })
        ));

        let lhs = utils_tests::matrix_tensor(vec![1.0, 2.0, 3.0, 4.0], 2, 2);
        let rhs = utils_tests::vector_tensor(vec![5.0, 6.0]);

        let err = CausalTensor::mat_mul_2d(&lhs, &rhs).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::RankMismatch {
                expected: 2,
                found: 1
            })
        ));
    }

    #[test]
    fn test_mat_mul_2d_shape_mismatch() {
        let lhs = utils_tests::matrix_tensor(vec![1.0, 2.0, 3.0, 4.0], 2, 2);
        let rhs = utils_tests::matrix_tensor(vec![5.0, 6.0, 7.0, 8.0, 9.0, 10.0], 3, 2);

        let err = CausalTensor::mat_mul_2d(&lhs, &rhs).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::ShapeMismatch { message: _ })
        ));
    }

    #[test]
    fn test_contract_mat_mul_success() {
        let lhs = utils_tests::matrix_tensor(vec![1.0, 2.0, 3.0, 4.0], 2, 2);
        let rhs = utils_tests::matrix_tensor(vec![5.0, 6.0, 7.0, 8.0], 2, 2);
        let expected = utils_tests::matrix_tensor(vec![19.0, 22.0, 43.0, 50.0], 2, 2);

        let result = CausalTensor::contract(&lhs, &rhs, &[1], &[0]).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_contract_dot_prod_success() {
        let lhs = utils_tests::vector_tensor(vec![1.0, 2.0, 3.0]);
        let rhs = utils_tests::vector_tensor(vec![4.0, 5.0, 6.0]);
        let expected = utils_tests::scalar_tensor(32.0); // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32

        let result = CausalTensor::contract(&lhs, &rhs, &[0], &[0]).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_contract_invalid_axes_len() {
        let lhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);
        let rhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);

        let err = CausalTensor::contract(&lhs, &rhs, &[0, 1], &[0]).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));
    }

    #[test]
    fn test_contract_axis_out_of_bounds() {
        let lhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);
        let rhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);

        let err = CausalTensor::contract(&lhs, &rhs, &[0], &[2]).unwrap_err(); // RHS axis 2 is out of bounds
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));

        let err = CausalTensor::contract(&lhs, &rhs, &[2], &[0]).unwrap_err(); // LHS axis 2 is out of bounds
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));
    }

    #[test]
    fn test_contract_shape_mismatch() {
        let lhs = utils_tests::matrix_tensor(vec![1.0; 6], 2, 3);
        let rhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);

        let err = CausalTensor::contract(&lhs, &rhs, &[1], &[0]).unwrap_err(); // LHS dim 1 (3) != RHS dim 0 (2)
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::ShapeMismatch { message: _ })
        ));
    }

    #[test]
    fn test_element_wise_mul_success() {
        let lhs = utils_tests::vector_tensor(vec![1.0, 2.0, 3.0]);
        let rhs = utils_tests::vector_tensor(vec![4.0, 5.0, 6.0]);
        let expected = utils_tests::vector_tensor(vec![4.0, 10.0, 18.0]);

        let result = CausalTensor::element_wise_mul(&lhs, &rhs).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_trace_success_matrix() {
        let operand = utils_tests::matrix_tensor(vec![1.0, 2.0, 3.0, 4.0], 2, 2);
        let expected = utils_tests::scalar_tensor(5.0); // 1.0 + 4.0

        let result = CausalTensor::trace(&operand, 0, 1).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_trace_success_3d_tensor() {
        let operand =
            CausalTensor::new(vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], vec![2, 2, 2]).unwrap();
        // Trace over axes 1 and 2 (matrices within the batch)
        // Batch 0: [[1,2],[3,4]] -> 1+4 = 5
        // Batch 1: [[5,6],[7,8]] -> 5+8 = 13
        let expected = utils_tests::vector_tensor(vec![5.0, 13.0]);

        let result = CausalTensor::trace(&operand, 1, 2).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_trace_invalid_axes_out_of_bounds() {
        let operand = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);
        let err = CausalTensor::trace(&operand, 0, 2).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));
    }

    #[test]
    fn test_trace_invalid_axes_identical() {
        let operand = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);
        let err = CausalTensor::trace(&operand, 0, 0).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));
    }

    #[test]
    fn test_trace_shape_mismatch() {
        let operand = CausalTensor::new(vec![1.0; 6], vec![2, 3]).unwrap(); // 2x3 matrix
        let err = CausalTensor::trace(&operand, 0, 1).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::ShapeMismatch { message: _ })
        ));
    }

    #[test]
    fn test_diagonal_success_matrix() {
        let operand = utils_tests::matrix_tensor(vec![1.0, 2.0, 3.0, 4.0], 2, 2);
        let expected = utils_tests::vector_tensor(vec![1.0, 4.0]);

        let result = CausalTensor::diagonal(&operand, 0, 1).unwrap();
        assert_eq!(result, expected);
    }
    #[test]
    fn test_diagonal_success_3d_tensor() {
        let operand =
            CausalTensor::new(vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0], vec![2, 2, 2]).unwrap();
        // Extract diagonal over axes 1 and 2 (matrices within the batch)
        // Batch 0: [[1,2],[3,4]] -> [1,4]
        // Batch 1: [[5,6],[7,8]] -> [5,8]
        let expected = CausalTensor::new(vec![1.0, 4.0, 5.0, 8.0], vec![2, 2]).unwrap();

        let result = CausalTensor::diagonal(&operand, 1, 2).unwrap();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_diagonal_invalid_axes_out_of_bounds() {
        let operand = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);
        let err = CausalTensor::diagonal(&operand, 0, 2).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));
    }

    #[test]
    fn test_diagonal_invalid_axes_identical() {
        let operand = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2);
        let err = CausalTensor::diagonal(&operand, 0, 0).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::InvalidAxesSpecification {
                message: _
            })
        ));
    }

    #[test]
    fn test_diagonal_shape_mismatch() {
        let operand = CausalTensor::new(vec![1.0; 6], vec![2, 3]).unwrap(); // 2x3 matrix
        let err = CausalTensor::diagonal(&operand, 0, 1).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::ShapeMismatch { message: _ })
        ));
    }

    #[test]
    fn test_batch_mat_mul_rank_mismatch() {
        let lhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2); // Rank 2
        let rhs = utils_tests::tensor_3d(vec![1.0; 8], 2, 2, 2); // Rank 3

        let err = CausalTensor::batch_mat_mul(lhs, rhs).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::RankMismatch {
                expected: 3,
                found: 2
            })
        ));

        let lhs = utils_tests::tensor_3d(vec![1.0; 8], 2, 2, 2); // Rank 3
        let rhs = utils_tests::matrix_tensor(vec![1.0; 4], 2, 2); // Rank 2

        let err = CausalTensor::batch_mat_mul(lhs, rhs).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::RankMismatch {
                expected: 3,
                found: 2
            })
        ));
    }

    #[test]
    fn test_batch_mat_mul_batch_size_mismatch() {
        let lhs = utils_tests::tensor_3d(vec![1.0; 8], 2, 2, 2); // Batch size 2
        let rhs = utils_tests::tensor_3d(vec![1.0; 12], 3, 2, 2); // Batch size 3

        let err = CausalTensor::batch_mat_mul(lhs, rhs).unwrap_err();
        assert!(matches!(
            err,
            CausalTensorError::EinSumError(EinSumValidationError::ShapeMismatch { message: _ })
        ));
    }
}

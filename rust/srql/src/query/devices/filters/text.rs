use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::BindParam,
};

pub(super) fn collect_text_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    allow_lists: bool,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn if allow_lists => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => Err(ServiceError::InvalidRequest(
            "list filters are not supported for this field".into(),
        )),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

//! Why an environment identity could not be determined.

use crate::types::identity::{ENV_VAR, ONPREM, SINGLE_INSTANCE_KINDS};
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectorError {
    Absent,
    UnknownKind(String),
    InstanceRequired(String),
    InstanceNotAccepted(String),
}

impl fmt::Display for SelectorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // The one failure a reader may be meeting for the first time, possibly at 3am, in a
            // crash loop with no other output. It says what is wrong, why nothing can proceed,
            // exactly what to set, and how to set it on each platform -- because the reader's
            // next action is editing a manifest, not reading source.
            Self::Absent => write!(
                f,
                "\n\
                 ==============================================================================\n\
                 SERVICERADAR CANNOT START: {ENV_VAR} is not set.\n\
                 ==============================================================================\n\
                 \n\
                 This one environment variable declares WHICH ServiceRadar environment this\n\
                 process is running in. Everything else is derived from it: the database, the\n\
                 message bus, the TLS posture, and which provider resolves secrets. Nothing can\n\
                 be loaded until it is set.\n\
                 \n\
                 There is deliberately NO DEFAULT. A guessed environment is a guessed database,\n\
                 and guessing wrong is silent -- the process would start and connect somewhere\n\
                 nobody chose.\n\
                 \n\
                 Set {ENV_VAR} to exactly one of:\n\
                 \n\
                   {}\n\
                   {ONPREM}:<instance>     (on-prem is multi-instance; name the deployment)\n\
                 \n\
                 How to set it:\n\
                 \n\
                   Kubernetes   env:\n\
                                  - name: {ENV_VAR}\n\
                                    value: saas\n\
                   Docker       docker run -e {ENV_VAR}=saas ...\n\
                   Compose      environment:\n\
                                  {ENV_VAR}: saas\n\
                   CI           export {ENV_VAR}=ci\n\
                   Local dev    export {ENV_VAR}=localhost\n\
                 ==============================================================================",
                SINGLE_INSTANCE_KINDS.join("\n                   ")
            ),
            Self::UnknownKind(k) => write!(
                f,
                "{ENV_VAR}={k:?} names no environment kind. Valid: {}, {ONPREM}:<instance>.",
                SINGLE_INSTANCE_KINDS.join(", ")
            ),
            Self::InstanceRequired(k) => {
                write!(f, "{ENV_VAR}={k:?} requires an instance identifier, as {k}:<instance>.")
            }
            Self::InstanceNotAccepted(k) => {
                write!(f, "{ENV_VAR} kind {k:?} does not accept an instance identifier.")
            }
        }
    }
}

impl std::error::Error for SelectorError {}

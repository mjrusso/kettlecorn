use crate::Value;
use std::fmt;

#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    InvalidRuntime(anyhow::Error),
    InvalidOptions(anyhow::Error),
    Preparation(anyhow::Error),
    Boot(anyhow::Error),
    BootDeadline,
    InvalidRequest(anyhow::Error),
    Backpressure,
    RequestIdsExhausted,
    Deadline,
    Stopped,
    Execution(anyhow::Error),
    Protocol(anyhow::Error),
    GuestCall(Value),
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRuntime(error) => write!(formatter, "invalid runtime: {error:#}"),
            Self::InvalidOptions(error) => write!(formatter, "invalid VM options: {error:#}"),
            Self::Preparation(error) => write!(formatter, "runtime preparation failed: {error:#}"),
            Self::Boot(error) => write!(formatter, "guest boot failed: {error:#}"),
            Self::BootDeadline => formatter.write_str("guest boot deadline exceeded"),
            Self::InvalidRequest(error) => write!(formatter, "invalid request: {error:#}"),
            Self::Backpressure => formatter.write_str("guest request capacity deadline exceeded"),
            Self::RequestIdsExhausted => {
                formatter.write_str("guest request IDs exhausted; start a new VM")
            }
            Self::Deadline => formatter.write_str("guest reply deadline exceeded"),
            Self::Stopped => formatter.write_str("guest is stopped"),
            Self::Execution(error) => write!(formatter, "guest execution failed: {error:#}"),
            Self::Protocol(error) => write!(formatter, "guest protocol error: {error:#}"),
            Self::GuestCall(reason) => write!(
                formatter,
                "guest call failed: {}",
                reason.as_atom().unwrap_or("guest process exited")
            ),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::InvalidRuntime(error)
            | Self::InvalidOptions(error)
            | Self::Preparation(error)
            | Self::Boot(error)
            | Self::InvalidRequest(error)
            | Self::Execution(error)
            | Self::Protocol(error) => Some(error.as_ref()),
            _ => None,
        }
    }
}

//! Run untrusted Elixir and Erlang in a WebAssembly sandbox from Rust.
//! Evaluate code, call guest GenServers, and expose async Rust functions to the guest.
//!
//! The crate embeds Wasmtime in your application process. Each VM has a private
//! filesystem, and network access is off by default.
//!
//! It uses the same guest runtime as [Kettlecorn's Elixir package](https://hex.pm/packages/kettlecorn).
//! Running guest code requires no host Elixir installation.
//!
//! Use [`Runtime::find`] for runtime discovery or [`Runtime::load`] to supply
//! a runtime directory. With the `installer` feature, `Runtime::install()`
//! installs the matching release into the cache shared with Elixir.
//! Call [`Runtime::start`] from a Tokio runtime to boot a VM and evaluate
//! code with [`Vm::eval`].

#[cfg(feature = "cli")]
mod cli;
mod engine;
mod error;
mod protocol;
mod unix;
mod vm;

#[cfg(feature = "cli")]
#[doc(hidden)]
pub use cli::main as launch_cli;
pub use engine::{Preload, Runtime};
pub use error::Error;
pub use num_bigint::BigInt;
pub use protocol::Value;
pub use vm::{
    EvalOptions, EvalValue, Evaluation, Language, ScriptError, Shutdown, Stats, Vm, VmOptions,
};

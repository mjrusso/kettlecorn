mod app;
mod bot;
mod canvas;
mod emitters;
mod garden;

use anyhow::{Context, Result, anyhow, bail};
use bot::Script;
use eframe::egui;
use emitters::{Emitters, Pattern};
use kettlecorn::Runtime;
use std::ffi::OsStr;
use std::path::PathBuf;

const USAGE: &str = "Usage: pulse-field RUNTIME_DIR [PRESET | SCRIPT.exs]

Presets
  cover       Fixed lanes, 1 emitter (default)
  relay       Orbit, 4 emitters
  mirrors     Orbit, 4 emitters
  prism       Sweep, 4 emitters
  sierpinski  Sweep, 4 emitters

Presets are built into the executable. Pass a script path to load it from disk
and start with Fixed lanes and 1 emitter.";

fn setup(choice: &OsStr) -> (Script, Emitters) {
    let embedded = |filename, source| Script::Embedded { filename, source };
    let (script, pattern, count) = match choice.to_str() {
        Some("cover") => (
            embedded("cover.exs", include_str!("../cover.exs")),
            Pattern::Fixed,
            1,
        ),
        Some("relay") => (
            embedded("relay.exs", include_str!("../relay.exs")),
            Pattern::Orbit,
            4,
        ),
        Some("mirrors") => (
            embedded("mirrors.exs", include_str!("../mirrors.exs")),
            Pattern::Orbit,
            4,
        ),
        Some("prism") => (
            embedded("prism.exs", include_str!("../prism.exs")),
            Pattern::Sweep,
            4,
        ),
        Some("sierpinski") => (
            embedded("sierpinski.exs", include_str!("../sierpinski.exs")),
            Pattern::Sweep,
            4,
        ),
        _ => (Script::File(PathBuf::from(choice)), Pattern::Fixed, 1),
    };
    (script, Emitters { pattern, count })
}

fn main() -> Result<()> {
    let mut args = std::env::args_os().skip(1);
    let runtime = args.next();
    let choice = args.next();
    if args.next().is_some() {
        bail!("{USAGE}");
    }
    let is_help = |arg: &OsStr| arg == "--help" || arg == "-h";
    if runtime.as_deref().is_some_and(is_help) || choice.as_deref().is_some_and(is_help) {
        println!("{USAGE}");
        return Ok(());
    }
    let runtime = runtime.context(USAGE)?;
    let (script, emitters) = setup(choice.as_deref().unwrap_or_else(|| OsStr::new("cover")));
    let runtime = Runtime::load(runtime).context("load Kettlecorn runtime")?;
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1020.0, 780.0])
            .with_min_inner_size([690.0, 540.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Pulse Field",
        options,
        Box::new(move |cc| Ok(Box::new(app::App::new(cc, runtime, script, emitters)?))),
    )
    .map_err(|error| anyhow!("open Pulse Field: {error}"))
}

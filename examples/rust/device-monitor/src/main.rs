use anyhow::{Context, Result, bail};
use kettlecorn::{EvalOptions, Runtime, Value, Vm, VmOptions};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::sync::mpsc;

const DISPATCHER: &str = r#"
defmodule DeviceMonitor.Dispatcher do
  use GenServer

  def start, do: GenServer.start(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(event, _from, nil) do
    {:reply, apply(MonitorPlugin, :handle_event, [event]), nil}
  end
end

:ok = MonitorPlugin.start()
{:ok, _} = DeviceMonitor.Dispatcher.start()
:ok
"#;

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    Sample { device: String, temperature: i32 },
    Crash { device: String },
}

impl Event {
    fn into_guest(self) -> Value {
        let (kind, device, temperature) = match self {
            Self::Sample {
                device,
                temperature,
            } => ("sample", device, Some(temperature)),
            Self::Crash { device } => ("crash", device, None),
        };
        let mut fields = vec![
            (Value::binary("type"), Value::binary(kind)),
            (Value::binary("device"), Value::Binary(device.into_bytes())),
        ];
        if let Some(temperature) = temperature {
            fields.push((
                Value::binary("temperature"),
                Value::Integer(temperature.into()),
            ));
        }
        Value::map(fields)
    }
}

struct Plugin {
    name: String,
    vm: Vm,
}

#[derive(Serialize)]
struct Alert<'a> {
    plugin: &'a str,
    device: &'a str,
    kind: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<i32>,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let mut args = std::env::args_os().skip(1).map(PathBuf::from);
    let usage = "usage: device-monitor TELEMETRY.jsonl PLUGIN.exs [PLUGIN.exs ...]";
    let telemetry = args.next().context(usage)?;
    let paths: Vec<_> = args.collect();
    if paths.is_empty() {
        bail!(usage);
    }

    let executable = std::env::current_exe().context("locate application executable")?;
    let bundle = executable
        .parent()
        .and_then(Path::parent)
        .context("locate application bundle")?;
    let runtime = Runtime::load(bundle.join("runtime")).context("load bundled runtime")?;

    let (stdout, mut output) = mpsc::channel::<Vec<u8>>(16);
    let forward_output = tokio::task::spawn_blocking(move || {
        while let Some(chunk) = output.blocking_recv() {
            io::stderr().write_all(&chunk)?;
        }
        Ok::<_, io::Error>(())
    });
    let mut plugins = Vec::new();
    let mut result = monitor(&runtime, &telemetry, paths, &mut plugins, stdout).await;
    for Plugin { name, vm } in plugins {
        let shutdown = vm.shutdown().await.with_context(|| format!("stop {name}"));
        result = result.and(shutdown);
    }
    let forwarded = forward_output.await.context("join plugin output task")?;
    result.and(forwarded.context("write plugin output"))
}

async fn monitor(
    runtime: &Runtime,
    telemetry: &Path,
    paths: Vec<PathBuf>,
    plugins: &mut Vec<Plugin>,
    stdout: mpsc::Sender<Vec<u8>>,
) -> Result<()> {
    let samples =
        File::open(telemetry).with_context(|| format!("open telemetry {}", telemetry.display()))?;
    for path in paths {
        let name = path
            .file_stem()
            .and_then(|name| name.to_str())
            .with_context(|| format!("invalid plugin filename {}", path.display()))?
            .to_owned();
        let source = std::fs::read_to_string(&path)
            .with_context(|| format!("read plugin {}", path.display()))?;
        let mut options = VmOptions::default();
        options.stdout = Some(stdout.clone());
        let label = name.clone();
        options.register("emit_alert", move |args| {
            let label = label.clone();
            async move {
                tokio::task::spawn_blocking(move || emit_alert(&label, args))
                    .await
                    .map_err(|error| error.to_string())?
            }
        });
        let vm = runtime
            .start(options)
            .await
            .with_context(|| format!("start {name} VM"))?;
        let plugin = Plugin { name, vm };
        let loaded = plugin
            .eval(
                &format!("{source}\n{DISPATCHER}"),
                EvalOptions {
                    timeout: Duration::from_secs(30),
                    ..EvalOptions::default()
                },
            )
            .await;
        plugins.push(plugin);
        loaded.context("load plugin")?;
    }

    for (index, line) in BufReader::new(samples).lines().enumerate() {
        let line = line.with_context(|| format!("read telemetry line {}", index + 1))?;
        let event = serde_json::from_str::<Event>(&line)
            .with_context(|| format!("parse telemetry line {}", index + 1))?
            .into_guest();
        for plugin in plugins.iter() {
            let reply = plugin
                .vm
                .call("Elixir.DeviceMonitor.Dispatcher", event.clone())
                .await
                .with_context(|| {
                    format!("{}: dispatch telemetry line {}", plugin.name, index + 1)
                })?;
            if reply.as_atom() != Some("ok") {
                bail!("{}: plugin must return :ok", plugin.name);
            }
        }
    }
    Ok(())
}

impl Plugin {
    async fn eval(&self, code: &str, options: EvalOptions) -> Result<()> {
        let evaluation = self
            .vm
            .eval(code, options)
            .await
            .with_context(|| self.name.clone())?;
        eprint!("{}", evaluation.output);
        evaluation.result.with_context(|| self.name.clone())?;
        Ok(())
    }
}

fn emit_alert(plugin: &str, args: Value) -> Result<Value, String> {
    if !matches!(args, Value::Map(_)) {
        return Err("expected an alert map".into());
    }
    let field = |name: &str| args.get_binary(name);
    let text = |name: &str| match field(name) {
        Some(Value::Binary(bytes)) => {
            std::str::from_utf8(bytes).map_err(|_| format!("{name} must be UTF-8"))
        }
        _ => Err(format!("{name} must be a string")),
    };
    let temperature = match field("temperature") {
        None => None,
        Some(Value::Integer(value)) => {
            Some(i32::try_from(value).map_err(|_| "temperature out of range")?)
        }
        _ => return Err("temperature must be an integer".into()),
    };
    let alert = Alert {
        plugin,
        device: text("device")?,
        kind: text("kind")?,
        temperature,
    };
    let line = serde_json::to_string(&alert).map_err(|error| error.to_string())?;
    writeln!(io::stdout().lock(), "{line}").map_err(|error| error.to_string())?;
    Ok(Value::atom("ok"))
}

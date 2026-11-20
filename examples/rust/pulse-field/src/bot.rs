use crate::garden::{
    Actor, ActorState, Cell, Direction, Frame, Garden, Hit, INK_COLORS, MessageKind, PulseEffect,
    SIZE, within_board,
};
use anyhow::{Context, Result, bail, ensure};
use kettlecorn::{EvalOptions, Runtime, Value, Vm, VmOptions};
use std::ffi::OsStr;
use std::path::PathBuf;
use std::time::Duration;

const LOAD_TIMEOUT: Duration = Duration::from_secs(30);
const FRAME_TIMEOUT: Duration = Duration::from_millis(500);

pub enum Script {
    Embedded {
        filename: &'static str,
        source: &'static str,
    },
    File(PathBuf),
}

impl Script {
    pub fn filename(&self) -> &OsStr {
        match self {
            Self::Embedded { filename, .. } => OsStr::new(filename),
            Self::File(path) => path.file_name().unwrap_or(path.as_os_str()),
        }
    }
}

pub struct Bot(Vm);

impl Bot {
    pub async fn load(runtime: &Runtime, script: &Script) -> Result<Self> {
        let (source, filename) = match script {
            Script::Embedded { filename, source } => (Value::from(*source), Value::from(*filename)),
            Script::File(path) => {
                let source = std::fs::read_to_string(path)
                    .with_context(|| format!("read bot {}", path.display()))?;
                (
                    Value::from(source),
                    Value::from(path.to_string_lossy().into_owned()),
                )
            }
        };
        let bot = Self(runtime.start(VmOptions::default()).await?);
        let setup = Value::Tuple(vec![
            source,
            filename,
            map([
                ("size", Value::from(SIZE)),
                ("center", pair((SIZE / 2, SIZE / 2))),
            ]),
        ]);
        let mut options = EvalOptions {
            timeout: LOAD_TIMEOUT,
            ..Default::default()
        };
        options.binding.insert("setup".into(), setup);
        let loaded = async {
            let evaluation = bot.0.eval(include_str!("session.exs"), options).await?;
            eprint!("{}", evaluation.output);
            evaluation.result?;
            Ok::<(), anyhow::Error>(())
        }
        .await;
        if let Err(error) = loaded {
            let _ = bot.shutdown().await;
            return Err(error.context("load bot"));
        }
        Ok(bot)
    }

    pub async fn frame(&self, view: Value) -> Result<Frame> {
        let reply = self
            .0
            .call_with_timeout(
                "Elixir.PulseField.Session",
                Value::Tuple(vec![Value::atom("frame"), view]),
                FRAME_TIMEOUT,
            )
            .await?;
        let [drawing_value, Value::Integer(linked_processes)] = tuple(reply)? else {
            bail!("expected a drawing and a linked process count");
        };
        let mut frame = drawing(drawing_value)?;
        frame.linked_processes = usize::try_from(linked_processes)?;
        Ok(frame)
    }

    pub async fn shutdown(self) -> Result<()> {
        Ok(self.0.shutdown().await?)
    }
}

pub fn view(garden: &Garden) -> Value {
    let pulses = garden.pulses.iter().map(|pulse| {
        Value::Tuple(vec![
            Value::Integer(pulse.id.into()),
            pair(pulse.cell),
            pair(pulse.direction.vector()),
        ])
    });
    map([
        ("tick", Value::Integer(garden.tick.into())),
        ("pulses", Value::List(pulses.collect())),
        (
            "emitters",
            Value::List(
                garden
                    .emitters
                    .positions(garden.tick)
                    .map(|(cell, direction)| {
                        Value::Tuple(vec![pair(cell), pair(direction.vector())])
                    })
                    .collect(),
            ),
        ),
    ])
}

fn map<'a>(fields: impl IntoIterator<Item = (&'a str, Value)>) -> Value {
    Value::map(
        fields
            .into_iter()
            .map(|(key, value)| (Value::binary(key), value)),
    )
}

fn pair((x, y): Cell) -> Value {
    Value::Tuple(vec![Value::Integer(x.into()), Value::Integer(y.into())])
}

fn tuple<const N: usize>(value: Value) -> Result<[Value; N]> {
    if let Value::Tuple(fields) = value
        && let Ok(fields) = <[Value; N]>::try_from(fields)
    {
        return Ok(fields);
    }
    bail!("expected a {N}-element tuple")
}

fn coordinates(value: Value) -> Result<Cell> {
    let [Value::Integer(x), Value::Integer(y)] = tuple(value)? else {
        bail!("expected two integers");
    };
    Ok((i32::try_from(x)?, i32::try_from(y)?))
}

fn board_cell(value: Value) -> Result<Cell> {
    let cell = coordinates(value)?;
    ensure!(within_board(cell), "cell {cell:?} is outside the board");
    Ok(cell)
}

fn ink(value: Value) -> Result<usize> {
    let Value::Integer(value) = value else {
        bail!("expected an integer ink index");
    };
    let index = usize::try_from(value)?;
    ensure!(index < INK_COLORS, "invalid ink index {index}");
    Ok(index)
}

fn actor_state(value: Value) -> Result<ActorState> {
    match value {
        Value::Atom(state) => match state.as_str() {
            "nil" => Ok(ActorState::Plain),
            "slash" => Ok(ActorState::Slash),
            "backslash" => Ok(ActorState::Backslash),
            _ => bail!("expected :slash, :backslash, nil, or a shield state"),
        },
        Value::Tuple(parts) => {
            let Ok(
                [
                    Value::Atom(kind),
                    Value::Atom(raised),
                    Value::Integer(charge),
                    Value::Integer(health),
                ],
            ) = <[Value; 4]>::try_from(parts)
            else {
                bail!("expected {{:shield, raised, charge, health}}");
            };
            ensure!(kind == "shield", "expected a shield state");
            let raised = match raised.as_str() {
                "true" => true,
                "false" => false,
                _ => bail!("expected a boolean shield position"),
            };
            Ok(ActorState::Shield {
                raised,
                charge: u8::try_from(charge)?,
                health: u8::try_from(health)?,
            })
        }
        _ => bail!("expected an actor state"),
    }
}

fn drawing(value: Value) -> Result<Frame> {
    let Value::Map(mut fields) = value else {
        bail!("expected a frame map");
    };
    let mut collection = |key: &str| -> Result<Vec<Value>> {
        match fields.remove(&Value::binary(key)) {
            Some(Value::List(items)) => Ok(items),
            Some(_) => bail!("{key} must be a list"),
            None => Ok(Vec::new()),
        }
    };
    let turns = collection("turns")?;
    let marks = collection("marks")?;
    let actors = collection("actors")?;
    let messages = collection("messages")?;
    let hits = collection("hits")?;
    ensure!(fields.is_empty(), "unexpected frame field");

    let mut frame = Frame::default();
    for turn in turns {
        let [Value::Integer(id), vector] = tuple(turn)? else {
            bail!("expected an integer pulse ID and a direction");
        };
        let direction = Direction::new(coordinates(vector)?)
            .context("direction must be a single step north, south, east, west, or diagonally")?;
        ensure!(
            frame
                .effects
                .insert(u64::try_from(id)?, PulseEffect::Turn(direction))
                .is_none(),
            "a pulse can turn only once per frame"
        );
    }

    for mark in marks {
        let [cell, color] = tuple(mark)?;
        frame.marks.push((board_cell(cell)?, ink(color)?));
    }
    for actor in actors {
        let [Value::Integer(id), cell, color, state] = tuple(actor)? else {
            bail!("expected {{actor_id, cell, ink, state}}");
        };
        let actor = Actor {
            cell: board_cell(cell)?,
            ink: ink(color)?,
            state: actor_state(state)?,
        };
        ensure!(
            frame.actors.insert(u32::try_from(id)?, actor).is_none(),
            "actor IDs must be unique within a frame"
        );
    }
    for message in messages {
        let [Value::Integer(from), Value::Integer(to), Value::Atom(kind)] = tuple(message)? else {
            bail!("expected {{sender_id, receiver_id, kind}}");
        };
        let kind = match kind.as_str() {
            "nil" => None,
            "cover_me" => Some(MessageKind::CoverMe),
            "in_position" => Some(MessageKind::InPosition),
            _ => bail!("expected nil, :cover_me, or :in_position"),
        };
        frame
            .messages
            .push((u32::try_from(from)?, u32::try_from(to)?, kind));
    }
    for hit in hits {
        let [Value::Integer(id), color, Value::Atom(kind)] = tuple(hit)? else {
            bail!("expected {{pulse_id, ink, kind}}");
        };
        let color = ink(color)?;
        let hit = match kind.as_str() {
            "shield" => Hit::Shield(color),
            "damage" => Hit::Damage(color),
            _ => bail!("expected :shield or :damage"),
        };
        ensure!(
            !matches!(
                frame
                    .effects
                    .insert(u64::try_from(id)?, PulseEffect::Hit(hit)),
                Some(PulseEffect::Hit(_))
            ),
            "a pulse can hit only once per frame"
        );
    }
    Ok(frame)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use tokio::sync::OnceCell;

    async fn test_runtime() -> Result<Option<&'static Runtime>> {
        static RUNTIME: OnceCell<Runtime> = OnceCell::const_new();
        let Some(path) = std::env::var_os("KETTLECORN_TEST_RUNTIME") else {
            return Ok(None);
        };
        let runtime = RUNTIME
            .get_or_try_init(|| async {
                let runtime = Runtime::load(path)?;
                runtime.warm_up(&VmOptions::default()).await?;
                Ok::<_, anyhow::Error>(runtime)
            })
            .await?;
        Ok(Some(runtime))
    }

    #[tokio::test]
    async fn triangle_rows_reveal_in_order_and_light_only_filled_cells() -> Result<()> {
        let Some(runtime) = test_runtime().await? else {
            return Ok(());
        };
        let (script, _) = crate::setup(OsStr::new("sierpinski"));
        let bot = Bot::load(runtime, &script).await?;
        let mut garden = Garden::new();

        garden.advance();
        let frame = bot.frame(view(&garden)).await?;
        assert_eq!(frame.marks, [((20, 4), 0)]);
        assert_eq!(frame.linked_processes, 16);
        assert!(frame.actors.is_empty());

        garden.fire((19, 5), Direction::EAST, 1);
        garden.fire((20, 5), Direction::EAST, 1);
        garden.advance();
        let frame = bot.frame(view(&garden)).await?;
        assert_eq!(frame.marks, [((20, 4), 0), ((19, 5), 3), ((21, 5), 0)]);
        assert!(frame.effects.is_empty());

        garden.advance();
        let frame = bot.frame(view(&garden)).await?;
        assert!(frame.marks.contains(&((19, 5), 3)));
        assert!(frame.marks.iter().all(|(cell, _)| *cell != (20, 5)));

        while garden.tick < 30 {
            garden.advance();
        }
        assert_eq!(bot.frame(view(&garden)).await?.marks.len(), 81);
        bot.shutdown().await
    }

    #[tokio::test]
    async fn shield_workers_handoff_and_continue_after_a_worker_dies() -> Result<()> {
        let Some(runtime) = test_runtime().await? else {
            return Ok(());
        };
        let (script, _) = crate::setup(OsStr::new("cover"));
        let bot = Bot::load(runtime, &script).await?;
        let mut garden = Garden::new();
        garden.emitters.pattern = crate::emitters::Pattern::Fixed;
        for _ in 0..34 {
            garden.advance();
            let frame = bot.frame(view(&garden)).await?;
            if garden.tick == 26 {
                assert_eq!(frame.linked_processes, 2);
                assert_eq!(frame.messages, [(1, 2, Some(MessageKind::CoverMe))]);
            }
            if garden.tick == 32 {
                assert_eq!(frame.messages, [(2, 1, Some(MessageKind::InPosition))]);
            }
            garden.apply(frame);
        }
        assert!(matches!(
            garden.actors[&1].state,
            ActorState::Shield { raised: false, .. }
        ));
        assert_eq!(
            garden.actors[&2].state,
            ActorState::Shield {
                raised: true,
                charge: 2,
                health: 2
            }
        );

        let target = garden.actors[&2].cell;
        for _ in 0..4 {
            garden.fire(target, Direction::EAST, 1);
        }
        garden.advance();
        let frame = bot.frame(view(&garden)).await?;
        assert_eq!(
            frame
                .effects
                .values()
                .filter(|effect| matches!(effect, PulseEffect::Hit(Hit::Damage(_))))
                .count(),
            2
        );
        garden.apply(frame);
        assert!(!garden.actors.contains_key(&2));
        assert!(!garden.pulses.iter().any(|pulse| pulse.cell == target));
        garden.advance();
        let frame = bot.frame(view(&garden)).await?;
        assert_eq!(frame.linked_processes, 1);
        garden.apply(frame);
        assert_eq!(garden.actors.len(), 1);
        bot.shutdown().await
    }

    #[tokio::test]
    async fn the_relay_passes_the_mirror_between_moving_workers() -> Result<()> {
        let Some(runtime) = test_runtime().await? else {
            return Ok(());
        };
        let (script, _) = crate::setup(OsStr::new("relay"));
        let bot = Bot::load(runtime, &script).await?;
        let mut garden = Garden::new();
        garden.fire((15, 15), Direction::EAST, 1);
        garden.fire((28, 12), Direction::EAST, 1);
        for tick in 1..=18 {
            if tick == 17 {
                garden.fire((28, 20), Direction::EAST, 1);
            }
            garden.advance();
            let frame = bot.frame(view(&garden)).await?;
            assert_eq!(frame.actors.len(), 4);
            garden.apply(frame);
            match tick {
                1 => {
                    assert_eq!(garden.actors[&1].state, ActorState::Slash);
                    assert_eq!(garden.actors[&2].state, ActorState::Plain);
                    assert_eq!(garden.pulses[0].direction, Direction::NORTH);
                    assert_eq!(garden.pulses[1].direction, Direction::EAST);
                }
                2 => {
                    assert_eq!(garden.actors[&1].cell, (16, 15));
                    assert!(garden.trails[(15 * SIZE + 15) as usize].is_some());
                }
                16 => {
                    assert_eq!(garden.actors[&2].cell, (28, 20));
                    assert_eq!(garden.messages[0].to, (28, 20));
                }
                17 => {
                    assert_eq!(garden.actors[&1].state, ActorState::Plain);
                    assert_eq!(garden.actors[&2].state, ActorState::Backslash);
                    assert_eq!(garden.pulses.last().unwrap().direction, Direction::SOUTH);
                }
                18 => assert_eq!(garden.actors[&2].cell, (28, 19)),
                _ => {}
            }
        }
        bot.shutdown().await
    }

    #[tokio::test]
    async fn mirror_cells_flip_their_neighbors_for_the_next_tick() -> Result<()> {
        let Some(runtime) = test_runtime().await? else {
            return Ok(());
        };
        let (script, _) = crate::setup(OsStr::new("mirrors"));
        let bot = Bot::load(runtime, &script).await?;
        let mut garden = Garden::new();
        garden.fire((2, 2), Direction::EAST, 1);
        garden.fire((3, 2), Direction::EAST, 2);
        garden.advance();

        let frame = bot.frame(view(&garden)).await?;
        assert_eq!(frame.linked_processes, (SIZE * SIZE) as usize);
        assert_eq!(
            frame.effects,
            HashMap::from([(0, PulseEffect::Turn(Direction::NORTH))])
        );
        assert!(frame.marks.contains(&((3, 2), 0)));
        garden.apply(frame);
        garden.advance();
        garden.apply(bot.frame(view(&garden)).await?);
        garden.advance();

        let frame = bot.frame(view(&garden)).await?;
        assert!(matches!(frame.effects.get(&2), Some(PulseEffect::Turn(_))));
        assert!(frame.marks.contains(&((3, 2), 2)));
        bot.shutdown().await?;

        let (script, _) = crate::setup(OsStr::new("prism"));
        let prism = Bot::load(runtime, &script).await?;
        let mut garden = Garden::new();
        garden.fire((20, 14), Direction::SOUTH, 1);
        garden.advance();
        let frame = prism.frame(view(&garden)).await?;
        assert_eq!(frame.linked_processes, 0);
        assert_eq!(
            frame.effects,
            HashMap::from([(0, PulseEffect::Turn(Direction::WEST))])
        );
        assert_eq!(frame.marks, [((20, 14), 3)]);
        prism.shutdown().await
    }
}

use crate::emitters::Emitters;
use std::collections::{BTreeMap, HashMap};

pub const SIZE: i32 = 41;
pub const INK_COLORS: usize = 4;
pub const TRAIL_AGE: u64 = 72;
pub const MESSAGE_AGE: u64 = 14;
pub const IMPACT_AGE: u64 = 8;
const PULSE_AGE: u64 = 240;
const BURST_SPACING: u64 = 2;

pub type Cell = (i32, i32);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Direction(Cell);

impl Direction {
    pub const NORTH: Self = Self((0, -1));
    pub const EAST: Self = Self((1, 0));
    pub const SOUTH: Self = Self((0, 1));
    pub const WEST: Self = Self((-1, 0));

    pub fn new((x, y): Cell) -> Option<Self> {
        ((-1..=1).contains(&x) && (-1..=1).contains(&y) && (x, y) != (0, 0)).then_some(Self((x, y)))
    }

    pub fn vector(self) -> Cell {
        self.0
    }
}

pub fn within_board((x, y): Cell) -> bool {
    (0..SIZE).contains(&x) && (0..SIZE).contains(&y)
}

pub struct Pulse {
    pub id: u64,
    pub cell: Cell,
    pub direction: Direction,
    born: u64,
}

#[derive(Clone, Copy)]
pub struct Trail {
    pub ink: usize,
    pub tick: u64,
}

struct Burst {
    origin: Cell,
    direction: Direction,
    remaining: u8,
    next: u64,
}

#[derive(Debug)]
pub struct Actor {
    pub cell: Cell,
    pub ink: usize,
    pub state: ActorState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActorState {
    Plain,
    Slash,
    Backslash,
    Shield {
        raised: bool,
        charge: u8,
        health: u8,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    Shield(usize),
    Damage(usize),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PulseEffect {
    Turn(Direction),
    Hit(Hit),
}

pub struct Impact {
    pub cell: Cell,
    pub hit: Hit,
    pub tick: u64,
}

pub struct Message {
    pub from: Cell,
    pub to: Cell,
    pub ink: usize,
    pub tick: u64,
    pub kind: Option<MessageKind>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MessageKind {
    CoverMe,
    InPosition,
}

#[derive(Debug, Default)]
pub struct Frame {
    pub linked_processes: usize,
    pub effects: HashMap<u64, PulseEffect>,
    pub marks: Vec<(Cell, usize)>,
    pub actors: BTreeMap<u32, Actor>,
    pub messages: Vec<(u32, u32, Option<MessageKind>)>,
}

pub struct Garden {
    pub tick: u64,
    pub pulses: Vec<Pulse>,
    pub trails: Vec<Option<Trail>>,
    pub actors: BTreeMap<u32, Actor>,
    pub messages: Vec<Message>,
    pub impacts: Vec<Impact>,
    pub emitters: Emitters,
    bursts: Vec<Burst>,
    next_id: u64,
}

impl Garden {
    pub fn new() -> Self {
        Self {
            tick: 0,
            pulses: Vec::new(),
            trails: vec![None; (SIZE * SIZE) as usize],
            actors: BTreeMap::new(),
            messages: Vec::new(),
            impacts: Vec::new(),
            emitters: Emitters::default(),
            bursts: Vec::new(),
            next_id: 0,
        }
    }

    pub fn fire(&mut self, origin: Cell, direction: Direction, count: u8) {
        self.bursts.push(Burst {
            origin,
            direction,
            remaining: count,
            next: self.tick + 1,
        });
    }

    pub fn advance(&mut self) {
        self.tick += 1;
        self.messages
            .retain(|message| self.tick - message.tick < MESSAGE_AGE);
        self.impacts
            .retain(|impact| self.tick - impact.tick < IMPACT_AGE);
        self.pulses.retain_mut(|pulse| {
            let (dx, dy) = pulse.direction.vector();
            pulse.cell.0 += dx;
            pulse.cell.1 += dy;
            self.tick - pulse.born < PULSE_AGE && within_board(pulse.cell)
        });
        let tick = self.tick;
        let mut launch = |cell, direction| {
            self.pulses.push(Pulse {
                id: self.next_id,
                cell,
                direction,
                born: tick,
            });
            self.next_id += 1;
        };
        if let Some((cell, direction)) = self.emitters.shot(tick) {
            launch(cell, direction);
        }
        for burst in &mut self.bursts {
            if burst.next == tick {
                launch(burst.origin, burst.direction);
                burst.remaining -= 1;
                burst.next += BURST_SPACING;
            }
        }
        self.bursts.retain(|burst| burst.remaining > 0);
    }

    pub fn apply(&mut self, frame: Frame) {
        self.pulses
            .retain_mut(|pulse| match frame.effects.get(&pulse.id).copied() {
                Some(PulseEffect::Hit(hit)) => {
                    self.impacts.push(Impact {
                        cell: pulse.cell,
                        hit,
                        tick: self.tick,
                    });
                    false
                }
                Some(PulseEffect::Turn(direction)) => {
                    pulse.direction = direction;
                    true
                }
                None => true,
            });
        for (cell, ink) in frame.marks {
            self.mark(cell, ink);
        }
        for (id, actor) in &frame.actors {
            if let Some(previous) = self.actors.get(id)
                && previous.cell != actor.cell
            {
                self.mark(previous.cell, actor.ink);
            }
        }
        self.actors = frame.actors;
        for (from, to, kind) in frame.messages {
            if let (Some(from), Some(to)) = (self.actors.get(&from), self.actors.get(&to)) {
                self.messages.push(Message {
                    from: from.cell,
                    to: to.cell,
                    ink: from.ink,
                    tick: self.tick,
                    kind,
                });
            }
        }
    }

    fn mark(&mut self, (x, y): Cell, ink: usize) {
        self.trails[(y * SIZE + x) as usize] = Some(Trail {
            ink,
            tick: self.tick,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turning_one_pulse_preserves_its_identity_and_moves_it_on_the_next_tick() {
        let mut garden = Garden::new();
        garden.fire((10, 10), Direction::EAST, 2);
        garden.advance();
        let id = garden.pulses[0].id;

        garden.apply(Frame {
            effects: HashMap::from([(id, PulseEffect::Turn(Direction::NORTH))]),
            marks: vec![((10, 10), 1)],
            ..Frame::default()
        });
        assert_eq!(garden.pulses[0].cell, (10, 10));
        garden.advance();
        garden.advance();

        assert_eq!(garden.pulses[0].id, id);
        assert_eq!(garden.pulses[0].cell, (10, 8));
        assert_eq!(garden.pulses[1].cell, (10, 10));
        assert_eq!(garden.pulses[1].direction, Direction::EAST);
    }
}

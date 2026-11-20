use crate::garden::{Cell, Direction, SIZE};

const SHOT_INTERVAL: u64 = 10;
const EDGE: i32 = SIZE - 1;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Pattern {
    Manual,
    Fixed,
    Sweep,
    Orbit,
}

impl Pattern {
    pub const ALL: [Self; 4] = [Self::Manual, Self::Fixed, Self::Sweep, Self::Orbit];

    pub fn label(self) -> &'static str {
        match self {
            Self::Manual => "Manual only",
            Self::Fixed => "Fixed lanes",
            Self::Sweep => "Sweep",
            Self::Orbit => "Orbit",
        }
    }
}

#[derive(Clone, Copy)]
pub struct Emitters {
    pub pattern: Pattern,
    pub count: u8,
}

impl Default for Emitters {
    fn default() -> Self {
        Self {
            pattern: Pattern::Manual,
            count: 1,
        }
    }
}

impl Emitters {
    pub fn positions(self, tick: u64) -> impl Iterator<Item = (Cell, Direction)> {
        let count = if self.pattern == Pattern::Manual {
            0
        } else {
            i32::from(self.count)
        };
        let travel = (tick / 3 % (4 * EDGE) as u64) as i32;
        (0..count).map(move |index| match self.pattern {
            Pattern::Manual => unreachable!(),
            Pattern::Fixed => {
                let lane = [SIZE / 2, SIZE / 3, SIZE * 2 / 3, SIZE / 4][index as usize];
                on_edge(index, lane)
            }
            Pattern::Sweep => {
                let span = EDGE - 10;
                let offset = (travel + index * 13).rem_euclid(2 * span);
                let lane = 5 + span - (span - offset).abs();
                on_edge(index, lane)
            }
            Pattern::Orbit => {
                let phase = (travel + index * 4 * EDGE / count).rem_euclid(4 * EDGE);
                let (cell, direction) = on_edge(phase / EDGE, phase % EDGE);
                if phase % EDGE == 0 {
                    let inward = (SIZE / 2 - cell.0, SIZE / 2 - cell.1);
                    (
                        cell,
                        Direction::new((inward.0.signum(), inward.1.signum())).unwrap(),
                    )
                } else {
                    (cell, direction)
                }
            }
        })
    }

    pub fn shot(self, tick: u64) -> Option<(Cell, Direction)> {
        if self.pattern == Pattern::Manual || tick == 0 || !(tick - 1).is_multiple_of(SHOT_INTERVAL)
        {
            return None;
        }
        let index = (tick - 1) / SHOT_INTERVAL % u64::from(self.count);
        self.positions(tick).nth(index as usize)
    }
}

fn on_edge(side: i32, lane: i32) -> (Cell, Direction) {
    match side {
        0 => ((0, EDGE - lane), Direction::EAST),
        1 => ((lane, 0), Direction::SOUTH),
        2 => ((EDGE, lane), Direction::WEST),
        _ => ((EDGE - lane, EDGE), Direction::NORTH),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::garden::within_board;

    #[test]
    fn every_automatic_pattern_keeps_the_same_firing_rate_and_aims_inward() {
        for pattern in [Pattern::Fixed, Pattern::Sweep, Pattern::Orbit] {
            for count in 1..=4 {
                let emitters = Emitters { pattern, count };
                assert_eq!(emitters.positions(1).count(), usize::from(count));
                for tick in 1..=480 {
                    for (cell, direction) in emitters.positions(tick) {
                        let (dx, dy) = direction.vector();
                        assert!(within_board(cell));
                        assert!(within_board((cell.0 + dx, cell.1 + dy)));
                    }
                    assert_eq!(emitters.shot(tick).is_some(), (tick - 1) % 10 == 0);
                }
            }
        }
        assert_eq!(Emitters::default().shot(1), None);
    }
}

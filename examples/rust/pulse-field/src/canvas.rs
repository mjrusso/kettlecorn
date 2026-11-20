use crate::garden::{
    ActorState, Cell, Direction, Garden, Hit, IMPACT_AGE, INK_COLORS, MESSAGE_AGE, MessageKind,
    SIZE, TRAIL_AGE, within_board,
};
use eframe::egui::{
    Align2, Color32, CursorIcon, FontId, Painter, Pos2, Rect, Sense, Stroke, StrokeKind, Ui, Vec2,
};
use std::f32::consts::PI;

const FIELD: Color32 = Color32::from_rgb(10, 15, 23);
const BORDER: Color32 = Color32::from_rgb(54, 69, 83);
const GRID: Color32 = Color32::from_rgb(30, 43, 54);
const PULSE: Color32 = Color32::from_rgb(255, 223, 167);
const DAMAGE: Color32 = Color32::from_rgb(255, 105, 92);
const INKS: [Color32; INK_COLORS] = [
    Color32::from_rgb(87, 208, 233),
    Color32::from_rgb(174, 146, 245),
    Color32::from_rgb(255, 135, 175),
    Color32::from_rgb(149, 233, 169),
];

pub fn draw(
    ui: &mut Ui,
    side: f32,
    garden: &Garden,
    origin: Cell,
    direction: Direction,
) -> Option<Cell> {
    let (rect, response) = ui.allocate_exact_size(Vec2::splat(side), Sense::click());
    let painter = ui.painter_at(rect);
    painter.rect_filled(rect, 5, FIELD);
    painter.rect_stroke(rect, 5, Stroke::new(1.0, BORDER), StrokeKind::Inside);

    let field = rect.shrink(12.0_f32.min(side / 4.0));
    let unit = field.width() / SIZE as f32;
    let position = |(x, y): Cell| field.min + Vec2::new(x as f32 + 0.5, y as f32 + 0.5) * unit;
    let cell_at = |pos: Pos2| {
        let offset = (pos - field.min) / unit;
        (offset.x.floor() as i32, offset.y.floor() as i32)
    };
    let hover = response
        .hover_pos()
        .filter(|pos| field.contains(*pos))
        .map(cell_at)
        .filter(|&cell| within_board(cell));
    if hover.is_some() {
        ui.ctx().set_cursor_icon(CursorIcon::Crosshair);
    }
    for i in (0..SIZE).step_by(2) {
        for j in (0..SIZE).step_by(2) {
            painter.circle_filled(position((i, j)), 0.7, GRID);
        }
    }

    for (index, trail) in garden.trails.iter().enumerate() {
        let Some(trail) = trail.filter(|trail| garden.tick - trail.tick < TRAIL_AGE) else {
            continue;
        };
        let center = position(((index as i32) % SIZE, (index as i32) / SIZE));
        let fade = 1.0 - (garden.tick - trail.tick) as f32 / TRAIL_AGE as f32;
        let ink = INKS[trail.ink];
        painter.circle_filled(center, unit * 0.64, ink.gamma_multiply(fade * 0.22));
        painter.rect_filled(
            Rect::from_center_size(center, Vec2::splat(unit * 0.51)),
            2,
            ink.gamma_multiply(fade * 0.85),
        );
    }

    for message in &garden.messages {
        let from = position(message.from);
        let to = position(message.to);
        let age = (garden.tick - message.tick) as f32 / MESSAGE_AGE as f32;
        let ink = INKS[message.ink];
        painter.line_segment(
            [from, to],
            Stroke::new(1.0, ink.gamma_multiply((1.0 - age) * 0.68)),
        );
        painter.circle_filled(from.lerp(to, age), unit * 0.24, ink);
        if let Some(kind) = message.kind {
            let text = match kind {
                MessageKind::CoverMe => "Cover me",
                MessageKind::InPosition => "In position",
            };
            let direction = to - from;
            let normal = if kind == MessageKind::InPosition || direction == Vec2::ZERO {
                Vec2::new(0.0, -1.0)
            } else {
                Vec2::new(direction.y, -direction.x).normalized()
            };
            let anchor = from.lerp(to, 0.5) + normal * 29.0;
            let align = if normal.x > 0.25 {
                Align2::LEFT_CENTER
            } else if normal.x < -0.25 {
                Align2::RIGHT_CENTER
            } else {
                Align2::CENTER_CENTER
            };
            let fade = ((1.0 - age) * 4.0).min(1.0);
            let ink = ink.gamma_multiply(fade);
            let galley = painter.layout_no_wrap(text.into(), FontId::proportional(12.0), ink);
            let size = galley.size();
            let room = rect.shrink(6.0);
            let min = align
                .anchor_size(anchor, size)
                .min
                .clamp(room.min, (room.max - size).max(room.min));
            let label = Rect::from_min_size(min, size);
            let badge = label.expand2(Vec2::new(5.0, 3.0));
            painter.rect_filled(badge, 3, FIELD.gamma_multiply(fade));
            painter.rect_stroke(badge, 3, Stroke::new(1.0, ink), StrokeKind::Inside);
            painter.galley(label.min, galley, ink);
        }
    }

    for impact in &garden.impacts {
        let ink = match impact.hit {
            Hit::Shield(ink) => INKS[ink],
            Hit::Damage(ink) => DAMAGE.lerp_to_gamma(INKS[ink], 0.15),
        };
        let age = (garden.tick - impact.tick) as f32 / IMPACT_AGE as f32;
        let stroke = Stroke::new(2.0, ink.gamma_multiply(1.0 - age));
        painter.circle_stroke(position(impact.cell), unit * (0.75 + age), stroke);
    }

    for pulse in &garden.pulses {
        let center = position(pulse.cell);
        let (dx, dy) = pulse.direction.vector();
        let heading = Vec2::new(dx as f32, dy as f32) * unit * 0.43;
        painter.circle_filled(center, unit * 0.59, PULSE.gamma_multiply(0.27));
        painter.line_segment(
            [center - heading, center + heading],
            Stroke::new(2.5, PULSE),
        );
        painter.circle_filled(center, unit * 0.18, Color32::WHITE);
    }

    for (&id, actor) in &garden.actors {
        let center = position(actor.cell);
        let ink = INKS[actor.ink];
        let radius = (unit * 0.60).max(7.0);
        painter.circle_filled(center, radius + 3.0, ink.gamma_multiply(0.19));
        painter.circle_filled(center, radius, FIELD);
        painter.circle_stroke(center, radius, Stroke::new(1.6, ink));
        let label = match actor.state {
            ActorState::Plain => center,
            ActorState::Slash | ActorState::Backslash => {
                let rise = if actor.state == ActorState::Slash {
                    -1.0
                } else {
                    1.0
                };
                let edge = Vec2::new(1.0, rise) * radius * 0.48;
                painter.line_segment([center - edge, center + edge], Stroke::new(2.3, PULSE));
                center - Vec2::new(0.0, radius + 8.0)
            }
            ActorState::Shield {
                raised,
                charge,
                health,
            } => {
                shield(&painter, center, radius, ink, raised, charge, health);
                center - Vec2::new(0.0, radius * 0.28)
            }
        };
        painter.text(
            label,
            Align2::CENTER_CENTER,
            id,
            FontId::monospace((unit * 0.75).max(9.0)),
            ink,
        );
    }

    let shot = garden.emitters.shot(garden.tick);
    for (cell, direction) in garden.emitters.positions(garden.tick) {
        let center = position(cell);
        let (dx, dy) = direction.vector();
        let flashing = shot == Some((cell, direction));
        let body = Rect::from_center_size(center, Vec2::splat(unit * 0.83));
        painter.rect_filled(body, 2, if flashing { PULSE } else { BORDER });
        painter.arrow(
            center,
            Vec2::new(dx as f32, dy as f32) * unit * 1.08,
            Stroke::new(1.2, PULSE),
        );
    }

    let emitter = position(hover.unwrap_or(origin));
    let (dx, dy) = direction.vector();
    painter.circle_stroke(emitter, unit * 0.66, Stroke::new(1.0, PULSE));
    painter.arrow(
        emitter,
        Vec2::new(dx as f32, dy as f32) * unit * 1.55,
        Stroke::new(1.3, PULSE),
    );

    hover.filter(|_| response.clicked())
}

fn shield(
    painter: &Painter,
    center: Pos2,
    radius: f32,
    ink: Color32,
    raised: bool,
    charge: u8,
    health: u8,
) {
    let segments = charge.max(3);
    let sweep = PI / f32::from(segments);
    for segment in 0..segments {
        let start = PI + (f32::from(segment) + 0.12) * sweep;
        let points = (0..=5)
            .map(|step| {
                let angle = start + step as f32 * sweep * 0.76 / 5.0;
                center + Vec2::angled(angle) * (radius + 4.0)
            })
            .collect();
        let color = if segment < charge {
            ink.gamma_multiply(if raised { 1.0 } else { 0.54 })
        } else {
            BORDER
        };
        painter.line(points, Stroke::new(if raised { 2.5 } else { 1.7 }, color));
    }

    let slots = health.max(2);
    let spacing = (radius / f32::from(slots)).min(5.0);
    for slot in 0..slots {
        let offset = (f32::from(slot) - (f32::from(slots) - 1.0) * 0.5) * spacing;
        let position = center + Vec2::new(offset, radius * 0.49);
        let color = if slot < health {
            Color32::WHITE
        } else {
            BORDER
        };
        painter.circle_filled(position, (spacing * 0.34).min(1.7), color);
    }
}

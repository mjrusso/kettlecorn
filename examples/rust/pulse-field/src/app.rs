use crate::bot::{self, Bot, Script};
use crate::canvas;
use crate::emitters::{Emitters, Pattern};
use crate::garden::{Cell, Direction, Frame, Garden};
use anyhow::Result;
use eframe::egui::{self, Align, Color32, Key, Layout, RichText, Stroke, Ui, Vec2};
use kettlecorn::{Runtime, Value};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tokio::sync::mpsc as async_mpsc;

const FRAME_INTERVAL: Duration = Duration::from_millis(80);
const WORKSPACE: Color32 = Color32::from_rgb(17, 23, 31);
const CHROME: Color32 = Color32::from_rgb(23, 31, 41);
const DIVIDER: Color32 = Color32::from_rgb(52, 66, 80);
const INSPECTOR_WIDTH: f32 = 216.0;
const TEXT: Color32 = Color32::from_rgb(231, 239, 244);
const MUTED: Color32 = Color32::from_rgb(166, 183, 197);
const ACCENT: Color32 = Color32::from_rgb(255, 223, 167);
const ERROR: Color32 = Color32::from_rgb(255, 156, 141);

enum Request {
    Reload,
    Frame(Value),
}

enum Response {
    Loaded,
    Frame(Frame),
    Error(String),
}

struct Worker {
    thread: Option<(async_mpsc::Sender<Request>, JoinHandle<()>)>,
    responses: mpsc::Receiver<Response>,
}

impl Worker {
    fn spawn(context: egui::Context, runtime: Runtime, script: Script) -> Result<Self> {
        let executor = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let (requests, mut commands) = async_mpsc::channel(1);
        let (send, responses) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("pulse-field-vm".into())
            .spawn(move || {
                executor.block_on(async move {
                    let mut bot: Option<Bot> = None;
                    while let Some(request) = commands.recv().await {
                        let response = match request {
                            Request::Reload => {
                                if let Some(previous) = bot.take() {
                                    let _ = previous.shutdown().await;
                                }
                                Bot::load(&runtime, &script).await.map(|loaded| {
                                    bot = Some(loaded);
                                    Response::Loaded
                                })
                            }
                            Request::Frame(view) => match &bot {
                                Some(bot) => bot.frame(view).await.map(Response::Frame),
                                None => Err(anyhow::anyhow!("load an Elixir bot first")),
                            },
                        };
                        let response =
                            response.unwrap_or_else(|error| Response::Error(format!("{error:#}")));
                        if send.send(response).is_err() {
                            break;
                        }
                        context.request_repaint();
                    }
                    if let Some(bot) = bot {
                        let _ = bot.shutdown().await;
                    }
                });
            })?;
        Ok(Self {
            thread: Some((requests, thread)),
            responses,
        })
    }

    fn send(&self, request: Request) -> bool {
        self.thread
            .as_ref()
            .is_some_and(|(requests, _)| requests.try_send(request).is_ok())
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some((requests, thread)) = self.thread.take() {
            drop(requests);
            let _ = thread.join();
        }
    }
}

enum State {
    Loading,
    Ready,
    Drawing,
    Failed(String),
}

pub struct App {
    worker: Worker,
    garden: Garden,
    state: State,
    playing: bool,
    show_controls: bool,
    linked_processes: Option<usize>,
    next_frame: Instant,
    filename: String,
    origin: Cell,
    direction: Direction,
    count: u8,
}

impl App {
    pub fn new(
        cc: &eframe::CreationContext<'_>,
        runtime: Runtime,
        script: Script,
        emitters: Emitters,
    ) -> Result<Self> {
        let mut visuals = egui::Visuals::dark();
        visuals.panel_fill = CHROME;
        visuals.widgets.noninteractive.bg_stroke = Stroke::new(1.0, DIVIDER);
        visuals.selection.bg_fill = Color32::from_rgb(58, 77, 95);
        visuals.selection.stroke = Stroke::new(1.0, TEXT);
        visuals.override_text_color = Some(TEXT);
        visuals.widgets.inactive.weak_bg_fill = Color32::from_rgb(39, 51, 66);
        visuals.widgets.hovered.weak_bg_fill = Color32::from_rgb(55, 70, 87);
        visuals.widgets.hovered.bg_stroke = Stroke::new(1.0, ACCENT);
        cc.egui_ctx.set_visuals(visuals);
        let filename = script.filename().to_string_lossy().into_owned();
        let worker = Worker::spawn(cc.egui_ctx.clone(), runtime, script)?;
        let mut garden = Garden::new();
        garden.emitters = emitters;
        let mut app = Self {
            worker,
            garden,
            state: State::Ready,
            playing: true,
            show_controls: true,
            linked_processes: None,
            next_frame: Instant::now(),
            filename,
            origin: (7, 14),
            direction: Direction::EAST,
            count: 16,
        };
        app.reload();
        Ok(app)
    }

    fn request(&mut self, request: Request) {
        let state = match &request {
            Request::Reload => State::Loading,
            Request::Frame(_) => State::Drawing,
        };
        self.state = if self.worker.send(request) {
            state
        } else {
            State::Failed("The VM worker is unavailable".into())
        };
    }

    fn reload(&mut self) {
        self.playing = true;
        self.linked_processes = None;
        let emitters = self.garden.emitters;
        self.garden = Garden::new();
        self.garden.emitters = emitters;
        self.request(Request::Reload);
    }

    fn step(&mut self) {
        if matches!(self.state, State::Ready) {
            self.garden.advance();
            self.next_frame = Instant::now() + FRAME_INTERVAL;
            self.request(Request::Frame(bot::view(&self.garden)));
        }
    }

    fn update(&mut self, context: &egui::Context) {
        match self.worker.responses.try_recv() {
            Ok(Response::Loaded) => self.state = State::Ready,
            Ok(Response::Frame(frame)) => {
                self.linked_processes = Some(frame.linked_processes);
                self.garden.apply(frame);
                self.state = State::Ready;
            }
            Ok(Response::Error(message)) => {
                self.playing = false;
                self.state = State::Failed(message);
            }
            Err(mpsc::TryRecvError::Disconnected) => {
                self.state = State::Failed("The VM worker exited".into());
            }
            Err(mpsc::TryRecvError::Empty) => {}
        }

        let (toggle, step, reload, toggle_controls) = context.input_mut(|keys| {
            (
                keys.consume_key(egui::Modifiers::NONE, Key::Space),
                keys.consume_key(egui::Modifiers::NONE, Key::ArrowRight),
                keys.consume_key(egui::Modifiers::NONE, Key::R),
                keys.consume_key(egui::Modifiers::NONE, Key::H),
            )
        });
        if toggle && self.can_play() {
            self.playing = !self.playing;
        }
        if step && self.can_play() {
            self.playing = false;
            self.step();
        }
        if reload && self.can_reload() {
            self.reload();
        }
        if toggle_controls {
            self.show_controls = !self.show_controls;
        }
    }

    fn play(&mut self, context: &egui::Context) {
        if self.playing && matches!(self.state, State::Ready) {
            let delay = self.next_frame.saturating_duration_since(Instant::now());
            if delay.is_zero() {
                self.step();
            } else {
                context.request_repaint_after(delay);
            }
        }
    }

    fn can_play(&self) -> bool {
        matches!(self.state, State::Ready | State::Drawing)
    }

    fn can_reload(&self) -> bool {
        matches!(self.state, State::Ready | State::Failed(_))
    }

    fn fire(&mut self) {
        self.garden.fire(self.origin, self.direction, self.count);
    }

    fn toolbar(&mut self, ui: &mut Ui) {
        ui.spacing_mut().interact_size.y = 28.0;
        ui.horizontal(|ui| {
            let playback = if self.playing && self.can_play() {
                "Pause"
            } else {
                "Play"
            };
            if ui
                .add_enabled(
                    self.can_play(),
                    egui::Button::new(playback).min_size(Vec2::new(68.0, 28.0)),
                )
                .on_hover_text("Space to play or pause")
                .clicked()
            {
                self.playing = !self.playing;
            }
            if ui
                .add_enabled(
                    self.can_play(),
                    egui::Button::new("Step").min_size(Vec2::new(56.0, 28.0)),
                )
                .on_hover_text("Right Arrow to advance one frame")
                .clicked()
            {
                self.playing = false;
                self.step();
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if ui
                    .button("Hide controls")
                    .on_hover_text("Press H to hide or show controls")
                    .clicked()
                {
                    self.show_controls = false;
                    ui.ctx().request_repaint();
                }
                if ui
                    .add_enabled(self.can_reload(), egui::Button::new("Reload script"))
                    .on_hover_text("R to reload in a fresh VM")
                    .clicked()
                {
                    self.reload();
                }
                ui.add(
                    egui::Label::new(RichText::new(&self.filename).monospace().color(MUTED))
                        .truncate(),
                )
                .on_hover_text(&self.filename);
            });
        });
    }

    fn status_bar(&self, ui: &mut Ui) {
        ui.horizontal(|ui| {
            let (status, color) = match &self.state {
                State::Loading => ("Loading Elixir", MUTED),
                State::Failed(_) => ("Error", ERROR),
                _ if self.playing => ("Running", TEXT),
                _ => ("Paused", ACCENT),
            };
            ui.label(RichText::new(status).color(color));
            ui.separator();
            ui.label(
                RichText::new(format!("Frame {}", self.garden.tick))
                    .monospace()
                    .color(MUTED),
            );
            if self.can_play()
                && let Some(count) = self.linked_processes
            {
                ui.separator();
                ui.label(RichText::new(format!("{count} linked OTP processes")).color(MUTED));
            }

            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.label(
                    RichText::new(format!("Cell {:02}, {:02}", self.origin.0, self.origin.1))
                        .monospace()
                        .color(MUTED),
                );
            });
        });
    }

    fn controls(&mut self, ui: &mut Ui) {
        ui.spacing_mut().item_spacing.y = 8.0;
        ui.spacing_mut().interact_size.y = 26.0;

        if let State::Failed(message) = &self.state {
            egui::CollapsingHeader::new(RichText::new("Error details").color(ERROR)).show(
                ui,
                |ui| {
                    ui.label(RichText::new(message).monospace());
                },
            );
            ui.separator();
        }

        ui.label(RichText::new("Automatic fire").size(14.0).strong());
        let emitters = &mut self.garden.emitters;
        egui::ComboBox::from_id_salt("pattern")
            .width(ui.available_width())
            .selected_text(emitters.pattern.label())
            .show_ui(ui, |ui| {
                for pattern in Pattern::ALL {
                    ui.selectable_value(&mut emitters.pattern, pattern, pattern.label());
                }
            });
        ui.add_enabled_ui(emitters.pattern != Pattern::Manual, |ui| {
            ui.horizontal(|ui| {
                ui.label("Emitters");
                for count in 1..=4 {
                    ui.selectable_value(&mut emitters.count, count, count.to_string());
                }
            });
        });

        ui.add_space(12.0);
        ui.separator();
        ui.add_space(4.0);
        self.manual_burst(ui);

        ui.add_space(12.0);
        ui.separator();
        ui.collapsing("Field key", |ui| {
            ui.label(RichText::new("Lines show messages between workers. Shield arcs show charge, and dots show health. Gold diagonals show raised mirrors.").color(MUTED));
        });
    }

    fn manual_burst(&mut self, ui: &mut Ui) {
        ui.label(RichText::new("Manual burst").size(14.0).strong());
        ui.horizontal_wrapped(|ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            for (label, direction) in [
                ("North", Direction::NORTH),
                ("East", Direction::EAST),
                ("South", Direction::SOUTH),
                ("West", Direction::WEST),
            ] {
                ui.selectable_value(&mut self.direction, direction, label);
            }
        });
        ui.horizontal(|ui| {
            let label = ui.label("Pulses");
            let value_width = ui.spacing().interact_size.x + ui.spacing().item_spacing.x;
            ui.spacing_mut().slider_width = (ui.available_width() - value_width).max(1.0);
            ui.add(egui::Slider::new(&mut self.count, 1..=32))
                .labelled_by(label.id);
        });
        let button = egui::Button::new(RichText::new("Fire burst").color(ACCENT))
            .min_size(Vec2::new(ui.available_width(), 30.0));
        if ui
            .add_enabled(self.can_play(), button)
            .on_hover_text("Fire from the selected cell. Clicking a cell also fires.")
            .clicked()
        {
            self.fire();
        }
    }

    fn control_panels(&mut self, ui: &mut Ui) {
        let bar = egui::Frame::new()
            .fill(CHROME)
            .inner_margin(egui::Margin::symmetric(16, 8));
        egui::Panel::top("toolbar")
            .frame(bar)
            .show(ui, |ui| self.toolbar(ui));
        egui::Panel::bottom("status")
            .frame(bar)
            .show(ui, |ui| self.status_bar(ui));
        egui::Panel::right("inspector")
            .resizable(false)
            .exact_size(INSPECTOR_WIDTH)
            .frame(bar.inner_margin(egui::Margin::symmetric(16, 16)))
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| self.controls(ui));
            });
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut Ui, _frame: &mut eframe::Frame) {
        self.update(ui.ctx());
        if self.show_controls {
            self.control_panels(ui);
        }

        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(WORKSPACE)
                    .inner_margin(egui::Margin::same(14)),
            )
            .show(ui, |ui| {
                let side = ui.available_width().min(ui.available_height()).max(1.0);
                ui.centered_and_justified(|ui| {
                    if let Some(cell) =
                        canvas::draw(ui, side, &self.garden, self.origin, self.direction)
                    {
                        self.origin = cell;
                        if self.can_play() {
                            self.fire();
                        }
                    }
                });
            });

        self.play(ui.ctx());
    }
}

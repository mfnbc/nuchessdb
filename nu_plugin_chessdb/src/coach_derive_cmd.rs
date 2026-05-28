use nu_plugin::{EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value};
use std::collections::HashMap;
use shakmaty::Position;
use crate::ChessdbPlugin;
use crate::PLUGIN_CATEGORY;

pub struct DeriveCoachSignals;

impl PluginCommand for DeriveCoachSignals {
    type Plugin = ChessdbPlugin;
    fn name(&self) -> &str { "chessdb derive-coach-signals" }
    fn description(&self) -> &str {
        "Compute per-player baselines, state encodings, and anomaly alerts from a table of moves"
    }
    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![
                (Type::List(Box::new(Type::Record(vec![].into()))), Type::Record(vec![].into())),
            ])
            .named("min-games", nu_protocol::SyntaxShape::Int, "min samples for baseline trust (default 25)", None)
            .category(Category::Custom(PLUGIN_CATEGORY.into()))
    }
    fn run(&self, _plugin: &Self::Plugin, _engine: &nu_plugin::EngineInterface, call: &EvaluatedCall, input: PipelineData) -> Result<PipelineData, LabeledError> {
        let span = call.head;
        let min_games: i64 = call.get_flag("min-games")?.unwrap_or(25);
        let input_value = input.into_value(span)?;

        let rows: Vec<MoveRecord> = match input_value {
            Value::List { vals, .. } => vals.iter().filter_map(parse_move_record).collect(),
            _ => return Err(LabeledError::new("Expected list of records with game_id, ply, fen, hugm_score")),
        };

        let states = encode_move_states(&rows, span);
        let baselines = compute_baselines(&rows, &states);
        let anomalies = detect_anomalies(&rows, &states, &baselines, min_games, span);
        let (transitions, transition_anomalies) = compute_transitions(&rows, &states, min_games, span);
        let (states_out, baselines_out) = format_results(&states, &baselines, &anomalies, span);

        Ok(PipelineData::Value(Value::record(nu_protocol::record! {
            "states" => states_out,
            "baselines" => baselines_out,
            "anomalies" => Value::list(anomalies, span),
            "transitions" => Value::list(transitions, span),
            "transition_anomalies" => Value::list(transition_anomalies, span),
        }, span), None))
    }
}

struct MoveRecord { game_id: String, ply: i64, fen: String, hugm_score: i64, player: String, color: String, state_id: Option<u16> }

fn parse_move_record(v: &Value) -> Option<MoveRecord> {
    let rec = v.as_record().ok()?;
    let hugm_score = rec.get("hugm_score")
        .and_then(|v| v.as_int().ok())
        .unwrap_or(0) as i64;
    let player = rec.get("player").and_then(|v| v.as_str().ok()).unwrap_or("unknown").to_string();
    let color = rec.get("color").and_then(|v| v.as_str().ok()).unwrap_or("unknown").to_string();
    let state_id = rec.get("state_id").and_then(|v| v.as_int().ok()).map(|x| x as u16);
    Some(MoveRecord {
        game_id: format!("{}", rec.get("game_id")?.as_int().ok()?),
        ply: rec.get("ply")?.as_int().ok()? as i64,
        fen: rec.get("fen")?.as_str().ok()?.to_string(),
        hugm_score,
        player,
        color,
        state_id,
    })
}

/// Encode move states, using pre-computed state_id from ingestion when available.
/// Falls back to full FEN→shakmaty→eval→encode_state path only for rows missing state_id.
fn encode_move_states(rows: &[MoveRecord], span: nu_protocol::Span) -> Vec<Value> {
    rows.iter().map(|r| {
        // Fast path: state_id already computed during process_corpus ingestion
        if let Some(sid) = r.state_id {
            let phase = (sid & 0x3) as u8;
            return Value::record(nu_protocol::record! {
                "game_id"        => Value::string(&r.game_id, span),
                "ply"            => Value::int(r.ply, span),
                "state_id"       => Value::int(sid as i64, span),
                "phase_bucket"   => Value::int(phase as i64, span),
                "king_exposed"   => Value::bool((sid >> 5) & 1 != 0, span),
                "has_fork"       => Value::bool((sid >> 7) & 1 != 0, span),
                "has_pin"        => Value::bool((sid >> 8) & 1 != 0, span),
                "has_hanging"    => Value::bool((sid >> 9) & 1 != 0, span),
                "has_outpost"    => Value::bool((sid >> 10) & 1 != 0, span),
                "has_open_file"  => Value::bool((sid >> 11) & 1 != 0, span),
                "has_passed_pawn"=> Value::bool((sid >> 12) & 1 != 0, span),
                "has_skewer"     => Value::bool((sid >> 13) & 1 != 0, span),
                "has_discovered" => Value::bool((sid >> 14) & 1 != 0, span),
            }, span);
        }
        // Slow path: re-parse FEN (fallback for rows without state_id)
        let fen = match shakmaty::fen::Fen::from_ascii(r.fen.as_bytes()) {
            Ok(f) => f, Err(_) => return Value::record(nu_protocol::record! {
                "game_id" => Value::string(&r.game_id, span),
                "ply" => Value::int(r.ply, span),
                "state_id" => Value::int(0, span),
                "error" => Value::string("invalid FEN", span),
            }, span),
        };
        let chess: shakmaty::Chess = match fen.into_position(shakmaty::CastlingMode::Standard) {
            Ok(c) => c, Err(_) => return Value::record(nu_protocol::record! {
                "game_id" => Value::string(&r.game_id, span),
                "ply" => Value::int(r.ply, span),
                "state_id" => Value::int(0, span),
                "error" => Value::string("invalid position", span),
            }, span),
        };
        let phase = crate::eval::compute_phase(chess.board());
        let groups = crate::eval::compute_groups(&chess, phase, 0);
        let sensor = crate::eval::build_sensor_report(chess.board(), &r.fen, &groups, &chess, phase, None);
        let state = crate::eval::encode_state(&sensor, &groups, phase);
        Value::record(nu_protocol::record! {
            "game_id"         => Value::string(&r.game_id, span),
            "ply"             => Value::int(r.ply, span),
            "state_id"        => Value::int(state.state_id as i64, span),
            "phase_bucket"    => Value::int(state.phase as i64, span),
            "king_exposed"    => Value::bool(state.king_exposed, span),
            "has_fork"        => Value::bool(state.has_fork, span),
            "has_pin"         => Value::bool(state.has_pin, span),
            "has_hanging"     => Value::bool(state.has_hanging, span),
            "has_outpost"     => Value::bool(state.has_outpost, span),
            "has_open_file"   => Value::bool(state.open_file, span),
            "has_passed_pawn" => Value::bool(state.has_passed_pawn, span),
            "has_skewer"      => Value::bool(state.has_skewer, span),
            "has_discovered"  => Value::bool(state.has_discovered, span),
        }, span)
    }).collect()
}

#[derive(Debug, Clone)]
struct Welford { count: f64, mean: f64, m2: f64 }

impl Welford {
    fn new() -> Self { Welford { count: 0.0, mean: 0.0, m2: 0.0 } }
    fn update(&mut self, value: f64) {
        self.count += 1.0;
        let delta = value - self.mean;
        self.mean += delta / self.count;
        let delta2 = value - self.mean;
        self.m2 += delta * delta2;
    }
    fn std_dev(&self) -> f64 {
        if self.count < 2.0 { 1.0 } else { (self.m2 / (self.count - 1.0)).sqrt().max(1.0) }
    }
}

fn get_field_i64(v: &Value, key: &str) -> Option<i64> {
    v.as_record().ok().and_then(|r| r.get(key)).and_then(|v| v.as_int().ok()).map(|x| x as i64)
}

fn get_field_bool(v: &Value, key: &str) -> bool {
    v.as_record().ok().and_then(|r| r.get(key)).and_then(|v| v.as_bool().ok()).unwrap_or(false)
}

fn compute_baselines(rows: &[MoveRecord], states: &[Value]) -> HashMap<(String, u8, String), (f64, f64)> {
    let mut prev_score: HashMap<(String, String), i64> = HashMap::new(); // (player, game_id) → prev_score
    let mut baselines: HashMap<(String, u8, String), Welford> = HashMap::new(); // (player, phase, concept) → stats
    for (i, row) in rows.iter().enumerate() {
        let phase_bucket = states.get(i).and_then(|v| get_field_i64(v, "phase_bucket")).unwrap_or(1) as u8;
        let game_key = (row.player.clone(), row.game_id.clone());
        let (delta, _signed_delta) = if let Some(prev) = prev_score.get(&game_key).copied() {
            let sd = row.hugm_score - prev;
            ((sd.abs() as f64), sd)
        } else { (0.0, 0) };
        prev_score.insert(game_key.clone(), row.hugm_score);
        if delta < 1.0 { continue; }
        // Always track overall eval swing
        baselines.entry((row.player.clone(), phase_bucket, "hugm_delta".into()))
            .or_insert_with(Welford::new).update(delta);
        // Per-concept baselines: eval swing when each tactical/positional pattern is present.
        let s = &states[i];
        for (concept, flag) in &[
            ("fork",             "has_fork"),
            ("pin",              "has_pin"),
            ("hanging_piece",    "has_hanging"),
            ("outpost",          "has_outpost"),
            ("open_file",        "has_open_file"),
            ("passed_pawn",      "has_passed_pawn"),
            ("skewer",           "has_skewer"),
            ("discovered_attack","has_discovered"),
        ] {
            if get_field_bool(s, flag) {
                baselines.entry((row.player.clone(), phase_bucket, concept.to_string()))
                    .or_insert_with(Welford::new).update(delta);
            }
        }
    }
    baselines.into_iter().map(|((p, ph, cn), w)| ((p, ph, cn), (w.mean, w.std_dev()))).collect()
}

fn detect_anomalies(rows: &[MoveRecord], states: &[Value], baselines: &HashMap<(String, u8, String), (f64, f64)>, _min_games: i64, span: nu_protocol::Span) -> Vec<Value> {
    let mut prev_score: HashMap<(String, String), i64> = HashMap::new();
    let mut results = Vec::new();
    for (i, row) in rows.iter().enumerate() {
        let game_key = (row.player.clone(), row.game_id.clone());
        let (delta, signed_delta) = if let Some(prev) = prev_score.get(&game_key).copied() {
            let sd = row.hugm_score - prev;
            ((sd.abs() as f64), sd)
        } else { (0.0, 0) };
        prev_score.insert(game_key.clone(), row.hugm_score);
        if delta < 5.0 { continue; }
        let phase_bucket = states.get(i).and_then(|v| get_field_i64(v, "phase_bucket")).unwrap_or(1) as u8;
        let state_id = states.get(i).and_then(|v| get_field_i64(v, "state_id")).unwrap_or(0);
        let s = &states[i];
        let check_concepts: [(&str, bool); 9] = [
            ("hugm_delta",       true),
            ("fork",             get_field_bool(s, "has_fork")),
            ("pin",              get_field_bool(s, "has_pin")),
            ("hanging_piece",    get_field_bool(s, "has_hanging")),
            ("outpost",          get_field_bool(s, "has_outpost")),
            ("open_file",        get_field_bool(s, "has_open_file")),
            ("passed_pawn",      get_field_bool(s, "has_passed_pawn")),
            ("skewer",           get_field_bool(s, "has_skewer")),
            ("discovered_attack",get_field_bool(s, "has_discovered")),
        ];
        for (concept, should_check) in &check_concepts {
            if !should_check { continue; }
            let key = (row.player.clone(), phase_bucket, concept.to_string());
            if let Some((mean, std)) = baselines.get(&key) {
                let z = (delta - mean) / std;
                if z > 2.0 {
                    // If the moving side is White and score dropped → hurt.
                    // If the moving side is Black and score rose → hurt (White gained).
                    let hurt_player = (row.color == "white" && signed_delta < 0)
                        || (row.color == "black" && signed_delta > 0);
                    results.push(Value::record(nu_protocol::record! {
                        "player" => Value::string(&row.player, span),
                        "game_id" => Value::string(&row.game_id, span),
                        "ply" => Value::int(row.ply, span),
                        "state_id" => Value::int(state_id, span),
                        "anomaly_type" => Value::string("z_score", span),
                        "concept_name" => Value::string(*concept, span),
                        "z_score" => Value::float(z, span),
                        "severity" => Value::float(delta, span),
                        "signed_delta" => Value::float(signed_delta as f64, span),
                        "hurt_player" => Value::bool(hurt_player, span),
                    }, span));
                }
            }
        }
    }
    results
}

fn compute_transitions(rows: &[MoveRecord], states: &[Value], _min_games: i64, span: nu_protocol::Span) -> (Vec<Value>, Vec<Value>) {
    let mut transitions: HashMap<(i64, i64), (i64, i64)> = HashMap::new(); // (state_from, state_to) → (total, blunders)
    let mut prev: Option<(String, i64, i64)> = None; // (game_id, state_id, score)

    for (i, row) in rows.iter().enumerate() {
        let state_id = states.get(i).and_then(|v| get_field_i64(v, "state_id")).unwrap_or(0);
        if let Some((pg, prev_state, pscore)) = prev.take() {
            if pg == row.game_id {
                let delta = row.hugm_score - pscore;
                let entry = transitions.entry((prev_state, state_id)).or_insert((0, 0));
                entry.0 += 1;
                if delta < -200 { entry.1 += 1; } // blunder: lost > 200cp
            }
        }
        prev = Some((row.game_id.clone(), state_id, row.hugm_score));
    }

    let mut trans_list = Vec::new();
    let mut trans_anomalies = Vec::new();

    for ((from, to), (total, blunders)) in &transitions {
        let risk = if *total > 0 { *blunders as f64 / *total as f64 } else { 0.0 };
        trans_list.push(Value::record(nu_protocol::record! {
            "state_from" => Value::int(*from, span),
            "state_to" => Value::int(*to, span),
            "total_count" => Value::int(*total, span),
            "blunder_count" => Value::int(*blunders, span),
            "blunder_risk" => Value::float(risk, span),
        }, span));

        if risk > 0.25 && *total >= 3 {
            trans_anomalies.push(Value::record(nu_protocol::record! {
                "state_from" => Value::int(*from, span),
                "state_to" => Value::int(*to, span),
                "anomaly_type" => Value::string("transition_risk", span),
                "blunder_risk" => Value::float(risk, span),
                "total_count" => Value::int(*total, span),
                "blunder_count" => Value::int(*blunders, span),
            }, span));
        }
    }

    (trans_list, trans_anomalies)
}

fn format_results(states: &[Value], baselines: &HashMap<(String, u8, String), (f64, f64)>, _anomalies: &[Value], span: nu_protocol::Span) -> (Value, Value) {
    let bl: Vec<Value> = baselines.iter().map(|((player, ph, cn), (mean, std))| {
        Value::record(nu_protocol::record! {
            "player" => Value::string(player, span),
            "phase_bucket" => Value::int(*ph as i64, span),
            "concept" => Value::string(cn, span),
            "mean" => Value::float(*mean, span),
            "std" => Value::float(*std, span),
        }, span)
    }).collect();
    (Value::list(states.to_vec(), span), Value::list(bl, span))
}
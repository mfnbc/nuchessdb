use crate::eval::position::EvalGroups;

/// A named concept detected in a chess position, with severity and ELO threshold.
#[derive(Debug, serde::Serialize)]
pub struct Concept {
    pub name: String,
    pub severity: i64,
    pub side: String,
    pub phrase: String,
    pub elo_min: i32,
}

/// Extract all detected concepts from an EvalGroups, ranked by severity descending.
pub fn extract_concepts(groups: &EvalGroups, _side_to_move: &str) -> Vec<Concept> {
    let mut concepts = Vec::new();

    // --- Material (ELO 600+) ---
    let material_imbalance = groups.material_total.value;
    if material_imbalance.abs() > 50 {
        let (side, phrase) = if material_imbalance > 0 {
            ("white", format!("White is up {} centipawns in material", material_imbalance))
        } else {
            ("black", format!("Black is up {} centipawns in material", -material_imbalance))
        };
        concepts.push(Concept { name: "material_imbalance".into(), severity: material_imbalance.abs(), side: side.into(), phrase, elo_min: 600 });
    }

    // Bishop pair (ELO 1800+)
    let bp = groups.material.terms.get("white_bishops").and_then(|v| v.as_i64()).unwrap_or(0);
    let bb = groups.material.terms.get("black_bishops").and_then(|v| v.as_i64()).unwrap_or(0);
    if bp >= 2 { concepts.push(Concept { name: "bishop_pair".into(), severity: 40, side: "white".into(), phrase: "White has the bishop pair".into(), elo_min: 1800 }); }
    if bb >= 2 { concepts.push(Concept { name: "bishop_pair".into(), severity: 40, side: "black".into(), phrase: "Black has the bishop pair".into(), elo_min: 1800 }); }

    // Tactical: forks (1000+), pins (1200+), skewers (1200+), discovered (1400+)
    for (key, label, weight, elo, name) in [
        ("forks_us","white",80i64,1000,"fork"),
        ("forks_them","black",80,1000,"fork"),
        ("pins_us","white",50,1200,"pin"),
        ("pins_them","black",50,1200,"pin"),
        ("skewers_us","white",45,1200,"skewer"),
        ("skewers_them","black",45,1200,"skewer"),
        ("discovered_us","white",60,1400,"discovered_attack"),
        ("discovered_them","black",60,1400,"discovered_attack"),
    ] {
        if let Some(v) = groups.tactical.terms.get(key).and_then(|v| v.as_i64()) {
            if v > 0 {
                concepts.push(Concept { name: name.into(), severity: v * weight, side: label.into(), phrase: format!("{} has {} {}(s)", label, v, name), elo_min: elo });
            }
        }
    }

    // Pawn structure (ELO 1600+)
    for (key, label, name) in [
        ("isolated_us","white","isolated_pawn"), ("isolated_them","black","isolated_pawn"),
        ("doubled_us","white","doubled_pawn"), ("doubled_them","black","doubled_pawn"),
    ] {
        if let Some(v) = groups.pawn_structure.terms.get(key).and_then(|v| v.as_i64()) {
            if v > 0 { concepts.push(Concept { name: name.into(), severity: v * 30, side: label.into(), phrase: format!("{} has {} {}(s)", label, v, name), elo_min: 1600 }); }
        }
    }

    // Pawn majority (1800+) and breaks (1800+)
    if let Some(v) = groups.pawn_structure.terms.get("majority_us").and_then(|v| v.as_i64()) {
        if v > 0 { concepts.push(Concept { name: "pawn_majority".into(), severity: v * 20, side: "white".into(), phrase: "White has a pawn majority".into(), elo_min: 1800 }); }
    }
    if let Some(v) = groups.pawn_structure.terms.get("majority_them").and_then(|v| v.as_i64()) {
        if v > 0 { concepts.push(Concept { name: "pawn_majority".into(), severity: v * 20, side: "black".into(), phrase: "Black has a pawn majority".into(), elo_min: 1800 }); }
    }
    if let Some(v) = groups.pawn_structure.terms.get("pawn_breaks").and_then(|v| v.as_i64()) {
        if v > 0 { concepts.push(Concept { name: "pawn_break".into(), severity: v * 30, side: "white".into(), phrase: format!("{} pawn break candidate(s)", v), elo_min: 1800 }); }
    }

    // Minority attack (ELO 2000+)
    if let Some(v) = groups.pawn_structure.terms.get("minority_attack").and_then(|v| v.as_i64()) {
        if v > 0 { concepts.push(Concept { name: "minority_attack".into(), severity: v * 35, side: "white".into(), phrase: "White has a minority attack".into(), elo_min: 2000 }); }
    }

    // Outposts (ELO 1600+)
    for (key, label) in [("outposts_us","white"), ("outposts_them","black")] {
        if let Some(v) = groups.piece_activity.terms.get(key).and_then(|v| v.as_i64()) {
            if v > 0 { concepts.push(Concept { name: "outpost".into(), severity: v * 40, side: label.into(), phrase: format!("{} has {} outpost(s)", label, v), elo_min: 1600 }); }
        }
    }

    // Rook activity (ELO 1400+)
    if let Some(v) = groups.piece_activity.terms.get("rook_open_file_us").and_then(|v| v.as_i64()) {
        if v > 0 { concepts.push(Concept { name: "rook_open_file".into(), severity: v * 25, side: "white".into(), phrase: "White has rook(s) on open file(s)".into(), elo_min: 1400 }); }
    }
    if let Some(v) = groups.piece_activity.terms.get("rook_seventh_us").and_then(|v| v.as_i64()) {
        if v > 0 { concepts.push(Concept { name: "rook_seventh".into(), severity: v * 30, side: "white".into(), phrase: "White has a rook on the 7th rank".into(), elo_min: 1400 }); }
    }

    // King safety (ELO 1000-1400+)
    if let Some(true) = groups.king_safety.terms.get("in_check").and_then(|v| v.as_bool()) {
        concepts.push(Concept { name: "king_in_check".into(), severity: 100, side: "neutral".into(), phrase: "The king is in check!".into(), elo_min: 1000 });
    }
    if groups.king_safety.blended.abs() > 40 {
        let (side, phrase) = if groups.king_safety.blended < 0 {
            ("white", "White's king is exposed".into())
        } else { ("black", "Black's king is exposed".into()) };
        concepts.push(Concept { name: "king_exposed".into(), severity: groups.king_safety.blended.abs(), side: side.into(), phrase, elo_min: 1400 });
    }

    // Passed pawns (ELO 1400+)
    for (key, label) in [("passed_us","white"), ("passed_them","black")] {
        if let Some(v) = groups.passed_pawns.terms.get(key).and_then(|v| v.as_i64()) {
            if v > 0 { concepts.push(Concept { name: "passed_pawn".into(), severity: v * 50, side: label.into(), phrase: format!("{} has {} passed pawn(s)", label, v), elo_min: 1400 }); }
        }
    }

    // Development (ELO 1400+)
    if groups.development.blended.abs() > 20 {
        let (side, phrase) = if groups.development.blended > 0 {
            ("white", "White has a development advantage".into())
        } else { ("black", "Black has a development advantage".into()) };
        concepts.push(Concept { name: "development".into(), severity: groups.development.blended.abs(), side: side.into(), phrase, elo_min: 1400 });
    }

    // Center control (ELO 1800+)
    if let Some(v) = groups.vector_features.terms.get("center_control_us").and_then(|v| v.as_i64()) {
        if v.abs() > 15 {
            let (side, phrase) = if v > 0 { ("white", "White controls the center") } else { ("black", "Black controls the center") };
            concepts.push(Concept { name: "center_control".into(), severity: v.abs(), side: side.into(), phrase: phrase.into(), elo_min: 1800 });
        }
    }

    concepts.sort_by(|a, b| b.severity.cmp(&a.severity));
    concepts
}

/// Filter concepts visible to a player at the given ELO.
pub fn concepts_for_elo(concepts: &[Concept], elo: i32) -> Vec<&Concept> {
    concepts.iter().filter(|c| c.elo_min <= elo).collect()
}

/// A gated issue scored by magnitude × severity × elo_relevance × confidence.
#[derive(Debug, Clone, serde::Serialize)]
pub struct GatedIssue {
    pub name: String,
    pub severity: i64,
    pub elo_min: i32,
    pub magnitude: f64,
    pub elo_relevance: f64,
    pub confidence: f64,
    pub score: f64,
    pub phrase: String,
    pub side: String,
}

/// Gate concepts for a single position (no delta history).
/// Ranks by severity × elo_relevance × confidence. Returns top 1-3.
pub fn rank_issues_for_position(concepts: &[Concept], player_elo: i32) -> Vec<GatedIssue> {
    let mut issues: Vec<GatedIssue> = concepts.iter().filter_map(|c| {
        let elo_relevance = if c.elo_min <= player_elo { 1.0 }
            else { 0.5f64.powf((c.elo_min - player_elo) as f64 / 200.0) };
        let confidence = match c.name.as_str() {
            "fork"|"pin"|"skewer"|"discovered_attack"|"king_in_check" => 1.0,
            "hanging_piece"|"passed_pawn"|"material_imbalance" => 0.9,
            "rook_open_file"|"rook_seventh"|"outpost"|"development" => 0.8,
            "king_exposed"|"isolated_pawn"|"doubled_pawn" => 0.7,
            _ => 0.6,
        };
        let score = c.severity as f64 * elo_relevance * confidence;
        if score < 1.0 { return None; }
        Some(GatedIssue { name: c.name.clone(), severity: c.severity, elo_min: c.elo_min,
            magnitude: 1.0, elo_relevance, confidence, score,
            phrase: c.phrase.clone(), side: c.side.clone() })
    }).collect();
    issues.sort_by(|a,b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    let has_critical = issues.iter().any(|i| i.severity >= 80 && i.elo_min <= 1000 && i.score > 10.0);
    if has_critical { issues.retain(|i| i.elo_min <= 1200); }
    issues.truncate(3);
    issues
}

/// Gate concepts for a player based on evaluation deltas between plies.
/// Returns top 1-3 issues. If a critical low-ELO issue exists, suppresses higher-level coaching.
pub fn rank_issues_for_player(
    concepts: &[Concept],
    player_elo: i32,
    deltas: &std::collections::HashMap<String, f64>,
) -> Vec<GatedIssue> {
    let mut issues: Vec<GatedIssue> = concepts.iter().filter_map(|c| {
        let magnitude = deltas.get(&c.name).copied().unwrap_or(0.0);
        if magnitude < 1.0 { return None; }
        let elo_relevance = if c.elo_min <= player_elo { 1.0 }
            else { 0.5f64.powf((c.elo_min - player_elo) as f64 / 200.0) };
        let confidence = match c.name.as_str() {
            "fork"|"pin"|"skewer"|"discovered_attack"|"king_in_check" => 1.0,
            "hanging_piece"|"passed_pawn"|"material_imbalance" => 0.9,
            "rook_open_file"|"rook_seventh"|"outpost"|"development" => 0.8,
            "king_exposed"|"isolated_pawn"|"doubled_pawn" => 0.7,
            _ => 0.6,
        };
        let score = magnitude * c.severity as f64 * elo_relevance * confidence;
        Some(GatedIssue { name: c.name.clone(), severity: c.severity, elo_min: c.elo_min,
            magnitude, elo_relevance, confidence, score, phrase: c.phrase.clone(), side: c.side.clone() })
    }).collect();
    issues.sort_by(|a,b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    let has_critical = issues.iter().any(|i| i.severity >= 80 && i.elo_min <= 1000 && i.score > 10.0);
    if has_critical { issues.retain(|i| i.elo_min <= 1200); }
    issues.truncate(3);
    issues
}

// ── Markov StateVector: compact position encoding for transition tracking ──

/// Compact state ID for a chess position. Deterministic — same position → same state.
/// Encodes phase, material balance, tactical flags, and positional features into ~13 bits.
#[derive(Debug, Clone, Copy, Default, serde::Serialize)]
pub struct StateVector {
    pub state_id: u16,
    pub phase: u8,
    pub material_sign: i8,
    pub king_exposed: bool,
    pub in_check: bool,
    pub has_fork: bool,
    pub has_pin: bool,
    pub has_hanging: bool,
    pub has_outpost: bool,
    pub open_file: bool,
    pub has_passed_pawn: bool,
}

/// Encode a position into a compact state ID from the sensor report and groups.
pub fn encode_state(sensor: &crate::eval::sensor::SensorReport, groups: &crate::eval::position::EvalGroups, phase: u8) -> StateVector {
    let phase_bits = match phase {
        0..=8 => 0u8,      // deep endgame
        9..=16 => 1,       // endgame
        17..=24 => 2,      // midgame
        _ => 3,            // opening
    };

    let mat = groups.material_total.value;
    let material_sign: i8 = if mat > 300 { 2 } else if mat > 100 { 1 }
        else if mat < -300 { -2 } else if mat < -100 { -1 } else { 0 };

    let has_fork = !sensor.tactical.forks.is_empty();
    let has_pin = !sensor.tactical.pins.is_empty();
    let has_hanging = !sensor.tactical.hanging.is_empty();
    let king_exposed = sensor.positional.king_exposure.as_ref()
        .map(|k| k.attacker_count > 0).unwrap_or(false);
    let in_check = groups.king_safety.terms.get("in_check")
        .and_then(|v| v.as_bool()).unwrap_or(false);
    let has_outpost = !sensor.positional.outposts.is_empty();
    let open_file = !sensor.positional.open_files.is_empty();
    let has_passed_pawn = !sensor.positional.passed_pawns.is_empty();

    // Pack into u16 bitfield
    let mut id: u16 = 0;
    id |= (phase_bits as u16) & 0x3;          // bits 0-1
    id |= ((material_sign + 2) as u16 & 0x7) << 2; // bits 2-4 (shifted to 0-4)
    id |= (king_exposed as u16) << 5;          // bit 5
    id |= (in_check as u16) << 6;              // bit 6
    id |= (has_fork as u16) << 7;              // bit 7
    id |= (has_pin as u16) << 8;               // bit 8
    id |= (has_hanging as u16) << 9;           // bit 9
    id |= (has_outpost as u16) << 10;          // bit 10
    id |= (open_file as u16) << 11;            // bit 11
    id |= (has_passed_pawn as u16) << 12;      // bit 12

    StateVector {
        state_id: id,
        phase: phase_bits,
        material_sign,
        king_exposed,
        in_check,
        has_fork,
        has_pin,
        has_hanging,
        has_outpost,
        open_file,
        has_passed_pawn,
    }
}

// ── Elo Sensor Taxonomy: Convergence Gate ──

/// Sensor tier classification for the attenuation matrix.
/// Each tier has a fundamentally different mathematical behavior:
/// - Survival/Threat: digital switches (on/off), always active
/// - Positional: hybrid, partially attenuated by tactical chaos
/// - Strategic: analog dials, fully suppressed in unstable positions
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SensorTier {
    Survival,    // 600-1000: material imbalance, checks, hanging pieces
    Threat,      // 1000-1400: forks, pins, skewers, discovered attacks
    Positional,  // 1400-1800: outposts, open files, pawn structure
    Strategic,   // 1800-2000+: minority attack, pawn majority, bishop pair
}

/// Classify a concept name into its sensor tier.
pub fn tier_for_concept(name: &str) -> SensorTier {
    match name {
        "material_imbalance" | "king_in_check" | "hanging_piece" => SensorTier::Survival,
        "fork" | "pin" | "skewer" | "discovered_attack" => SensorTier::Threat,
        "rook_open_file" | "rook_seventh" | "outpost" | "isolated_pawn"
        | "doubled_pawn" | "passed_pawn" | "king_exposed" | "development" => SensorTier::Positional,
        "bishop_pair" | "pawn_majority" | "pawn_break" | "minority_attack" => SensorTier::Strategic,
        _ => SensorTier::Positional,
    }
}

/// Attenuation factor per tier given the chaos coefficient (0.0 = clean, 1.0 = chaotic).
/// Survival/Threat sensors are digital switches — always active regardless of chaos.
/// Positional sensors are dampened at 50% of chaos.
/// Strategic sensors are fully suppressed proportional to chaos.
pub fn attenuation(tier: SensorTier, chaos: f64) -> f64 {
    match tier {
        SensorTier::Survival => 1.0,
        SensorTier::Threat => 1.0,
        SensorTier::Positional => 1.0 - chaos * 0.5,
        SensorTier::Strategic => (1.0 - chaos).max(0.0),
    }
}

use serde::Serialize;
use crate::eval::concept_types::*;
use crate::eval::threat_graph::EvaluatedFork;

/// Full sensor report from a single position evaluation.
/// Contains all detected concepts as typed structs, ready for JSON serialization.
#[derive(Debug, Clone, Serialize, Default)]
pub struct SensorReport {
    pub fen: String,
    pub state_id: u16,
    pub material: MaterialConceptReport,
    pub tactical: TacticalReport,
    pub positional: PositionalReport,
    pub aggregated: AggregatedScores,
    /// Forks with SEE material consequence (from ThreatGraph)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub evaluated_forks: Vec<EvaluatedFork>,
    /// ELO-gated, ranked issues for coaching (from concepts.rs)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub gated_issues: Vec<crate::eval::concepts::GatedIssue>,
    /// Side to move has at least one legal move that delivers checkmate
    #[serde(default)]
    pub mate_in_1_exists: bool,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct MaterialConceptReport {
    pub balance: Option<MaterialBalance>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct TacticalReport {
    pub forks: Vec<Fork>,
    pub pins: Vec<Pin>,
    pub skewers: Vec<Skewer>,
    pub discovered: Vec<DiscoveredAttack>,
    pub hanging: Vec<HangingPiece>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct PositionalReport {
    pub outposts: Vec<Outpost>,
    pub open_files: Vec<OpenFile>,
    pub passed_pawns: Vec<PassedPawn>,
    pub doubled_pawns: Vec<DoubledPawn>,
    pub isolated_pawns: Vec<IsolatedPawn>,
    pub pawn_islands: Vec<PawnIsland>,
    pub pawn_breaks: Vec<PawnBreak>,
    pub minority_attack: Option<MinorityAttack>,
    pub king_exposure: Option<KingExposure>,
    pub development: Option<DevelopmentInfo>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct AggregatedScores {
    pub material_cp: i64,
    pub positional_cp: i64,
    pub tactical_cp: i64,
    pub total_cp: i64,
    /// Chaos coefficient 0.0–1.0: how tactically unstable the position is.
    /// Higher chaos → positional/strategic sensors are attenuated.
    pub chaos: f64,
}

/// Produce a SensorReport with typed concepts from board evaluation.
/// Populated by build_sensor_report in eval/position.rs.
impl SensorReport {
    pub fn new(fen: &str) -> Self {
        SensorReport {
            fen: fen.to_string(),
            ..Default::default()
        }
    }
}

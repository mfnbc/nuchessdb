pub mod concept_types;
pub mod concepts;
pub mod position;
pub mod sensor;

pub use position::{analyze_fen, analyze_fen_with_engine_score, compute_phase, compute_groups, build_sensor_report, PositionRecord, render_explanations, render_structured_explanations, set_weights_from_file};
pub use concepts::{encode_state, SensorTier, tier_for_concept, attenuation};

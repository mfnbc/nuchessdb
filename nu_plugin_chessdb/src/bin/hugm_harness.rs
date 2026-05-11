use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader};
use anyhow::Result;
use serde::Deserialize;

#[derive(Deserialize)]
struct InputRecord {
    id: Option<String>,
    fen: String,
    engine_score: Option<i64>,
}

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: hugm_harness <input.jsonl> <output.csv>");
        std::process::exit(2);
    }
    let input_path = &args[1];
    let output_path = &args[2];

    let input = File::open(input_path)?;
    let reader = BufReader::new(input);
    let mut wtr = csv::Writer::from_path(output_path)?;

    // header
    wtr.write_record(&[
        "id",
        "fen",
        "phase",
        "hugm_raw",
        "engine_score",
        "material_blended",
        "pawn_structure_blended",
        "piece_activity_blended",
        "king_safety_blended",
        "passed_pawns_blended",
        "development_blended",
        "vector_features_blended",
        "strategic_blended",
        "tactical_blended",
        "mobility_total",
        "mobility_knight",
        "mobility_bishop",
        "mobility_rook",
        "mobility_queen",
        "mobility_pawn",
    ])?;

    // running stats for simple linear mapping
    let mut n = 0usize;
    let mut sum_x = 0f64;
    let mut sum_y = 0f64;
    let mut sum_xx = 0f64;
    let mut sum_xy = 0f64;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() { continue; }
        let rec: InputRecord = serde_json::from_str(&line)?;
        let engine_score = rec.engine_score;
        let analysis = if let Some(es) = engine_score {
            // pass through engine score as given for record binding
            nu_plugin_chessdb::eval::analyze_fen_with_engine_score(&rec.fen, Some(es))
        } else {
            nu_plugin_chessdb::eval::analyze_fen(&rec.fen)
        };
        match analysis {
            Ok(r) => {
                let phase = r.phase as i64;
                let hugm_raw = r.final_score;
                let material = r.groups.material.blended;
                let pawn_structure = r.groups.pawn_structure.blended;
                let piece_activity = r.groups.piece_activity.blended;
                let king_safety = r.groups.king_safety.blended;
                let passed_pawns = r.groups.passed_pawns.blended;
                let development = r.groups.development.blended;
                let vector_features = r.groups.vector_features.blended;
                let strategic = r.groups.strategic.blended;
                let tactical = r.groups.tactical.blended;

                let mobility_total = r.groups.piece_activity.terms.get("mobility_total").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_knight = r.groups.piece_activity.terms.get("mobility_knight").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_bishop = r.groups.piece_activity.terms.get("mobility_bishop").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_rook = r.groups.piece_activity.terms.get("mobility_rook").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_queen = r.groups.piece_activity.terms.get("mobility_queen").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_pawn = r.groups.piece_activity.terms.get("mobility_pawn").and_then(|v| v.as_i64()).unwrap_or(0);

                wtr.write_record(&[
                    r.checks.sum_groups.to_string(), // use sum_groups as id fallback
                    r.fen.clone(),
                    phase.to_string(),
                    hugm_raw.to_string(),
                    engine_score.map(|s| s.to_string()).unwrap_or_else(|| "".to_string()),
                    material.to_string(),
                    pawn_structure.to_string(),
                    piece_activity.to_string(),
                    king_safety.to_string(),
                    passed_pawns.to_string(),
                    development.to_string(),
                    vector_features.to_string(),
                    strategic.to_string(),
                    tactical.to_string(),
                    mobility_total.to_string(),
                    mobility_knight.to_string(),
                    mobility_bishop.to_string(),
                    mobility_rook.to_string(),
                    mobility_queen.to_string(),
                    mobility_pawn.to_string(),
                ])?;

                if let Some(es) = engine_score {
                    let x = hugm_raw as f64;
                    let y = es as f64;
                    n += 1;
                    sum_x += x;
                    sum_y += y;
                    sum_xx += x * x;
                    sum_xy += x * y;
                }
            }
            Err(e) => {
                eprintln!("Error evaluating fen {}: {}", rec.fen, e);
                return Err(e);
            }
        }
    }

    wtr.flush()?;

    if n > 0 {
        let n_f = n as f64;
        let mean_x = sum_x / n_f;
        let mean_y = sum_y / n_f;
        let cov_xy = sum_xy / n_f - mean_x * mean_y;
        let var_x = sum_xx / n_f - mean_x * mean_x;
        if var_x.abs() > 1e-12 {
            let a = cov_xy / var_x;
            let b = mean_y - a * mean_x;
            println!("Linear calibration: engine_score ≈ a * hugm_raw + b  --> a = {:.6}, b = {:.3}", a, b);
        } else {
            println!("Insufficient variance in hugm_raw to compute calibration");
        }
    } else {
        println!("No engine_score values provided in input; no calibration computed");
    }

    Ok(())
}

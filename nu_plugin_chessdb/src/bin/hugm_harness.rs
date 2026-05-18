use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use anyhow::Result;
use serde::Deserialize;

#[derive(Deserialize)]
struct InputRecord {
    _id: Option<String>,
    fen: String,
    engine_score: Option<i64>,
}

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: hugm_harness <input.jsonl> <output.csv> [weights_out.json]");
        std::process::exit(2);
    }
    let input_path = &args[1];
    let output_path = &args[2];
    let weights_out = if args.len() > 3 { Some(args[3].as_str()) } else { None };

    let input = File::open(input_path)?;
    let reader = BufReader::new(input);
    let mut wtr = csv::Writer::from_path(output_path)?;

    wtr.write_record(&[
        "id", "fen", "phase",
        "hugm_raw", "engine_score",
        "material_total", "positional_total", "tactical_total",
        "material_mg", "material_eg", "material_blended",
        "pawn_structure_mg", "pawn_structure_eg", "pawn_structure_blended",
        "piece_activity_mg", "piece_activity_eg", "piece_activity_blended",
        "king_safety_mg", "king_safety_eg", "king_safety_blended",
        "passed_pawns_mg", "passed_pawns_eg", "passed_pawns_blended",
        "development_mg", "development_eg", "development_blended",
        "vector_features_mg", "vector_features_eg", "vector_features_blended",
        "strategic_mg", "strategic_eg", "strategic_blended",
        "tactical_mg", "tactical_eg", "tactical_blended",
        "mobility_knight", "mobility_bishop", "mobility_rook", "mobility_queen", "mobility_pawn",
    ])?;

    let mut rows: Vec<RegressionRow> = Vec::new();

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() { continue; }
        let rec: InputRecord = serde_json::from_str(&line)?;
        let engine_score = rec.engine_score;
        let analysis = if engine_score.is_some() {
            nu_plugin_chessdb::eval::analyze_fen_with_engine_score(&rec.fen, engine_score)
        } else {
            nu_plugin_chessdb::eval::analyze_fen(&rec.fen)
        };
        match analysis {
            Ok(r) => {
                let phase = r.phase as i64;
                let hugm_raw = r.final_score;
                let engine_score_val = engine_score.unwrap_or(0);

                let mobility_knight = r.groups.piece_activity.terms.get("mobility_knight").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_bishop = r.groups.piece_activity.terms.get("mobility_bishop").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_rook = r.groups.piece_activity.terms.get("mobility_rook").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_queen = r.groups.piece_activity.terms.get("mobility_queen").and_then(|v| v.as_i64()).unwrap_or(0);
                let mobility_pawn = r.groups.piece_activity.terms.get("mobility_pawn").and_then(|v| v.as_i64()).unwrap_or(0);

                wtr.write_record(&[
                    r.checks.sum_groups.to_string(),
                    r.fen.clone(),
                    phase.to_string(),
                    hugm_raw.to_string(),
                    engine_score_val.to_string(),
                    r.groups.material_total.value.to_string(),
                    r.groups.positional_total.value.to_string(),
                    r.groups.tactical_total.value.to_string(),
                    r.groups.material.mg.to_string(), r.groups.material.eg.to_string(), r.groups.material.blended.to_string(),
                    r.groups.pawn_structure.mg.to_string(), r.groups.pawn_structure.eg.to_string(), r.groups.pawn_structure.blended.to_string(),
                    r.groups.piece_activity.mg.to_string(), r.groups.piece_activity.eg.to_string(), r.groups.piece_activity.blended.to_string(),
                    r.groups.king_safety.mg.to_string(), r.groups.king_safety.eg.to_string(), r.groups.king_safety.blended.to_string(),
                    r.groups.passed_pawns.mg.to_string(), r.groups.passed_pawns.eg.to_string(), r.groups.passed_pawns.blended.to_string(),
                    r.groups.development.mg.to_string(), r.groups.development.eg.to_string(), r.groups.development.blended.to_string(),
                    r.groups.vector_features.mg.to_string(), r.groups.vector_features.eg.to_string(), r.groups.vector_features.blended.to_string(),
                    r.groups.strategic.mg.to_string(), r.groups.strategic.eg.to_string(), r.groups.strategic.blended.to_string(),
                    r.groups.tactical.mg.to_string(), r.groups.tactical.eg.to_string(), r.groups.tactical.blended.to_string(),
                    mobility_knight.to_string(), mobility_bishop.to_string(), mobility_rook.to_string(),
                    mobility_queen.to_string(), mobility_pawn.to_string(),
                ])?;

                if engine_score.is_some() {
                    rows.push(RegressionRow {
                        phase,
                        material_total: r.groups.material_total.value,
                        positional_total: r.groups.positional_total.value,
                        tactical_total: r.groups.tactical_total.value,
                        material: r.groups.material.blended,
                        pawn_structure: r.groups.pawn_structure.blended,
                        piece_activity: r.groups.piece_activity.blended,
                        king_safety: r.groups.king_safety.blended,
                        passed_pawns: r.groups.passed_pawns.blended,
                        development: r.groups.development.blended,
                        vector_features: r.groups.vector_features.blended,
                        strategic: r.groups.strategic.blended,
                        engine_score: engine_score_val,
                    });
                }
            }
            Err(e) => {
                eprintln!("Error evaluating fen {}: {}", rec.fen, e);
                return Err(e);
            }
        }
    }

    wtr.flush()?;

    if rows.len() >= 10 {
        run_multivariate_regression(&rows, weights_out);
    } else {
        println!("Not enough records with engine scores (need >= 10, have {})", rows.len());
    }

    Ok(())
}

struct RegressionRow {
    phase: i64,
    material_total: i64,
    positional_total: i64,
    tactical_total: i64,
    material: i64,
    pawn_structure: i64,
    piece_activity: i64,
    king_safety: i64,
    passed_pawns: i64,
    development: i64,
    vector_features: i64,
    strategic: i64,
    engine_score: i64,
}

fn run_multivariate_regression(rows: &[RegressionRow], weights_out: Option<&str>) {
    let n = rows.len();
    let k = 10;
    let mut xtx = vec![0.0f64; k * k];
    let mut xty = vec![0.0f64; k];
    let names = ["intercept","phase","material","pawn_structure","piece_activity","king_safety","passed_pawns","development","vector_features","strategic"];
    for row in rows {
        let x: [f64; 10] = [1.0,row.phase as f64,row.material as f64,row.pawn_structure as f64,row.piece_activity as f64,row.king_safety as f64,row.passed_pawns as f64,row.development as f64,row.vector_features as f64,row.strategic as f64];
        let y = row.engine_score as f64;
        for i in 0..k { xty[i] += x[i]*y; for j in 0..k { xtx[i*k+j] += x[i]*x[j]; } }
    }
    let ols = solve_ridge(&xtx, &xty, k, 0.0);
    let r2_ols = compute_r2(rows, &ols, n);
    let lambdas = [0.1, 1.0, 10.0, 100.0, 1000.0, 10000.0];
    let mut best_lam = 0.0; let mut best_r2 = -1.0; let mut best_beta = vec![0.0f64; k];
    for &lam in &lambdas {
        let ridge = solve_ridge(&xtx, &xty, k, lam);
        let r2 = compute_r2(rows, &ridge, n);
        if r2 > best_r2 { best_r2 = r2; best_lam = lam; best_beta = ridge.clone(); }
    }
    println!("\n=== OLS ({} pos, 10 feats) ===", n);
    for i in 0..k { println!("  {:>20}: {:>10.4}", names[i], ols[i]); }
    println!("  R^2 = {:.4}", r2_ols);
    println!("\n=== Ridge (lam={:.0}) ===", best_lam);
    for i in 0..k { println!("  {:>20}: {:>10.4}", names[i], best_beta[i]); }
    println!("  R^2 = {:.4}", best_r2);
    println!("\nLambda scan:");
    for &lam in &lambdas {
        let r = solve_ridge(&xtx, &xty, k, lam);
        let r2 = compute_r2(rows, &r, n);
        println!("  lam={:7.0}  R^2={:.4}", lam, r2);
    }
    let (ua,ub) = univariate_calibration(rows);
    println!("\nUnivariate: engine ~ {:.6} * hugm + {:.3}", ua, ub);

    // 3-feature model: material + positional + tactical
    three_feature_regression(rows);

    phase_grouped_regression(rows);
    if let Some(path) = weights_out { gen_weights(&best_beta, &names, path); }
}

fn three_feature_regression(rows: &[RegressionRow]) {
    let k = 4; // intercept + material + positional + tactical
    let mut xtx = vec![0.0f64; k*k];
    let mut xty = vec![0.0f64; k];
    for row in rows {
        let x = [1.0, row.material_total as f64, row.positional_total as f64, row.tactical_total as f64];
        let y = row.engine_score as f64;
        for i in 0..k { xty[i] += x[i]*y; for j in 0..k { xtx[i*k+j] += x[i]*x[j]; } }
    }
    let beta = solve_ridge(&xtx, &xty, k, 0.0);
    let r2 = {
        let n = rows.len();
        let ym: f64 = rows.iter().map(|r| r.engine_score as f64).sum::<f64>() / n as f64;
        let mut ssr=0.0; let mut sst=0.0;
        for row in rows {
            let x = [1.0, row.material_total as f64, row.positional_total as f64, row.tactical_total as f64];
            let yp: f64 = beta[0] + beta[1]*x[1] + beta[2]*x[2] + beta[3]*x[3];
            let ya = row.engine_score as f64;
            ssr += (ya-yp).powi(2); sst += (ya-ym).powi(2);
        }
        if sst>0.0 { 1.0-ssr/sst } else { 0.0 }
    };
    println!("\n=== 3-feature (material + positional + tactical) ===");
    println!("  intercept:    {:>10.4}", beta[0]);
    println!("  material:     {:>10.4}", beta[1]);
    println!("  positional:   {:>10.4}", beta[2]);
    println!("  tactical:     {:>10.4}", beta[3]);
    println!("  R^2 = {:.4}", r2);
}
fn phase_grouped_regression(rows: &[RegressionRow]) {
    let k = 10;
    let names = ["intercept","phase","material","pawn_structure","piece_activity","king_safety","passed_pawns","development","vector_features","strategic"];
    let groups: [(i64,i64,&str); 5] = [
        (19,100,"Ph 19-24"),
        (16,18, "Ph 16-18"),
        (10,15, "Ph 10-15"),
        (4, 9,  "Ph 4-9"),
        (0, 3,  "Ph 0-3"),
    ];
    println!("\n=== Phase-grouped OLS ===");
    print!("{:>16} {:>4}", "group", "n");
    for i in 2..k { print!(" {:>9}", names[i]); }
    println!(" {:>9} {:>6}", "phase", "R^2");
    for (lo,hi,label) in &groups {
        let subset: Vec<&RegressionRow> = rows.iter().filter(|r| r.phase>=*lo && r.phase<=*hi).collect();
        if subset.len()<20 { println!("  {:>16}: {} pos (skip)", label, subset.len()); continue; }
        let mut xtx=vec![0.0f64; k*k]; let mut xty=vec![0.0f64; k];
        for row in &subset {
            let x: [f64;10] = [1.0,row.phase as f64,row.material as f64,row.pawn_structure as f64,row.piece_activity as f64,row.king_safety as f64,row.passed_pawns as f64,row.development as f64,row.vector_features as f64,row.strategic as f64];
            let y=row.engine_score as f64;
            for i in 0..k { xty[i]+=x[i]*y; for j in 0..k { xtx[i*k+j]+=x[i]*x[j]; } }
        }
        let beta=solve_ridge(&xtx,&xty,k,0.0);
        let r2=compute_r2_vec(&subset,&beta);
        print!("  {:>16} {:>4}", label, subset.len());
        for i in 2..k { print!(" {:>9.4}", beta[i]); }
        println!(" {:>9.4} {:>6.4}", beta[1], r2);
    }
}
fn compute_r2_vec(rows: &[&RegressionRow], beta: &[f64]) -> f64 {
    let n=rows.len(); let k=beta.len();
    let ym: f64 = rows.iter().map(|r| r.engine_score as f64).sum::<f64>() / n as f64;
    let mut ssr=0.0; let mut sst=0.0;
    for row in rows {
        let x: [f64;10] = [1.0,row.phase as f64,row.material as f64,row.pawn_structure as f64,row.piece_activity as f64,row.king_safety as f64,row.passed_pawns as f64,row.development as f64,row.vector_features as f64,row.strategic as f64];
        let yp: f64 = (0..k).map(|i| x[i]*beta[i]).sum();
        let ya=row.engine_score as f64;
        ssr+=(ya-yp).powi(2); sst+=(ya-ym).powi(2);
    }
    if sst>0.0 { 1.0-ssr/sst } else { 0.0 }
}
fn solve_ridge(xtx: &[f64], xty: &[f64], k: usize, lam: f64) -> Vec<f64> {
    let mut aug = vec![0.0f64; k*(k+1)];
    for i in 0..k { for j in 0..k { aug[i*(k+1)+j] = xtx[i*k+j]; if i==j { aug[i*(k+1)+j] += lam; } } aug[i*(k+1)+k] = xty[i]; }
    for col in 0..k {
        let mut best = col; let mut bv = aug[col*(k+1)+col].abs();
        for row in (col+1)..k { let v = aug[row*(k+1)+col].abs(); if v>bv { bv=v; best=row; } }
        if bv<1e-12 { continue; }
        if best!=col { for j in 0..=k { aug.swap(col*(k+1)+j, best*(k+1)+j); } }
        let piv = aug[col*(k+1)+col];
        for row in (col+1)..k { let f = aug[row*(k+1)+col]/piv; for j in col..=k { aug[row*(k+1)+j] -= f*aug[col*(k+1)+j]; } }
    }
    let mut beta = vec![0.0f64; k];
    for i in (0..k).rev() { let mut s = aug[i*(k+1)+k]; for j in (i+1)..k { s -= aug[i*(k+1)+j]*beta[j]; } beta[i] = s/aug[i*(k+1)+i]; }
    beta
}
fn compute_r2(rows: &[RegressionRow], beta: &[f64], n: usize) -> f64 {
    let k = beta.len();
    let ym: f64 = rows.iter().map(|r| r.engine_score as f64).sum::<f64>() / n as f64;
    let mut ssr=0.0; let mut sst=0.0;
    for row in rows {
        let x: [f64;10] = [1.0,row.phase as f64,row.material as f64,row.pawn_structure as f64,row.piece_activity as f64,row.king_safety as f64,row.passed_pawns as f64,row.development as f64,row.vector_features as f64,row.strategic as f64];
        let yp: f64 = (0..k).map(|i| x[i]*beta[i]).sum();
        let ya = row.engine_score as f64;
        ssr += (ya-yp).powi(2); sst += (ya-ym).powi(2);
    }
    if sst>0.0 { 1.0-ssr/sst } else { 0.0 }
}

fn univariate_calibration(rows: &[RegressionRow]) -> (f64,f64) {
    let nf = rows.len() as f64;
    let mut sx=0.0; let mut sy=0.0; let mut sxx=0.0; let mut sxy=0.0;
    for r in rows {
        let h = (r.material+r.pawn_structure+r.piece_activity+r.king_safety+r.passed_pawns+r.development+r.vector_features+r.strategic) as f64;
        let e = r.engine_score as f64;
        sx+=h; sy+=e; sxx+=h*h; sxy+=h*e;
    }
    let mx=sx/nf; let my=sy/nf;
    let vx = sxx/nf-mx*mx;
    if vx.abs()>1e-12 { let a=(sxy/nf-mx*my)/vx; (a,my-a*mx) } else { (0.0,my) }
}

fn gen_weights(beta: &[f64], _names: &[&str], path: &str) {
    let comps: [(usize,&str);8] = [(2,"material"),(3,"pawn_structure"),(4,"piece_activity"),(5,"king_safety"),(6,"passed_pawns"),(7,"development"),(8,"vector_features"),(9,"strategic")];
    let coeffs: Vec<f64> = comps.iter().map(|(i,_)| beta[*i]).collect();
    let mean = coeffs.iter().sum::<f64>() / coeffs.len() as f64;
    if mean.abs()<1e-12 { eprintln!("zero mean coeff"); return; }
    let mut scales: Vec<(String,f64)> = Vec::new();
    for (i,n) in &comps { scales.push((n.to_string(), beta[*i]/mean)); }
    println!("\n=== Scale factors (mean={:.4}) ===", mean);
    for (n,s) in &scales { println!("  {:>20}: {:.4}", n, s); }
    let mut w = serde_json::Map::new();
    for (name, scale) in &scales {
        match name.as_str() {
            "material" => {
                w.insert("val_queen".into(), serde_json::json!(((900.0*scale).round() as i64)));
                w.insert("val_rook".into(), serde_json::json!(((500.0*scale).round() as i64)));
                w.insert("val_bishop".into(), serde_json::json!(((330.0*scale).round() as i64)));
                w.insert("val_knight".into(), serde_json::json!(((320.0*scale).round() as i64)));
                w.insert("val_pawn".into(), serde_json::json!(((100.0*scale).round() as i64)));
            }
            "pawn_structure" => {
                w.insert("pawn_majority_weight".into(), serde_json::json!(((20.0*scale).round() as i64)));
                w.insert("pawn_break_weight".into(), serde_json::json!(((30.0*scale).round() as i64)));
                w.insert("minority_attack_weight".into(), serde_json::json!(((35.0*scale).round() as i64)));
            }
            "piece_activity" => {
                w.insert("rook_open_file_bonus".into(), serde_json::json!(((25.0*scale).round() as i64)));
                w.insert("doubled_rook_bonus".into(), serde_json::json!(((20.0*scale).round() as i64)));
                w.insert("rook_seventh_bonus".into(), serde_json::json!(((30.0*scale).round() as i64)));
                w.insert("piece_mobility_weight".into(), serde_json::json!(((5.0*scale).round() as i64)));
            }
            "king_safety" => {
                w.insert("tropism_queen".into(), serde_json::json!(((90.0*scale).round() as i64)));
                w.insert("tropism_rook".into(), serde_json::json!(((50.0*scale).round() as i64)));
                w.insert("tropism_bishop".into(), serde_json::json!(((35.0*scale).round() as i64)));
                w.insert("tropism_knight".into(), serde_json::json!(((30.0*scale).round() as i64)));
                w.insert("tropism_pawn".into(), serde_json::json!(((10.0*scale).round() as i64)));
            }
            _ => {}
        }
    }
    if beta[1].abs() > 0.001 { w.insert("phase_factor_den".into(), serde_json::json!(((40.0*beta[1].signum()).max(10.0)).round() as i64)); }
    let mut f = File::create(path).unwrap();
    f.write_all(serde_json::to_string_pretty(&w).unwrap().as_bytes()).unwrap();
    println!("\nWrote weights to {}", path);
}

impl RegressionRow {
    #[allow(dead_code)]
    fn hugm_raw(&self) -> i64 {
        self.material + self.pawn_structure + self.piece_activity + self.king_safety
        + self.passed_pawns + self.development + self.vector_features + self.strategic
    }
}

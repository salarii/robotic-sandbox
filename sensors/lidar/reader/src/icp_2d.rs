// 2D ICP (Iterative Closest Point) in Rust
// ==========================================
// Cargo.toml dependencies:
//
// [dependencies]
// nalgebra = "0.33"
// kiddo = "4"
//
// Run: cargo run --release

use nalgebra::{Matrix2, SMatrix, SVD, Vector2};
use kiddo::{KdTree, SquaredEuclidean};

// ─────────────────────────────────────────────
// 1. Types and point cloud helpers
// ─────────────────────────────────────────────

type Point2 = [f64; 2];

/// Generate N points uniformly on a 2-D rectangle border (W × H).
fn rectangle_points(w: f64, h: f64, n: usize) -> Vec<Point2> {
    let perimeter = 2.0 * (w + h);
    (0..n)
        .map(|i| {
            let s = i as f64 / n as f64 * perimeter;
            if s < w {
                [s, 0.0]
            } else if s < w + h {
                [w, s - w]
            } else if s < 2.0 * w + h {
                [w - (s - w - h), h]
            } else {
                [0.0, h - (s - 2.0 * w - h)]
            }
        })
        .collect()
}

/// Apply 2-D rigid transform: rotate by theta, then translate by (tx, ty).
fn apply_transform(pts: &[Point2], theta: f64, tx: f64, ty: f64) -> Vec<Point2> {
    let (c, s) = (theta.cos(), theta.sin());
    pts.iter()
        .map(|[x, y]| [c * x - s * y + tx, s * x + c * y + ty])
        .collect()
}

// ─────────────────────────────────────────────
// 2. KD-Tree nearest-neighbor association (kiddo)
// ─────────────────────────────────────────────

/// Build a KD-tree from `reference`, then find the nearest neighbor in it
/// for every point in `query`.  Returns (indices, squared_distances).
fn kd_nn(reference: &[Point2], query: &[Point2]) -> (Vec<usize>, Vec<f64>) {
    // kiddo::KdTree requires items as &[f64; K]
    let mut tree: KdTree<f64, 2> = KdTree::new();
    for (i, p) in reference.iter().enumerate() {
        tree.add(p, i as u64);
    }

    query
        .iter()
        .map(|q| {
            let nn = tree.nearest_one::<SquaredEuclidean>(q);
            (nn.item as usize, nn.distance)  // distance is squared here
        })
        .unzip()
}

// ─────────────────────────────────────────────
// 3. Outlier rejection
// ─────────────────────────────────────────────

/// Reject pairs whose squared_distance exceeds `factor² × median_sq_dist`.
/// Returns a boolean mask (true = keep).
fn reject_outliers(sq_dists: &[f64], factor: f64) -> Vec<bool> {
    let mut sorted = sq_dists.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median_sq = sorted[sorted.len() / 2];
    let threshold = (factor * factor) * median_sq;
    sq_dists.iter().map(|&d| d < threshold).collect()
}

// ─────────────────────────────────────────────
// 4. SVD solver for optimal R, t  (nalgebra)
// ─────────────────────────────────────────────

/// Given matched pairs (src[i] → dst[i]), find R, t minimising Σ||R·src+t−dst||².
///
/// Steps:
///   1. Compute centroids and centre both clouds.
///   2. Cross-covariance H = src_c^T dst_c  (2×2).
///   3. SVD: H = U Σ V^T.
///   4. R = V * diag(1, det(V*U^T)) * U^T   (handles reflections).
///   5. t = dst_mean − R * src_mean.
fn svd_solve(src: &[Point2], dst: &[Point2]) -> (Matrix2<f64>, Vector2<f64>) {
    let n = src.len() as f64;

    let src_mean = Vector2::new(
        src.iter().map(|p| p[0]).sum::<f64>() / n,
        src.iter().map(|p| p[1]).sum::<f64>() / n,
    );
    let dst_mean = Vector2::new(
        dst.iter().map(|p| p[0]).sum::<f64>() / n,
        dst.iter().map(|p| p[1]).sum::<f64>() / n,
    );

    // Build 2×N centred matrices as flat SMatrix (nalgebra static)
    // For 2D we can just build the 2×2 cross-covariance directly
    let mut h = Matrix2::zeros();
    for (s, d) in src.iter().zip(dst.iter()) {
        let sc = Vector2::new(s[0] - src_mean[0], s[1] - src_mean[1]);
        let dc = Vector2::new(d[0] - dst_mean[0], d[1] - dst_mean[1]);
        h += sc * dc.transpose();
    }

    // SVD via nalgebra
    let svd = SVD::new(h, true, true);
    let u = svd.u.unwrap();
    let v_t = svd.v_t.unwrap();
    let v = v_t.transpose();

    // Reflection correction
    let det_sign = (v * u.transpose()).determinant().signum();
    let correction = Matrix2::new(1.0, 0.0, 0.0, det_sign);

    let r = v * correction * u.transpose();
    let t = dst_mean - r * src_mean;

    (r, t)
}

// ─────────────────────────────────────────────
// 5. Full ICP pipeline
// ─────────────────────────────────────────────

struct IcpResult {
    r_total: Matrix2<f64>,
    t_total: Vector2<f64>,
    iterations: usize,
    final_error: f64,
    converged: bool,
    error_history: Vec<f64>,
}

fn icp(
    new_scan: &[Point2],   // current frame — being aligned
    prev_scan: &[Point2],  // reference frame — aligned against
    warm_r: Matrix2<f64>,
    warm_t: Vector2<f64>,
    max_iter: usize,
    tol: f64,
    outlier_factor: f64,
    verbose: bool,
) -> IcpResult {
    // Apply warm start
    let mut current: Vec<Point2> = new_scan
        .iter()
        .map(|p| {
            let v = warm_r * Vector2::new(p[0], p[1]) + warm_t;
            [v[0], v[1]]
        })
        .collect();

    let mut r_acc = warm_r;
    let mut t_acc = warm_t;
    let mut prev_error = f64::INFINITY;
    let mut error_history = Vec::new();

    for iter in 0..max_iter {
        // ── Step 1: KD-Tree association ──────────────────────────
        let (idxs, sq_dists) = kd_nn(prev_scan, &current);

        // ── Step 2: Outlier rejection ────────────────────────────
        let mask = reject_outliers(&sq_dists, outlier_factor);
        let inliers: Vec<usize> = (0..current.len()).filter(|&i| mask[i]).collect();

        if inliers.len() < 4 {
            if verbose {
                eprintln!("  Too few inliers ({}) at iteration {}", inliers.len(), iter);
            }
            break;
        }

        let matched_new: Vec<Point2> = inliers.iter().map(|&i| current[i]).collect();
        let matched_prev: Vec<Point2> = inliers.iter().map(|&i| prev_scan[idxs[i]]).collect();

        let mean_sq: f64 = inliers.iter().map(|&i| sq_dists[i]).sum::<f64>()
            / inliers.len() as f64;
        let mean_dist = mean_sq.sqrt();
        error_history.push(mean_dist);

        if verbose {
            println!(
                "  iter {:2} | inliers {:3}/{:3} | mean_dist {:.6}",
                iter,
                inliers.len(),
                new_scan.len(),
                mean_dist
            );
        }

        // ── Step 3: SVD solve ────────────────────────────────────
        let (r, t) = svd_solve(&matched_new, &matched_prev);

        // ── Step 4: Apply transform ──────────────────────────────
        current = current
            .iter()
            .map(|p| {
                let v = r * Vector2::new(p[0], p[1]) + t;
                [v[0], v[1]]
            })
            .collect();

        // Accumulate transforms
        t_acc = r * t_acc + t;
        r_acc = r * r_acc;

        // ── Convergence check ────────────────────────────────────
        let delta = (prev_error - mean_dist).abs();
        if delta < tol {
            if verbose {
                println!("  ✓ Converged at iteration {} (Δ={:.2e})", iter, delta);
            }
            return IcpResult {
                r_total: r_acc,
                t_total: t_acc,
                iterations: iter + 1,
                final_error: mean_dist,
                converged: true,
                error_history,
            };
        }
        prev_error = mean_dist;
    }

    IcpResult {
        r_total: r_acc,
        t_total: t_acc,
        iterations: max_iter,
        final_error: prev_error,
        converged: false,
        error_history,
    }
}

// ─────────────────────────────────────────────
// 6. Tests
// ─────────────────────────────────────────────

fn rotation_angle(r: &Matrix2<f64>) -> f64 {
    r[(1, 0)].atan2(r[(0, 0)])
}

fn main() {
    println!("{}", "=".repeat(60));
    println!("TEST 1: Clean recovery (small rotation + translation)");
    println!("{}", "=".repeat(60));

    {
        let prev_frame = rectangle_points(4.0, 3.0, 20);
        let (theta_true, tx_true, ty_true) = (0.08, 0.3, 0.2);
        let new_frame = apply_transform(&prev_frame, theta_true, tx_true, ty_true);

        println!("\n-- Cold start --");
        let identity = Matrix2::identity();
        let zero = Vector2::zeros();
        // pass (prev, new): ICP aligns prev onto new -> recovers forward transform
        let result = icp(&prev_frame, &new_frame, identity, zero, 50, 1e-3, 3.0, true);

        let theta_est = rotation_angle(&result.r_total);
        println!(
            "  True:  θ={:.4}  tx={:.4}  ty={:.4}",
            theta_true, tx_true, ty_true
        );
        println!(
            "  Found: θ={:.4}  tx={:.4}  ty={:.4}  (converged={})",
            theta_est, result.t_total[0], result.t_total[1], result.converged
        );
    }

    println!();
    println!("{}", "=".repeat(60));
    println!("TEST 2: LOCAL MINIMUM TRAP — rectangle shifted ~one side-length");
    println!("{}", "=".repeat(60));
    println!("Scenario: robot moves ~4 m along a 4 m wall.");
    println!("Points nearly slide into adjacent holes.");
    println!();

    {
        let (w, h) = (4.0_f64, 3.0_f64);
        let n = 16usize;
        let prev_frame = rectangle_points(w, h, n);

        // True movement: almost exactly one long-side length → local min territory
        let theta_true = 0.0_f64;
        let tx_true = w / n as f64 * (n - 1) as f64 + 0.05;
        let ty_true = 0.05_f64;
        let new_frame = apply_transform(&prev_frame, theta_true, tx_true, ty_true);

        println!("-- Cold start (no odometry) --");
        let result_cold = icp(&prev_frame, &new_frame, Matrix2::identity(), Vector2::zeros(), 50, 1e-6, 3.0, true);
        let theta_est = rotation_angle(&result_cold.r_total);
        println!(
            "  True:  θ={:.4}  tx={:.4}  ty={:.4}",
            theta_true, tx_true, ty_true
        );
        println!(
            "  Found: θ={:.4}  tx={:.4}  ty={:.4}  (converged={})",
            theta_est, result_cold.t_total[0], result_cold.t_total[1], result_cold.converged
        );
        let err_t = ((result_cold.t_total[0] - tx_true).powi(2)
            + (result_cold.t_total[1] - ty_true).powi(2))
        .sqrt();
        println!(
            "  Translation error: {:.4} m  {}",
            err_t,
            if err_t > 0.5 { "⚠ TRAPPED IN LOCAL MINIMUM!" } else { "✓ correct" }
        );

        println!();
        println!("-- Warm start (odometry gives 90% of true movement) --");
        let warm_t = Vector2::new(tx_true * 0.9, ty_true * 0.9);
        let result_warm = icp(&prev_frame, &new_frame, Matrix2::identity(), warm_t, 50, 1e-6, 3.0, true);
        let theta_est = rotation_angle(&result_warm.r_total);
        println!(
            "  True:  θ={:.4}  tx={:.4}  ty={:.4}",
            theta_true, tx_true, ty_true
        );
        println!(
            "  Found: θ={:.4}  tx={:.4}  ty={:.4}  (converged={})",
            theta_est, result_warm.t_total[0], result_warm.t_total[1], result_warm.converged
        );
        let err_t = ((result_warm.t_total[0] - tx_true).powi(2)
            + (result_warm.t_total[1] - ty_true).powi(2))
        .sqrt();
        println!(
            "  Translation error: {:.4} m  {}",
            err_t,
            if err_t > 0.5 { "⚠ TRAPPED" } else { "✓ correct (warm start rescued ICP!)" }
        );
    }

    println!();
    println!("{}", "=".repeat(60));
    println!("TEST 3: Noisy scan — sensor noise σ=2 cm");
    println!("{}", "=".repeat(60));

    {
        // Simple Box-Muller noise (no rand crate needed)
        fn noise_sample(seed: usize) -> f64 {
            let x = (seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407)) % (1 << 32);
            let u = x as f64 / (1u64 << 32) as f64;
            let v = ((seed.wrapping_mul(1234567) + 89101112) % (1 << 32)) as f64
                / (1u64 << 32) as f64;
            (-2.0 * u.ln()).sqrt() * (2.0 * std::f64::consts::PI * v).cos()
        }

        let prev_frame = rectangle_points(4.0, 3.0, 30);
        let (theta_true, tx_true, ty_true) = (0.05, 0.15, 0.10);
        let dst_clean = apply_transform(&prev_frame, theta_true, tx_true, ty_true);
        let sigma = 0.02;
        let dst: Vec<Point2> = dst_clean
            .iter()
            .enumerate()
            .map(|(i, &[x, y])| {
                [x + sigma * noise_sample(i * 2), y + sigma * noise_sample(i * 2 + 1)]
            })
            .collect();

        let result = icp(&prev_frame, &dst, Matrix2::identity(), Vector2::zeros(), 50, 1e-6, 2.5, true);
        let theta_est = rotation_angle(&result.r_total);
        println!(
            "  True:  θ={:.4}  tx={:.4}  ty={:.4}",
            theta_true, tx_true, ty_true
        );
        println!(
            "  Found: θ={:.4}  tx={:.4}  ty={:.4}",
            theta_est, result.t_total[0], result.t_total[1]
        );
        let err_t = ((result.t_total[0] - tx_true).powi(2)
            + (result.t_total[1] - ty_true).powi(2))
        .sqrt();
        println!(
            "  Error: Δθ={:.4} rad  |Δt|={:.4} m",
            (theta_est - theta_true).abs(),
            err_t
        );
    }

    println!();
    println!("Done.");
    println!("  - kiddo::KdTree<f64,2>   → O(log N) nearest-neighbor search");
    println!("  - nalgebra::SVD          → optimal R,t from matched pairs");
    println!("  - Outlier rejection      → median-based distance filter");
    println!("  - Warm start             → escapes the local minimum trap");
}

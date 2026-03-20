"""
2D ICP (Iterative Closest Point) in Julia
=========================================
Dependencies: NearestNeighbors.jl, LinearAlgebra (stdlib), Statistics (stdlib)
Install: using Pkg; Pkg.add(["NearestNeighbors", "StaticArrays"])

Demonstrates:
  1. KD-Tree based nearest-neighbor association
  2. Outlier rejection by distance threshold
  3. SVD-based optimal R, t computation
  4. Warm start from odometry vs cold start (local minimum trap)
"""

using LinearAlgebra
using Statistics
using NearestNeighbors
using Printf

# ─────────────────────────────────────────────
# 1. Point cloud helpers
# ─────────────────────────────────────────────

"""Generate N points uniformly on a 2-D rectangle border (W x H)."""
function rectangle_points(W::Float64, H::Float64, N::Int)
    perimeter = 2*(W + H)
    pts = Matrix{Float64}(undef, 2, N)
    for i in 1:N
        s = (i-1) / N * perimeter
        if s < W
            pts[:, i] = [s, 0.0]
        elseif s < W + H
            pts[:, i] = [W, s - W]
        elseif s < 2*W + H
            pts[:, i] = [W - (s - W - H), H]
        else
            pts[:, i] = [0.0, H - (s - 2*W - H)]
        end
    end
    return pts
end

"""Apply a 2-D rigid transformation: rotate by θ, then translate by (tx, ty)."""
function apply_transform(pts::Matrix{Float64}, θ::Float64, tx::Float64, ty::Float64)
    R = [cos(θ) -sin(θ); sin(θ) cos(θ)]
    t = [tx, ty]
    return R * pts .+ t
end

# ─────────────────────────────────────────────
# 2. KD-Tree nearest-neighbor association
# ─────────────────────────────────────────────

"""
Find nearest neighbor in `prev_scan` for every point in `query`.
Returns (indices, distances).
"""
function kd_nn(prev_scan::Matrix{Float64}, query::Matrix{Float64})
    tree = KDTree(prev_scan)
    idxs, dists = knn(tree, query, 1, true)
    return [i[1] for i in idxs], [d[1] for d in dists]
end

# ─────────────────────────────────────────────
# 3. Outlier rejection
# ─────────────────────────────────────────────

"""
Reject pairs whose distance exceeds `factor` × median distance.
Returns boolean mask (true = keep).
"""
function reject_outliers(dists::Vector{Float64}; factor::Float64 = 3.0)
    med = median(dists)
    return dists .< factor * med
end

# ─────────────────────────────────────────────
# 4. SVD solver for optimal R, t
# ─────────────────────────────────────────────

"""
Given matched point pairs (new_pts → prev_pts), compute the rotation R and
translation t that minimise Σ ||R·new_i + t - prev_i||².

Algorithm:
  1. Centre both clouds at their centroids.
  2. Build cross-covariance matrix H = new_c * prev_c'.
  3. SVD: H = U Σ V'.
  4. R = V * diag(1, det(V*U')) * U'  (det-correction handles reflections).
  5. t = prev_mean - R * new_mean.
"""
function svd_solve(new_pts::Matrix{Float64}, prev_pts::Matrix{Float64})
    new_mean  = mean(new_pts,  dims=2)
    prev_mean = mean(prev_pts, dims=2)

    new_c  = new_pts  .- new_mean
    prev_c = prev_pts .- prev_mean

    H = new_c * prev_c'   # 2×2 cross-covariance

    F = svd(H)
    d = sign(det(F.V * F.U'))
    D = Diagonal([1.0, d])

    R = F.V * D * F.U'
    t = prev_mean .- R * new_mean

    return R, vec(t)
end

# ─────────────────────────────────────────────
# 5. Full ICP pipeline
# ─────────────────────────────────────────────

struct ICPResult
    R_total::Matrix{Float64}   # accumulated rotation  (robot frame: prev → new)
    t_total::Vector{Float64}   # accumulated translation
    iterations::Int
    final_error::Float64
    converged::Bool
    error_history::Vector{Float64}
end

"""
Run ICP to align `prev_scan` onto `new_scan`, recovering the forward transform.

  prev_scan  – reference frame (previous lidar scan / map)
  new_scan   – current frame   (scan to align against the reference)
  warm_R, warm_t – initial guess from odometry (identity + zeros = cold start)

The returned R_total, t_total describe the motion:
  new_scan ≈ R_total * prev_scan + t_total
"""
function icp(prev_scan::Matrix{Float64}, new_scan::Matrix{Float64};
             warm_R::Matrix{Float64} = Matrix{Float64}(I, 2, 2),
             warm_t::Vector{Float64} = [0.0, 0.0],
             max_iter::Int = 50,
             tol::Float64 = 1e-3,
             outlier_factor::Float64 = 3.0,
             verbose::Bool = true)

    # Apply warm start to prev_scan — pre-positions it close to new_scan
    current = warm_R * prev_scan .+ warm_t

    R_acc = copy(warm_R)
    t_acc = copy(warm_t)
    prev_error = Inf
    error_history = Float64[]

    for iter in 1:max_iter
        # ── Step 1: KD-Tree association ──────────────────────────
        # find nearest neighbour in new_scan for each point in current
        idxs, dists = kd_nn(new_scan, current)

        # ── Step 2: Outlier rejection ────────────────────────────
        mask = reject_outliers(dists; factor = outlier_factor)
        n_inliers = sum(mask)

        if n_inliers < 4
            verbose && @warn "Too few inliers ($n_inliers) at iteration $iter"
            break
        end

        matched_current  = current[:, mask]
        matched_new_scan = new_scan[:, idxs[mask]]

        mean_dist = mean(dists[mask])
        push!(error_history, mean_dist)

        verbose && @printf("  iter %2d | inliers %3d/%3d | mean_dist %.6f\n",
                           iter, n_inliers, size(prev_scan, 2), mean_dist)

        # ── Step 3: SVD solve ────────────────────────────────────
        R, t = svd_solve(matched_current, matched_new_scan)

        # ── Step 4: Apply incremental transform ──────────────────
        current = R * current .+ t

        # Accumulate: total = incremental ∘ accumulated
        t_acc = R * t_acc + t
        R_acc = R * R_acc

        # ── Convergence check ────────────────────────────────────
        Δ = abs(prev_error - mean_dist)
        if Δ < tol
            verbose && println("  ✓ Converged at iteration $iter (Δ=$Δ)")
            return ICPResult(R_acc, t_acc, iter, mean_dist, true, error_history)
        end
        prev_error = mean_dist
    end

    return ICPResult(R_acc, t_acc, max_iter, prev_error, false, error_history)
end

# ─────────────────────────────────────────────
# 6. Tests
# ─────────────────────────────────────────────

println("=" ^ 60)
println("TEST 1: Clean recovery (small rotation + translation)")
println("=" ^ 60)

begin
    prev_frame = rectangle_points(4.0, 3.0, 20)
    θ_true, tx_true, ty_true = 0.08, 0.3, 0.2
    new_frame = apply_transform(prev_frame, θ_true, tx_true, ty_true)

    println("\n-- Cold start (no odometry hint) --")
    # pass (prev, new): ICP aligns prev onto new → recovers forward transform
    result = icp(prev_frame, new_frame; verbose=true)
    θ_est = atan(result.R_total[2,1], result.R_total[1,1])
    @printf("  True:  θ=%.4f  tx=%.4f  ty=%.4f\n", θ_true, tx_true, ty_true)
    @printf("  Found: θ=%.4f  tx=%.4f  ty=%.4f  (converged=%s)\n",
            θ_est, result.t_total..., result.converged)
end

println()
println("=" ^ 60)
println("TEST 2: LOCAL MINIMUM TRAP — rectangle shifted ~one side-length")
println("=" ^ 60)
println("Scenario: robot moves 3.8 m along a 4 m wall. Points nearly")
println("slide into adjacent holes. Cold ICP gets trapped.")
println()

begin
    W, H = 4.0, 3.0
    N = 16
    prev_frame = rectangle_points(W, H, N)

    θ_true  = 0.0
    tx_true = W / N * (N - 1) + 0.05
    ty_true = 0.05
    new_frame = apply_transform(prev_frame, θ_true, tx_true, ty_true)

    println("-- Cold start (odometry unavailable) --")
    result_cold = icp(prev_frame, new_frame; verbose=true)
    θ_est = atan(result_cold.R_total[2,1], result_cold.R_total[1,1])
    @printf("  True:  θ=%.4f  tx=%.4f  ty=%.4f\n", θ_true, tx_true, ty_true)
    @printf("  Found: θ=%.4f  tx=%.4f  ty=%.4f  (converged=%s)\n",
            θ_est, result_cold.t_total..., result_cold.converged)
    err_t = norm(result_cold.t_total - [tx_true, ty_true])
    @printf("  Translation error: %.4f m  %s\n", err_t,
            err_t > 0.5 ? "⚠ TRAPPED IN LOCAL MINIMUM!" : "✓ correct")

    println()
    println("-- Warm start (odometry gives 90% of true movement) --")
    warm_t = [tx_true * 0.9, ty_true * 0.9]
    warm_R = Matrix{Float64}(I, 2, 2)
    result_warm = icp(prev_frame, new_frame; warm_R=warm_R, warm_t=warm_t, verbose=true)
    θ_est = atan(result_warm.R_total[2,1], result_warm.R_total[1,1])
    @printf("  True:  θ=%.4f  tx=%.4f  ty=%.4f\n", θ_true, tx_true, ty_true)
    @printf("  Found: θ=%.4f  tx=%.4f  ty=%.4f  (converged=%s)\n",
            θ_est, result_warm.t_total..., result_warm.converged)
    err_t = norm(result_warm.t_total - [tx_true, ty_true])
    @printf("  Translation error: %.4f m  %s\n", err_t,
            err_t > 0.5 ? "⚠ TRAPPED" : "✓ correct (warm start rescued ICP!)")
end

println()
println("=" ^ 60)
println("TEST 3: Noisy scan — sensor noise 2cm std")
println("=" ^ 60)

begin
    prev_frame = rectangle_points(4.0, 3.0, 30)
    θ_true, tx_true, ty_true = 0.05, 0.15, 0.10
    noise = 0.02 * randn(2, 30)
    new_frame = apply_transform(prev_frame, θ_true, tx_true, ty_true) .+ noise

    result = icp(prev_frame, new_frame; outlier_factor=2.5, verbose=true)
    θ_est = atan(result.R_total[2,1], result.R_total[1,1])
    @printf("  True:  θ=%.4f  tx=%.4f  ty=%.4f\n", θ_true, tx_true, ty_true)
    @printf("  Found: θ=%.4f  tx=%.4f  ty=%.4f\n", θ_est, result.t_total...)
    @printf("  Error: Δθ=%.4f rad  |Δt|=%.4f m\n",
            abs(θ_est - θ_true), norm(result.t_total - [tx_true, ty_true]))
end

println()
println("Done. Summary:")
println("  - NearestNeighbors.KDTree  → O(log N) search per query point")
println("  - LinearAlgebra.svd        → optimal R,t from matched pairs")
println("  - Statistics.median        → robust outlier threshold")
println("  - Warm start               → escapes the local minimum trap")
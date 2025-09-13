from flask import Blueprint, request, jsonify, g, current_app
from db import SessionLocal
from models import InvestmentPlan
from auth import token_required
from math import pow, sqrt
import json

invest_suggestion_bp = Blueprint("invest_suggestion", __name__, url_prefix="/api/invest")

# ---------- Assumptions: expected returns and volatilities ----------
# These are tunable. Values are annual decimals.
_ASSET_ASSUMPTIONS = {
    "stocks": {"mu": 0.08, "sigma": 0.18},
    "bonds": {"mu": 0.035, "sigma": 0.06},
    "commodities": {"mu": 0.045, "sigma": 0.12},
    "cash": {"mu": 0.01, "sigma": 0.01},
}

# simple correlation matrix (symmetric) - tune as needed
_ASSET_CORR = {
    ("stocks", "stocks"): 1.0,
    ("bonds", "bonds"): 1.0,
    ("commodities", "commodities"): 1.0,
    ("cash", "cash"): 1.0,

    ("stocks", "bonds"): 0.2,
    ("stocks", "commodities"): 0.35,
    ("stocks", "cash"): 0.05,

    ("bonds", "commodities"): 0.05,
    ("bonds", "cash"): 0.1,

    ("commodities", "cash"): 0.02,
}
# helper to get correlation
def _corr(a, b):
    if (a,b) in _ASSET_CORR: return _ASSET_CORR[(a,b)]
    if (b,a) in _ASSET_CORR: return _ASSET_CORR[(b,a)]
    return 0.0

# Convert risk label to numeric score 0..1
def _risk_score(risk_label: str) -> float:
    r = (risk_label or "MEDIUM").strip().upper()
    if r == "LOW": return 0.25
    if r == "HIGH": return 0.85
    return 0.50  # MEDIUM

def _normalize_weights(raw: dict):
    s = sum(raw.values())
    if s <= 0:
        # fallback: even split
        n = len(raw)
        return {k: 1.0/n for k in raw}
    return {k: float(v)/s for k,v in raw.items()}

def _portfolio_volatility(weights: dict) -> float:
    """
    Compute portfolio volatility (annual) from weights, asset sigmas and correlation matrix.
    Var = w^T Cov w
    """
    keys = list(weights.keys())
    # build covariance on the fly
    var = 0.0
    for i,k1 in enumerate(keys):
        for j,k2 in enumerate(keys):
            wi = weights[k1]; wj = weights[k2]
            sigma_i = _ASSET_ASSUMPTIONS[k1]["sigma"]
            sigma_j = _ASSET_ASSUMPTIONS[k2]["sigma"]
            rho = _corr(k1, k2)
            cov = rho * sigma_i * sigma_j
            var += wi * wj * cov
    vol = sqrt(max(0.0, var))
    return vol

def _portfolio_expected_return(weights: dict) -> float:
    return sum(weights[k] * _ASSET_ASSUMPTIONS[k]["mu"] for k in weights)

def _dynamic_allocation(risk: str, horizon_months: int = 60):
    """
    Calculate allocation and expected annual return based on risk + horizon.
    Returns dict: {allocation: {...percent ints...}, expected_return: float}
    """
    # basic numeric risk
    rs = _risk_score(risk)  # 0.0..1.0
    horizon_years = max(0.1, float(horizon_months) / 12.0)

    # time factor: longer horizon -> tilt to risk assets (stocks/commodities) up to limit
    time_factor = 1.0 + max(-0.3, min(0.45, (horizon_years - 3.0) * 0.06))

    # base ideas:
    # - stocks weight grows with risk and horizon
    # - commodities are moderate allocation for inflation/commodity exposure, grows with risk/horizon
    # - cash = safety bucket inversely proportional to risk
    # - bonds soak up remainder and provide ballast

    raw = {}
    raw["stocks"] = rs * 0.75 * time_factor              # primary growth engine
    raw["commodities"] = 0.05 + (rs * 0.12) + min(0.08, horizon_years * 0.02)
    raw["cash"] = max(0.02, 0.16 * (1.0 - rs))           # more cash for low-risk users
    # bonds get logical remainder
    # normalize raw stocks+commodities+cash then set bonds to remainder
    tmp = raw["stocks"] + raw["commodities"] + raw["cash"]
    raw["bonds"] = max(0.0, (1.0 - tmp))

    # If we overshot (tmp > 1), scale down stocks/commodities/cash proportionally and set bonds=0
    if raw["bonds"] < 0.0:
        scale = 1.0 / tmp
        raw["stocks"] *= scale
        raw["commodities"] *= scale
        raw["cash"] *= scale
        raw["bonds"] = 0.0

    # normalize again for safety
    weights = _normalize_weights(raw)

    # convert to percent ints
    allocation_pct = {k: int(round(v * 100.0)) for k,v in weights.items()}
    # correct rounding to sum 100
    s = sum(allocation_pct.values())
    if s != 100:
        # adjust the largest weight to absorb rounding diff
        diff = 100 - s
        maxk = max(allocation_pct.keys(), key=lambda k: allocation_pct[k])
        allocation_pct[maxk] += diff

    # expected annual return: weighted average minus small volatility penalty
    port_mu = _portfolio_expected_return(weights)
    port_vol = _portfolio_volatility(weights)
    # penalty factor: you can tune this. It penalizes high-volatility mixes slightly so expected_return is practical.
    penalty = 0.5 * port_vol
    expected_annual = max(0.0, port_mu - penalty)

    return {"allocation": allocation_pct, "expected_return": round(expected_annual, 6), "port_mean": round(port_mu,6), "port_vol": round(port_vol,6)}


# --- Endpoints ---
def _monthly_sip_for_target(target: float, monthly_rate: float, months: int) -> float:
    if months <= 0:
        return float(target)
    if abs(monthly_rate) < 1e-12:
        return float(target) / months
    denom = pow(1 + monthly_rate, months) - 1.0
    if denom == 0:
        return float(target) / months
    payment = float(target) * monthly_rate / denom
    return payment

# -------------------------
# compute endpoint for preview (current user)
# POST /api/invest/compute
# -------------------------
@invest_suggestion_bp.route("/compute", methods=["POST"])
@token_required
def compute_suggestion_current_user():
    """
    Compute allocation, expected_annual_return and monthly_sip without persisting.
    Request body:
      { "goal": "My goal", "target_amount": 100000, "horizon_months": 60, "risk_profile": "MEDIUM" }
    Response:
      { "goal": "...", "target_amount": ..., "horizon_months": ..., "risk_profile": "...",
        "allocation": {...}, "expected_annual_return": 0.06, "monthly_sip": 1234.56, "port_mean": ..., "port_vol": ... }
    """
    if not getattr(g, "current_user", None):
        return jsonify({"error": "Authentication required"}), 401

    data = request.get_json() or {}
    goal = (data.get("goal") or data.get("goal_name") or "").strip()
    try:
        target = float(data.get("target_amount", 0.0))
    except Exception:
        return jsonify({"error": "target_amount must be numeric"}), 400
    horizon = int(data.get("horizon_months", 0) or 0)
    risk = (data.get("risk_profile") or "").strip().upper() or "MEDIUM"

    if not goal or target <= 0 or horizon <= 0:
        return jsonify({"error":"goal, target_amount (>0) and horizon_months (>0) are required"}), 400

    try:
        defaults = _dynamic_allocation(risk, horizon)
        allocation = defaults["allocation"]
        expected_annual = defaults["expected_return"]
        port_mean = defaults.get("port_mean")
        port_vol = defaults.get("port_vol")

        monthly_rate = expected_annual / 12.0
        sip = _monthly_sip_for_target(target, monthly_rate, horizon)

        return jsonify({
            "goal": goal,
            "target_amount": target,
            "horizon_months": horizon,
            "risk_profile": risk,
            "allocation": allocation,
            "expected_annual_return": expected_annual,
            "monthly_sip": round(sip, 6),
            "port_mean": port_mean,
            "port_vol": port_vol
        })
    except Exception as e:
        current_app.logger.exception("compute_suggestion failed: %s", e)
        return jsonify({"error": str(e)}), 500


# Create suggestion for specific user (persist)
@invest_suggestion_bp.route("/suggestion/<int:user_id>", methods=["POST"])
@token_required
def create_suggestion(user_id: int):
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error":"Forbidden"}), 403
    data = request.get_json() or {}
    goal = (data.get("goal") or data.get("goal_name") or "").strip()
    horizon = int(data.get("horizon_months", 60))
    target = float(data.get("target_amount", 0.0))
    risk = (data.get("risk_profile") or "").strip().upper() or "MEDIUM"
    notes = data.get("notes")
    if not goal or target <= 0 or horizon <= 0:
        return jsonify({"error":"goal, target_amount (>0) and horizon_months (>0) are required"}), 400

    # dynamic allocation
    defaults = _dynamic_allocation(risk, horizon)
    allocation = defaults["allocation"]
    expected_annual = defaults["expected_return"]

    monthly_rate = expected_annual / 12.0
    sip = _monthly_sip_for_target(target, monthly_rate, horizon)

    db = SessionLocal()
    try:
        plan = InvestmentPlan(
            user_id = user_id,
            goal_name = goal,
            target_amount = target,
            horizon_months = horizon,
            risk_profile = risk,
            expected_annual_return = expected_annual,
            monthly_sip = sip,
            allocation = json.dumps(allocation),
            notes = notes
        )
        db.add(plan)
        db.commit()
        db.refresh(plan)
        return jsonify(plan.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("Failed to create investment suggestion: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()

# Create suggestion for current user
@invest_suggestion_bp.route("/suggestion", methods=["POST"])
@token_required
def create_suggestion_current_user():
    """
    Create suggestion for the currently authenticated user (from token).
    """
    if not getattr(g, "current_user", None):
        return jsonify({"error": "Authentication required"}), 401

    user_id = g.current_user.id
    data = request.get_json() or {}
    goal = (data.get("goal") or data.get("goal_name") or "").strip()
    horizon = int(data.get("horizon_months", 60))
    try:
        target = float(data.get("target_amount", 0.0))
    except Exception:
        return jsonify({"error": "target_amount must be numeric"}), 400
    risk = (data.get("risk_profile") or "").strip().upper() or "MEDIUM"
    notes = data.get("notes")

    if not goal or target <= 0 or horizon <= 0:
        return jsonify({"error":"goal, target_amount (>0) and horizon_months (>0) are required"}), 400

    # compute allocation + expected return on the server
    defaults = _dynamic_allocation(risk, horizon)
    allocation = defaults["allocation"]
    expected_annual = defaults["expected_return"]

    monthly_rate = expected_annual / 12.0
    sip = _monthly_sip_for_target(target, monthly_rate, horizon)

    db = SessionLocal()
    try:
        # Ensure allocation is stored as a JSON string; be defensive about serialization
        try:
            allocation_str = json.dumps(allocation)
        except Exception:
            # fallback to a simple string representation to avoid crash
            allocation_str = str(allocation)

        plan = InvestmentPlan(
            user_id = user_id,
            goal_name = goal,
            target_amount = target,
            horizon_months = horizon,
            risk_profile = risk,
            expected_annual_return = expected_annual,
            monthly_sip = sip,
            allocation = allocation_str,
            notes = notes
        )
        db.add(plan)
        db.commit()
        db.refresh(plan)
        return jsonify(plan.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("Failed to create investment suggestion (current user): %s", e)

        return jsonify({"error": "server_error", "detail": str(e)}), 500
    finally:
        db.close()


# Listing / deleting endpoints remain same as before and will continue to work
@invest_suggestion_bp.route("/suggestions/<int:user_id>", methods=["GET"])
@token_required
def list_suggestions(user_id: int):
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error":"Forbidden"}), 403
    db = SessionLocal()
    try:
        rows = db.query(InvestmentPlan).filter(InvestmentPlan.user_id == user_id).order_by(InvestmentPlan.created_at.desc()).all()
        return jsonify([r.to_dict() for r in rows])
    finally:
        db.close()

@invest_suggestion_bp.route("/suggestions/<int:user_id>/<int:plan_id>", methods=["GET"])
@token_required
def get_suggestion(user_id: int, plan_id: int):
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error":"Forbidden"}), 403
    db = SessionLocal()
    try:
        p = db.get(InvestmentPlan, plan_id)
        if not p or p.user_id != user_id:
            return jsonify({"error":"Not found"}), 404
        return jsonify(p.to_dict())
    finally:
        db.close()

@invest_suggestion_bp.route("/suggestions/<int:user_id>/<int:plan_id>", methods=["DELETE"])
@token_required
def delete_suggestion(user_id: int, plan_id: int):
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error":"Forbidden"}), 403
    db = SessionLocal()
    try:
        p = db.get(InvestmentPlan, plan_id)
        if not p or p.user_id != user_id:
            return jsonify({"error":"Not found"}), 404
        db.delete(p)
        db.commit()
        return jsonify({"status":"deleted"})
    except Exception as e:
        db.rollback()
        current_app.logger.exception("Delete suggestion failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


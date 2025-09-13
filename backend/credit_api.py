import math
import traceback
from datetime import datetime, timedelta
from flask import Blueprint, jsonify, request, current_app, g
from sqlalchemy import func, or_
from db import SessionLocal
from models import FinancialEntry, DebtPlan, DebtBadge, User
from auth import token_required

credit_bp = Blueprint("credit", __name__, url_prefix="/api/credit")

# Define the universe of badges (key -> metadata)
POSSIBLE_BADGES = {
    "first_payment": {
        "title": "First Payment",
        "description": "Made your first debt payment. Nice start!",
        "points": 20
    },
    "plan_created": {
        "title": "Plan Starter",
        "description": "Created a debt payment plan. Good planning!",
        "points": 30
    },
    "consistent_payer": {
        "title": "Consistent Payer",
        "description": "Made payments for 3 consecutive months.",
        "points": 50
    },
    "debt_reduced_10": {
        "title": "Debt Reducer",
        "description": "Reduced outstanding debt by at least 10% over last 3 months.",
        "points": 40
    },
    "debt_free": {
        "title": "Debt-free",
        "description": "No outstanding debts detected. Congratulations!",
        "points": 150
    }
}


# ---------- Helpers ----------
def _get_user_entries(db, user_id):
    """Return all entries for user (we will filter as needed)."""
    return db.query(FinancialEntry).filter(FinancialEntry.user_id == user_id).all()


def _sum_by_conditions(db, user_id, cond):
    """Return sum(FinancialEntry.amount) filtered by cond and user"""
    q = db.query(func.coalesce(func.sum(FinancialEntry.amount), 0.0)).filter(FinancialEntry.user_id == user_id).filter(cond)
    return float(q.scalar() or 0.0)


def _aggregate_debt_simple(db, user_id):
    """
    Simple aggregate using rules:
     - Borrowed: sum of entries where entry_type == 'DEBT'
     - Paid: sum of entries where entry_type == 'EXPENSES' AND category contains 'debt' or 'loan'
    """
    # sum borrowed (DEBT)
    borrowed = float(db.query(func.coalesce(func.sum(FinancialEntry.amount), 0.0)).filter(
        FinancialEntry.user_id == user_id,
        FinancialEntry.entry_type == 'DEBT'
    ).scalar() or 0.0)

    # payments: only EXPENSES where category contains debt/loan
    paid = float(db.query(func.coalesce(func.sum(FinancialEntry.amount), 0.0)).filter(
        FinancialEntry.user_id == user_id,
        FinancialEntry.entry_type == 'EXPENSES',
        or_(
            func.lower(FinancialEntry.category).like('%debt%'),
            func.lower(FinancialEntry.category).like('%loan%')
        )
    ).scalar() or 0.0)
    
    print(borrowed)
    print(paid)

    outstanding = max(0.0, borrowed - paid)
    return {"borrowed": round(borrowed, 2), "paid": round(paid, 2), "outstanding": round(outstanding, 2)}


def _payments_in_month(db, user_id, months_ago=0):
    """
    Sum payments (only EXPENSES with category debt/loan) for the specified month (months_ago: 0 = this month).
    """
    target = (datetime.utcnow().date().replace(day=1) - timedelta(days=months_ago * 30))
    prefix = target.strftime("%Y-%m")
    paid = float(db.query(func.coalesce(func.sum(FinancialEntry.amount), 0.0)).filter(
        FinancialEntry.user_id == user_id,
        func.strftime('%Y-%m', FinancialEntry.entry_date) == prefix,
        FinancialEntry.entry_type == 'EXPENSES',
        or_(
            func.lower(FinancialEntry.category).like('%debt%'),
            func.lower(FinancialEntry.category).like('%loan%')
        )
    ).scalar() or 0.0)
    return paid


def _payments_in_last_n_months(db, user_id, n=3):
    """Return list of paid per month for last n months (most recent first)."""
    res = []
    for i in range(n):
        res.append(_payments_in_month(db, user_id, months_ago=i))
    return res


def _user_has_payment_plan(db, user_id):
    return db.query(DebtPlan).filter(DebtPlan.user_id == user_id).count() > 0


def _award_badge_if_missing(db, user_id, key):
    # check if already exists
    existing = db.query(DebtBadge).filter(DebtBadge.user_id == user_id, DebtBadge.badge_key == key).first()
    if existing:
        return None
    meta = POSSIBLE_BADGES.get(key)
    if not meta:
        return None
    b = DebtBadge(user_id=user_id, badge_key=key, title=meta["title"], description=meta.get("description"))
    db.add(b)
    db.commit()
    db.refresh(b)
    return b.to_dict()


# ----------------------
# Scoring & badge logic
# ----------------------
def compute_credit_score_and_metrics(db, user_id):
    """
    Returns a dict with:
     - score (int 300..850)
     - metrics: borrowed, paid, outstanding, recent_payments (list), has_plan(bool)
     - reasons: list of strings describing adjustments
    """
    agg = _aggregate_debt_simple(db, user_id)
    borrowed = agg["borrowed"]
    paid = agg["paid"]
    outstanding = agg["outstanding"]

    recent = _payments_in_last_n_months(db, user_id, 3)  # [this_month, last_month, prev]
    recent_sum = sum(recent)
    has_plan = _user_has_payment_plan(db, user_id)

    reasons = []

    # base score
    score = 600.0

    # debt ratio penalty (if borrowed > 0)
    if borrowed > 0:
        ratio = outstanding / (borrowed + 1.0)  # avoid division by zero
        penalty = min(200.0, ratio * 200.0)  # scale penalty
        score -= penalty
        reasons.append(f"Debt ratio penalty: -{round(penalty,1)} (ratio {ratio:.2f})")
    else:
        score += 20
        reasons.append("No borrowed records found: +20")

    # reward for having a plan
    if has_plan:
        score += 30
        reasons.append("+30 for having a payment plan")

    # reward for recent payments
    if recent_sum > 0:
        bonus = min(80.0, math.log1p(recent_sum) * 8.0)
        score += bonus
        reasons.append(f"+{round(bonus,1)} for recent payments ({round(recent_sum,2)})")

    # consistent payer bonus: payments in each of last 3 months > 0
    if all(p > 0.0 for p in recent):
        score += 50
        reasons.append("+50 for consistent payments in last 3 months")

    # debt-free giant bonus
    if outstanding <= 0:
        score += 150
        reasons.append("+150 debt-free bonus")

    # clamp to 300..850
    final = int(max(300, min(850, round(score))))
    return {
        "score": final,
        "borrowed": round(borrowed, 2),
        "paid": round(paid, 2),
        "outstanding": round(outstanding, 2),
        "recent_payments": [round(r, 2) for r in recent],
        "has_plan": bool(has_plan),
        "reasons": reasons
    }


# --------------------------
# API endpoints
# --------------------------
@credit_bp.route("/score", methods=["GET"])
@token_required
def api_get_score():
    user = g.current_user
    db = SessionLocal()
    try:
        res = compute_credit_score_and_metrics(db, user.id)
        # also return user's earned badges
        earned = db.query(DebtBadge).filter(DebtBadge.user_id == user.id).all()
        res["earned_badges"] = [b.to_dict() for b in earned]
        return jsonify(res)
    finally:
        db.close()


@credit_bp.route("/badges", methods=["GET"])
@token_required
def api_list_badges():
    user = g.current_user
    db = SessionLocal()
    try:
        earned = db.query(DebtBadge).filter(DebtBadge.user_id == user.id).all()
        earned_keys = {b.badge_key for b in earned}
        result = []
        for key, meta in POSSIBLE_BADGES.items():
            item = {
                "badge_key": key,
                "title": meta["title"],
                "description": meta.get("description"),
                "points": meta.get("points", 0),
                "earned": key in earned_keys
            }
            # attach earned info if present
            if key in earned_keys:
                b = next((x for x in earned if x.badge_key == key), None)
                if b:
                    item["earned_at"] = b.earned_at.isoformat()
            result.append(item)
        return jsonify({"badges": result})
    finally:
        db.close()


@credit_bp.route("/refresh", methods=["POST"])
@token_required
def api_refresh_and_award():
    """
    Recompute metrics and award badges if user qualifies.
    Returns list of newly awarded badges.
    """
    user = g.current_user
    db = SessionLocal()
    try:
        info = compute_credit_score_and_metrics(db, user.id)
        newly_awarded = []

        # logic to decide awarding:
        # first_payment -> if paid > 0
        if info["paid"] > 0:
            b = _award_badge_if_missing(db, user.id, "first_payment")
            if b:
                newly_awarded.append(b)

        # plan_created -> if user has a DebtPlan
        if info["has_plan"]:
            b = _award_badge_if_missing(db, user.id, "plan_created")
            if b:
                newly_awarded.append(b)

        # consistent_payer -> if all recent months > 0
        if all(p > 0.0 for p in info["recent_payments"]):
            b = _award_badge_if_missing(db, user.id, "consistent_payer")
            if b:
                newly_awarded.append(b)

        # debt_reduced_10 -> check reduction proportion: compare paid in last 3 months vs outstanding
        recent_sum = sum(info["recent_payments"])
        if info["outstanding"] > 0 and recent_sum >= 0.1 * (info["outstanding"] + recent_sum):
            b = _award_badge_if_missing(db, user.id, "debt_reduced_10")
            if b:
                newly_awarded.append(b)

        # debt_free
        if info["outstanding"] <= 0:
            b = _award_badge_if_missing(db, user.id, "debt_free")
            if b:
                newly_awarded.append(b)

        # refresh final state
        earned = db.query(DebtBadge).filter(DebtBadge.user_id == user.id).all()
        return jsonify({"new_badges": newly_awarded, "earned_badges": [b.to_dict() for b in earned], "metrics": info})
    except Exception as e:
        current_app.logger.exception("credit refresh failed: %s", e)
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        db.close()


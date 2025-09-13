import traceback
from datetime import datetime, timedelta, date
from math import ceil
from flask import Blueprint, jsonify, request, current_app, g
from sqlalchemy import Column, Integer, String, Float, DateTime, ForeignKey, Text, Boolean
from sqlalchemy.orm import relationship
from db import Base, engine, SessionLocal
from models import User, DebtPlan
from auth import token_required


bp = Blueprint("debt_plans", __name__, url_prefix="/api/debt/plans")

# -------------------
# Amortization core
# -------------------
def amortization_schedule(principal: float, annual_rate_pct: float, monthly_payment: float, extra_payment: float = 0.0, start_date: datetime = None, max_months: int = 600):
    """
    Return monthly amortization schedule list of dicts:
      [{"period": 1, "date":"YYYY-MM-DD", "payment":..., "interest":..., "principal":..., "balance":...}, ...]
    - monthly interest = annual_rate_pct / 12 / 100
    - if monthly_payment + extra_payment <= monthly_interest_amount -> raise ValueError (won't amortize)
    - stops when balance <= 0 or reaches max_months
    """
    if start_date is None:
        start_date = datetime.utcnow()
    schedule = []
    bal = float(principal)
    r_month = float(annual_rate_pct) / 12.0 / 100.0
    month_idx = 0
    total_interest = 0.0

    if bal <= 0:
        return {"schedule": [], "months": 0, "total_interest": 0.0, "paid": 0.0, "payoff_date": start_date.date().isoformat()}

    # If user didn't supply monthly_payment try to compute using a target amortization if possible
    payment = float(monthly_payment)

    # safety: if payment is smaller than 0 treat as 0
    if payment < 0:
        payment = 0.0

    # iterate months
    while bal > 1e-6 and month_idx < max_months:
        month_idx += 1
        interest_for_month = bal * r_month
        monthly_total_pay = payment + float(extra_payment or 0.0)

        # detect impossible amortization
        if monthly_total_pay <= interest_for_month + 1e-9:
            raise ValueError(f"Monthly payment too small to cover interest in month {month_idx}. monthly interest={interest_for_month:.4f}, monthly_payment+extra={monthly_total_pay:.4f}")

        principal_paid = monthly_total_pay - interest_for_month

        # if principal_paid > bal -> last payment smaller
        if principal_paid >= bal:
            principal_paid = bal
            monthly_total_pay = interest_for_month + principal_paid

        bal = max(0.0, bal - principal_paid)
        total_interest += interest_for_month

        # compute date for this payment
        # schedule payments on same day-of-month as start_date when possible
        sched_date = (start_date + timedelta(days=30 * month_idx))  # approximate monthly step
        schedule.append({
            "period": month_idx,
            "date": sched_date.date().isoformat(),
            "payment": round(monthly_total_pay, 2),
            "interest": round(interest_for_month, 2),
            "principal": round(principal_paid, 2),
            "balance": round(bal, 2)
        })
    payoff_date = schedule[-1]["date"] if schedule else start_date.date().isoformat()
    total_paid = sum(row["payment"] for row in schedule)
    return {
        "schedule": schedule,
        "months": month_idx,
        "total_interest": round(total_interest, 2),
        "total_paid": round(total_paid, 2),
        "payoff_date": payoff_date
    }


# -------------------
# Helpers and endpoints
# -------------------
@bp.route("", methods=["GET"])
@token_required
def list_plans():
    user = g.current_user
    db = SessionLocal()
    try:
        q = db.query(DebtPlan).filter(DebtPlan.user_id == user.id)
        items = [p.to_dict() for p in q.order_by(DebtPlan.created_at.desc()).all()]
        return jsonify({"items": items})
    finally:
        db.close()


@bp.route("", methods=["POST"])
@token_required
def create_plan():
    user = g.current_user
    data = request.get_json() or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name required"}), 400
    try:
        principal = float(data.get("principal", 0.0))
        annual_rate_pct = float(data.get("annual_interest_pct", 0.0))
    except Exception as e:
        return jsonify({"error": "principal and annual_interest_pct must be numbers"}), 400
    minimum_payment = data.get("minimum_payment")
    target_payment = data.get("target_payment")
    start_date = None
    if data.get("start_date"):
        try:
            start_date = datetime.fromisoformat(data.get("start_date"))
        except Exception:
            start_date = datetime.utcnow()
    notes = data.get("notes")
    vendor = data.get("vendor")

    db = SessionLocal()
    try:
        p = DebtPlan(
            user_id=user.id,
            name=name,
            vendor=vendor,
            principal=principal,
            annual_interest_pct=annual_rate_pct,
            minimum_payment=float(minimum_payment) if minimum_payment not in (None, "") else None,
            target_payment=float(target_payment) if target_payment not in (None, "") else None,
            start_date=start_date or datetime.utcnow(),
            notes=notes
        )
        db.add(p)
        db.commit()
        db.refresh(p)
        return jsonify(p.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("create_plan failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@bp.route("/<int:plan_id>", methods=["GET"])
@token_required
def get_plan(plan_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        p = db.get(DebtPlan, plan_id)
        if not p or p.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        # include amortization schedule using target_payment or minimum_payment fallback
        monthly_payment = p.target_payment or p.minimum_payment or 0.0
        if monthly_payment <= 0:
            # try to compute payment needed to amortize in 60 months (if user provided none)
            # using formula for fixed payment: A = r*P/(1-(1+r)^-n)
            r = float(p.annual_interest_pct) / 12.0 / 100.0
            n = 60
            if r > 0:
                denom = 1 - (1 + r) ** (-n)
                monthly_payment = (r * p.principal) / denom if denom != 0 else p.principal / n
            else:
                monthly_payment = p.principal / n
        schedule = amortization_schedule(p.principal, p.annual_interest_pct, monthly_payment, extra_payment=0.0, start_date=p.start_date)
        return jsonify({"plan": p.to_dict(), "schedule": schedule})
    finally:
        db.close()


@bp.route("/<int:plan_id>", methods=["PUT"])
@token_required
def update_plan(plan_id: int):
    user = g.current_user
    data = request.get_json() or {}
    db = SessionLocal()
    try:
        p = db.get(DebtPlan, plan_id)
        if not p or p.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        for field in ("name", "vendor", "notes"):
            if field in data:
                setattr(p, field, data[field])
        if "principal" in data:
            p.principal = float(data["principal"])
        if "annual_interest_pct" in data:
            p.annual_interest_pct = float(data["annual_interest_pct"])
        if "minimum_payment" in data:
            p.minimum_payment = float(data["minimum_payment"]) if data["minimum_payment"] not in (None, "") else None
        if "target_payment" in data:
            p.target_payment = float(data["target_payment"]) if data["target_payment"] not in (None, "") else None
        if "start_date" in data and data["start_date"]:
            try:
                p.start_date = datetime.fromisoformat(data["start_date"])
            except Exception:
                pass
        db.add(p)
        db.commit()
        db.refresh(p)
        return jsonify(p.to_dict())
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@bp.route("/<int:plan_id>", methods=["DELETE"])
@token_required
def delete_plan(plan_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        p = db.get(DebtPlan, plan_id)
        if not p or p.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        db.delete(p)
        db.commit()
        return jsonify({"status": "deleted"})
    finally:
        db.close()


@bp.route("/<int:plan_id>/simulate", methods=["POST"])
@token_required
def simulate_plan(plan_id: int):
    """
    Body example:
    { "extra_payment": 100.0, "override_monthly_payment": 500.0 }
    Returns schedule with given extra payments or override monthly payment.
    """
    user = g.current_user
    data = request.get_json() or {}
    extra_payment = float(data.get("extra_payment", 0.0))
    override_payment = data.get("override_monthly_payment")
    db = SessionLocal()
    try:
        p = db.get(DebtPlan, plan_id)
        if not p or p.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        monthly_payment = float(override_payment) if override_payment not in (None, "") else (p.target_payment or p.minimum_payment or 0.0)
        if monthly_payment <= 0:
            # use 60 month amortization default if no payment specified
            r = float(p.annual_interest_pct) / 12.0 / 100.0
            n = 60
            if r > 0:
                denom = 1 - (1 + r) ** (-n)
                monthly_payment = (r * p.principal) / denom if denom != 0 else p.principal / n
            else:
                monthly_payment = p.principal / n

        schedule = amortization_schedule(p.principal, p.annual_interest_pct, monthly_payment, extra_payment=extra_payment, start_date=p.start_date)
        return jsonify({"plan": p.to_dict(), "simulation": schedule})
    except ValueError as ve:
        return jsonify({"error": str(ve)}), 400
    except Exception as e:
        current_app.logger.exception("simulate_plan failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


# Suggest allocation across many debts (simple snowball/avalanche)
@bp.route("/suggest", methods=["POST"])
@token_required
def suggest_allocation():
    """
    Body example:
    {
      "debts": [
         {"id":1, "principal":..., "annual_interest_pct":..., "minimum_payment":...},
         ...
      ],
      "strategy": "snowball" | "avalanche",
      "available_extra": 200.0
    }
    Returns simple suggested allocation of extra payments and estimated payoff months per debt.
    """
    user = g.current_user
    data = request.get_json() or {}
    debts = data.get("debts") or []
    strategy = (data.get("strategy") or "snowball").lower()
    available_extra = float(data.get("available_extra", 0.0))

    # build internal structures
    debts2 = []
    for d in debts:
        debts2.append({
            "id": d.get("id"),
            "principal": float(d.get("principal", 0.0)),
            "annual_interest_pct": float(d.get("annual_interest_pct", 0.0)),
            "minimum_payment": float(d.get("minimum_payment", 0.0))
        })

    if not debts2:
        return jsonify({"error": "no debts provided"}), 400

    # order debts
    if strategy == "snowball":
        debts2.sort(key=lambda x: x["principal"])  # smallest first
    else:
        debts2.sort(key=lambda x: -x["annual_interest_pct"])  # highest interest first (avalanche)

    # allocate available_extra to first debt(s)
    # naive: add all extra to the first debt until paid, then next
    suggestions = []
    extra_left = available_extra
    for d in debts2:
        sug_extra = 0.0
        if extra_left > 0:
            sug_extra = extra_left
            extra_left = 0.0
        # estimate months to payoff using amortization (monthly_payment = minimum_payment + sug_extra)
        try:
            monthly_payment = d["minimum_payment"] + sug_extra
            sim = amortization_schedule(d["principal"], d["annual_interest_pct"], monthly_payment, extra_payment=0.0)
            est_months = sim["months"]
            payoff_date = sim["payoff_date"]
        except Exception:
            est_months = None
            payoff_date = None
        suggestions.append({
            "id": d["id"],
            "principal": d["principal"],
            "annual_interest_pct": d["annual_interest_pct"],
            "minimum_payment": d["minimum_payment"],
            "suggested_extra_allocation": round(sug_extra, 2),
            "estimated_months": est_months,
            "estimated_payoff_date": payoff_date
        })

    return jsonify({"strategy": strategy, "available_extra": available_extra, "suggestions": suggestions})


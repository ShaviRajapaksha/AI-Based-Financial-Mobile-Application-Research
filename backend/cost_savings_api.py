import os
import io
import traceback
from datetime import datetime, date, timedelta, timezone
from flask import Blueprint, request, jsonify, current_app, g, send_from_directory
from sqlalchemy import Column, Integer, String, Float, DateTime, Date, Text, ForeignKey, func, desc, text

from sqlalchemy.orm import relationship, Session
from db import Base, SessionLocal
from models import User, FinancialEntry
from auth import token_required
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
import requests



bp = Blueprint("cost_savings", __name__, url_prefix="/api/expense")

REPORT_DIR = os.path.join(os.path.dirname(__file__), "cs_reports")
os.makedirs(REPORT_DIR, exist_ok=True)

# Models (lightweight - stored in same DB)
class SavingsGoal(Base):
    __tablename__ = "savings_goals"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(300), nullable=False)
    target_amount = Column(Float, nullable=False)  # target total
    target_date = Column(Date, nullable=True)  # deadline
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    notes = Column(Text, nullable=True)

    user = relationship("User")

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "name": self.name,
            "target_amount": float(self.target_amount or 0.0),
            "target_date": self.target_date.isoformat() if self.target_date else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "notes": self.notes,
        }

class SavingsContribution(Base):
    __tablename__ = "savings_contributions"
    id = Column(Integer, primary_key=True)
    goal_id = Column(Integer, ForeignKey("savings_goals.id", ondelete="CASCADE"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    amount = Column(Float, nullable=False)
    contrib_date = Column(Date, nullable=False)
    notes = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    goal = relationship("SavingsGoal")
    user = relationship("User")

    def to_dict(self):
        return {
            "id": self.id,
            "goal_id": self.goal_id,
            "user_id": self.user_id,
            "amount": float(self.amount or 0.0),
            "contrib_date": self.contrib_date.isoformat(),
            "notes": self.notes,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }

class SavingsReport(Base):
    __tablename__ = "savings_reports"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(300), nullable=False)
    filename = Column(String(500), nullable=False)
    size = Column(Integer, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    user = relationship("User")
    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "name": self.name,
            "filename": self.filename,
            "size": self.size,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }

# ensure tables exist
Base.metadata.create_all(bind=SessionLocal().get_bind())


# -------------------------
# Helper utilities
# -------------------------
def _iso(d):
    if d is None: return None
    if isinstance(d, (datetime,)):
        return d.isoformat()
    if isinstance(d, date):
        return d.isoformat()
    return str(d)

def _sum_contributions(db: Session, user_id: int, goal_id: int):
    s = db.query(func.coalesce(func.sum(SavingsContribution.amount), 0.0)).filter(
        SavingsContribution.user_id == user_id,
        SavingsContribution.goal_id == goal_id
    ).scalar() or 0.0
    return float(s)

def _get_goal_progress(db: Session, goal: SavingsGoal):
    total_saved = _sum_contributions(db, goal.user_id, goal.id)
    target = float(goal.target_amount or 0.0)
    percent = (total_saved / target * 100.0) if target > 0 else 0.0
    percent = min(100.0, percent)
    remaining = max(0.0, target - total_saved)
    # months left
    if goal.target_date:
        today = date.today()
        delta_months = max(1, (goal.target_date.year - today.year) * 12 + (goal.target_date.month - today.month))
    else:
        delta_months = None
    # current monthly required
    monthly_required = (remaining / delta_months) if delta_months and delta_months > 0 else None
    return {
        "total_saved": round(total_saved, 2),
        "target_amount": round(target, 2),
        "percent": round(percent, 2),
        "remaining": round(remaining, 2),
        "months_left": delta_months,
        "monthly_required": round(monthly_required, 2) if monthly_required is not None else None
    }

def _adaptive_micro_targets(db: Session, goal: SavingsGoal):
    """
    If user is behind schedule, suggest a new monthly target for remaining months.
    """
    prog = _get_goal_progress(db, goal)
    months_left = prog["months_left"]
    if months_left is None or months_left <= 0:
        return {"suggested_monthly": None, "message": "No deadline or already due."}
    # months elapsed from start assumption: we don't have start; assume created_at as start
    created = goal.created_at.date() if goal.created_at else date.today()
    total_months = max(1, (goal.target_date.year - created.year) * 12 + (goal.target_date.month - created.month)) if goal.target_date else None
    # expected_saved_by_now = (elapsed/total)*target
    today = date.today()
    elapsed_months = max(0, (today.year - created.year) * 12 + (today.month - created.month))
    suggested = None
    message = ""
    if total_months and total_months > 0:
        expected_by_now = (elapsed_months / total_months) * float(goal.target_amount)
        actual_saved = prog["total_saved"]
        if actual_saved < expected_by_now:
            remaining = prog["remaining"]
            # recompute monthly to catch up
            suggested_monthly = round(remaining / months_left, 2)
            suggested = suggested_monthly
            message = f"You are behind schedule. Expected ~{expected_by_now:.2f} by now but saved {actual_saved:.2f}. Suggest {suggested_monthly:.2f}/month to catch up."
        else:
            message = "On track or ahead of schedule."
    else:
        message = "Insufficient deadline info to compute adaptive target."
    return {"suggested_monthly": suggested, "message": message}


# -------------------------
# Endpoints: Goals CRUD
# -------------------------
@bp.route("/goals", methods=["GET"])
@token_required
def list_goals():
    """
    Returns list of goals with quick progress summary for each goal.
    """
    user = g.current_user
    db = SessionLocal()
    try:
        rows = db.query(SavingsGoal).filter(SavingsGoal.user_id == user.id).order_by(SavingsGoal.created_at.desc()).all()
        out = []
        for r in rows:
            try:
                progress = _get_goal_progress(db, r)
            except Exception:
                # If progress computation fails for a goal, return a safe default
                progress = {"total_saved": 0.0, "target_amount": float(r.target_amount or 0.0), "percent": 0.0, "remaining": float(r.target_amount or 0.0), "months_left": None, "monthly_required": None}
            d = r.to_dict()
            d["progress"] = progress
            out.append(d)
        return jsonify(out)
    finally:
        db.close()

@bp.route("/goals", methods=["POST"])
@token_required
def create_goal():
    user = g.current_user
    data = request.get_json() or {}
    name = (data.get("name") or "").strip()
    target_amount = float(data.get("target_amount") or 0.0)
    target_date = data.get("target_date")
    notes = data.get("notes")
    if not name or target_amount <= 0:
        return jsonify({"error": "name and positive target_amount required"}), 400
    db = SessionLocal()
    try:
        td = None
        if target_date:
            try:
                td = date.fromisoformat(target_date)
            except Exception:
                return jsonify({"error": "target_date must be ISO YYYY-MM-DD"}), 400
        gobj = SavingsGoal(user_id=user.id, name=name, target_amount=target_amount, target_date=td, notes=notes)
        db.add(gobj)
        db.commit()
        db.refresh(gobj)
        return jsonify(gobj.to_dict()), 201
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()

@bp.route("/goals/<int:goal_id>", methods=["GET"])
@token_required
def get_goal(goal_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        gobj = db.get(SavingsGoal, goal_id)
        if not gobj or gobj.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        # contributions
        contribs = db.query(SavingsContribution).filter(SavingsContribution.goal_id == goal_id).order_by(SavingsContribution.contrib_date.desc()).all()
        return jsonify({"goal": gobj.to_dict(), "progress": _get_goal_progress(db, gobj), "adaptive": _adaptive_micro_targets(db, gobj), "contributions": [c.to_dict() for c in contribs]})
    finally:
        db.close()

@bp.route("/goals/<int:goal_id>", methods=["PUT"])
@token_required
def update_goal(goal_id: int):
    user = g.current_user
    data = request.get_json() or {}
    db = SessionLocal()
    try:
        gobj = db.get(SavingsGoal, goal_id)
        if not gobj or gobj.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        if "name" in data: gobj.name = data["name"]
        if "target_amount" in data: gobj.target_amount = float(data["target_amount"])
        if "target_date" in data:
            td = data.get("target_date")
            gobj.target_date = date.fromisoformat(td) if td else None
        if "notes" in data: gobj.notes = data.get("notes")
        db.add(gobj); db.commit(); db.refresh(gobj)
        return jsonify(gobj.to_dict())
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()

@bp.route("/goals/<int:goal_id>", methods=["DELETE"])
@token_required
def delete_goal(goal_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        gobj = db.get(SavingsGoal, goal_id)
        if not gobj or gobj.user_id != user.id:
            return jsonify({"error":"Not found"}), 404
        db.delete(gobj); db.commit()
        return jsonify({"status": "deleted"})
    finally:
        db.close()


# -------------------------
# Contributions
# -------------------------
@bp.route("/goals/<int:goal_id>/contribute", methods=["POST"])
@token_required
def add_contribution(goal_id: int):
    user = g.current_user
    data = request.get_json() or {}
    amount = float(data.get("amount") or 0.0)
    contrib_date = data.get("date")
    notes = data.get("notes")
    if amount <= 0:
        return jsonify({"error": "amount positive required"}), 400
    try:
        cd = date.fromisoformat(contrib_date) if contrib_date else date.today()
    except Exception:
        return jsonify({"error":"date must be YYYY-MM-DD"}), 400

    db = SessionLocal()
    try:
        gobj = db.get(SavingsGoal, goal_id)
        if not gobj or gobj.user_id != user.id:
            return jsonify({"error":"Not found"}), 404
        c = SavingsContribution(goal_id=goal_id, user_id=user.id, amount=amount, contrib_date=cd, notes=notes)
        db.add(c)
        db.commit()
        db.refresh(c)
        return jsonify(c.to_dict()), 201
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()

@bp.route("/goals/<int:goal_id>/contributions", methods=["GET"])
@token_required
def list_contributions(goal_id:int):
    user = g.current_user
    db = SessionLocal()
    try:
        gobj = db.get(SavingsGoal, goal_id)
        if not gobj or gobj.user_id != user.id:
            return jsonify({"error":"Not found"}), 404
        rows = db.query(SavingsContribution).filter(SavingsContribution.goal_id == goal_id).order_by(SavingsContribution.contrib_date.desc()).all()
        return jsonify([r.to_dict() for r in rows])
    finally:
        db.close()


# -------------------------
# Reports (PDF)
# -------------------------
def _make_progress_chart(df_dates_amounts: pd.DataFrame) -> bytes:
    """
    df_dates_amounts: DataFrame with columns ['date' (datetime.date), 'cum'] sorted by date
    returns PNG bytes
    """
    fig, ax = plt.subplots(figsize=(8,3), dpi=100)
    if df_dates_amounts.empty:
        ax.text(0.5, 0.5, "No contributions", ha='center', va='center')
    else:
        ax.plot(df_dates_amounts['date'], df_dates_amounts['cum'], marker='o', linewidth=2)
        ax.set_xlabel("Date")
        ax.set_ylabel("Cumulative saved")
        ax.grid(True, alpha=0.3)
    buf = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buf, format='png')
    plt.close(fig)
    buf.seek(0)
    return buf.read()

def _render_savings_pdf(user: User, name: str, goal: SavingsGoal, contributions: list, out_path: str):
    pdf = canvas.Canvas(out_path, pagesize=A4)
    w,h = A4
    margin = 18*mm
    x = margin; y = h - margin
    pdf.setFont("Helvetica-Bold", 16)
    pdf.drawString(x,y, f"Savings Report — {goal.name}")
    pdf.setFont("Helvetica", 10)
    y -= 18
    pdf.drawString(x, y, f"User: {user.name or user.email}   Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    y -= 16
    pdf.drawString(x, y, f"Target: {goal.target_amount:.2f} • Deadline: {goal.target_date.isoformat() if goal.target_date else '—'}")
    y -= 18

    # build dataframe for cumulative
    rows = []
    cum = 0.0
    for c in sorted(contributions, key=lambda r: r['contrib_date']):
        d = date.fromisoformat(c['contrib_date']) if isinstance(c['contrib_date'], str) else c['contrib_date']
        cum += float(c['amount'])
        rows.append({"date": d, "cum": cum})
    df = pd.DataFrame(rows)
    if df.empty:
        pdf.drawString(x, y, "No contributions yet.")
        y -= 16
    else:
        img_bytes = _make_progress_chart(df)
        img_reader = ImageReader(io.BytesIO(img_bytes))
        pdf.drawImage(img_reader, x, y-120, width=160*mm, height=60*mm, preserveAspectRatio=True, mask='auto')
        y -= (120 + 8)

    pdf.setFont("Helvetica-Bold", 12)
    pdf.drawString(x, y, "Contributions (recent)")
    pdf.setFont("Helvetica", 9)
    y -= 14
    for c in sorted(contributions, key=lambda r: r['contrib_date'], reverse=True)[:20]:
        pdf.drawString(x, y, f"{c['contrib_date']} • {c.get('amount', 0):.2f} • {c.get('notes') or ''}")
        y -= 12
        if y < margin + 60:
            pdf.showPage(); y = h - margin
    pdf.showPage(); pdf.save()


@bp.route("/reports", methods=["POST"])
@token_required
def create_savings_report():
    """
    POST { "goal_id": <id>, "name": "My monthly savings" }
    """
    user = g.current_user
    data = request.get_json() or {}
    goal_id = data.get("goal_id")
    name = data.get("name") or f"Savings report {datetime.utcnow().date().isoformat()}"
    if not goal_id:
        return jsonify({"error":"goal_id required"}), 400
    db = SessionLocal()
    try:
        goal = db.get(SavingsGoal, goal_id)
        if not goal or goal.user_id != user.id:
            return jsonify({"error":"Goal not found"}), 404
        contributions = [c.to_dict() for c in db.query(SavingsContribution).filter(SavingsContribution.goal_id==goal_id).order_by(SavingsContribution.contrib_date.asc()).all()]
        filename = f"savings_report_user{user.id}_goal{goal.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}.pdf"
        out_path = os.path.join(REPORT_DIR, filename)
        _render_savings_pdf(user, name, goal, contributions, out_path)
        size = os.path.getsize(out_path)
        rpt = SavingsReport(user_id=user.id, name=name, filename=filename, size=size)
        db.add(rpt); db.commit(); db.refresh(rpt)
        return jsonify(rpt.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("create_savings_report failed: %s", e)
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        db.close()

@bp.route("/reports", methods=["GET"])
@token_required
def list_savings_reports():
    user = g.current_user
    db = SessionLocal()
    try:
        items = db.query(SavingsReport).filter(SavingsReport.user_id==user.id).order_by(SavingsReport.created_at.desc()).all()
        return jsonify([i.to_dict() for i in items])
    finally:
        db.close()

@bp.route("/reports/<int:report_id>/download", methods=["GET"])
@token_required
def download_report(report_id:int):
    user = g.current_user
    db = SessionLocal()
    try:
        r = db.get(SavingsReport, report_id)
        if not r or r.user_id != user.id:
            return jsonify({"error":"Not found"}), 404
        return send_from_directory(REPORT_DIR, r.filename, as_attachment=True, download_name=r.filename)
    finally:
        db.close()


# -------------------------
# --- RAG + Gemini chat endpoint for personalized savings advice ---


# Helper: build retrieval context from user's data
def _build_rag_context_for_user(db, user_id: int, days_back: int = 180, max_entries: int = 40):
    """
    Returns:
      - context_text: big multiline string the LLM can use
      - sources: list of small dicts with items included (for provenance)
    """
    cutoff = date.today() - timedelta(days=days_back)

    # Recent expense entries (limit recent + non-zero)
    recent_exp_q = db.query(
        FinancialEntry.id,
        FinancialEntry.entry_date,
        FinancialEntry.entry_type,
        FinancialEntry.category,
        FinancialEntry.vendor,
        FinancialEntry.amount,
        FinancialEntry.currency,
        FinancialEntry.notes
    ).filter(
        FinancialEntry.user_id == user_id,
        FinancialEntry.entry_date >= cutoff
    ).order_by(FinancialEntry.entry_date.desc()).limit(max_entries)
    recent_expenses = [dict(
        id=r.id,
        date=(r.entry_date.isoformat() if r.entry_date else None),
        type=r.entry_type,
        category=(r.category or "Uncategorized"),
        vendor=(r.vendor or ""),
        amount=float(r.amount or 0.0),
        currency=(r.currency or ""),
        notes=(r.notes or "")
    ) for r in recent_exp_q.all()]

    # Top spending categories (last days_back)
    top_cats_q = db.query(
        FinancialEntry.category,
        func.coalesce(func.sum(FinancialEntry.amount), 0.0).label("total")
    ).filter(
        FinancialEntry.user_id == user_id,
        FinancialEntry.entry_type == 'EXPENSES',
        FinancialEntry.entry_date >= cutoff
    ).group_by(FinancialEntry.category).order_by(desc(func.sum(FinancialEntry.amount))).limit(8)
    top_categories = [{"category": (r[0] or "Uncategorized"), "total": float(r[1])} for r in top_cats_q.all()]

    # Recent incomes (last 6 entries)
    income_q = db.query(
        FinancialEntry.entry_date,
        FinancialEntry.amount,
        FinancialEntry.currency,
        FinancialEntry.vendor,
        FinancialEntry.category,
        FinancialEntry.notes,
    ).filter(
        FinancialEntry.user_id == user_id,
        FinancialEntry.entry_type == 'INCOME',
        FinancialEntry.entry_date >= cutoff
    ).order_by(FinancialEntry.entry_date.desc()).limit(6)
    recent_incomes = [{"date": (r.entry_date.isoformat() if r.entry_date else None), "amount": float(r.amount or 0.0), "currency": (r.currency or ""), "vendor": (r.vendor or ""), "category": (r.category or ""), "notes": (r.notes or "")} for r in income_q.all()]

    # Savings goals & contributions (recent)
    goals_q = db.query(SavingsGoal).filter(SavingsGoal.user_id == user_id).order_by(SavingsGoal.created_at.desc()).all()
    goals = []
    for goal_obj in goals_q:
        total = db.query(func.coalesce(func.sum(SavingsContribution.amount), 0.0)).filter(SavingsContribution.goal_id == goal_obj.id).scalar() or 0.0
        contribs_q = db.query(SavingsContribution.contrib_date, SavingsContribution.amount, SavingsContribution.notes).filter(SavingsContribution.goal_id == goal_obj.id).order_by(SavingsContribution.contrib_date.desc()).limit(6)
        contribs = [{"date": (c.contrib_date.isoformat() if c.contrib_date else None), "amount": float(c.amount), "notes": (c.notes or "")} for c in contribs_q.all()]
        goals.append({
            "id": goal_obj.id,
            "name": goal_obj.name,
            "target_amount": float(goal_obj.target_amount or 0.0),
            "target_date": (goal_obj.target_date.isoformat() if goal_obj.target_date else None),
            "total_saved": float(total),
            "recent_contribs": contribs
        })

    # Monthly net flow (last 12 months) and current month net_flow
    sql_monthly = text("""
        SELECT strftime('%Y-%m', entry_date) AS ym,
               SUM(CASE WHEN entry_type = 'INCOME' THEN amount ELSE 0 END) AS income,
               SUM(CASE WHEN entry_type = 'EXPENSES' THEN amount ELSE 0 END) AS expenses
        FROM financial_entries
        WHERE user_id = :uid AND entry_date >= :since
        GROUP BY ym
        ORDER BY ym ASC
    """)
    since_iso = (date.today() - timedelta(days=365)).isoformat()
    net_rows = db.execute(sql_monthly, {"uid": user_id, "since": since_iso}).fetchall()
    monthly = []
    for r in net_rows:
        monthly.append({"month": r[0], "income": float(r[1] or 0.0), "expenses": float(r[2] or 0.0), "net_flow": float((r[1] or 0.0) - (r[2] or 0.0))})

    # current month values (defensive)
    current_month = None
    if monthly:
        current_month = monthly[-1]
    else:
        sql_cm = text("""
            SELECT
                SUM(CASE WHEN entry_type='INCOME' THEN amount ELSE 0 END) AS income,
                SUM(CASE WHEN entry_type='EXPENSES' THEN amount ELSE 0 END) AS expenses
            FROM financial_entries
            WHERE user_id = :uid AND entry_date >= :cm
        """)
        cm_start = date.today().replace(day=1).isoformat()
        row = db.execute(sql_cm, {"uid": user_id, "cm": cm_start}).fetchone()
        if row:
            current_month = {"month": date.today().strftime("%Y-%m"), "income": float(row[0] or 0.0), "expenses": float(row[1] or 0.0), "net_flow": float((row[0] or 0.0) - (row[1] or 0.0))}

    # money in hand (simple current liquidity)
    sql_balance = text("""
        SELECT 
           SUM(CASE WHEN entry_type = 'INCOME' THEN amount ELSE -amount END) AS balance
        FROM financial_entries
        WHERE user_id = :uid
    """)
    bal_row = db.execute(sql_balance, {"uid": user_id}).fetchone()
    money_in_hand = float(bal_row[0] or 0.0) if bal_row and bal_row[0] is not None else 0.0

    # Compose context text
    parts = []
    parts.append("---- SUMMARY ----")
    parts.append(f"Current month ({current_month['month'] if current_month else 'N/A'}): income={current_month['income'] if current_month else '0.0'}, expenses={current_month['expenses'] if current_month else '0.0'}, net_flow={current_month['net_flow'] if current_month else '0.0'}")
    parts.append(f"Money-in-hand (simple sum): {money_in_hand:.2f}")
    parts.append("---- TOP CATEGORIES ----")
    for t in top_categories:
        parts.append(f"TOP_CAT | {t['category']} | total={t['total']:.2f}")
    parts.append("---- RECENT EXPENSES ----")
    for e in recent_expenses[:max_entries]:
        parts.append(f"EXPENSE | date={e['date']} | category={e['category']} | vendor={e['vendor']} | amount={e['amount']:.2f} | currency={e['currency']} | notes={e['notes']}")
    parts.append("---- RECENT INCOMES ----")
    for inc in recent_incomes:
        parts.append(f"INCOME | date={inc['date']} | category={e['category']} | vendor={e['vendor']} | amount={inc['amount']:.2f} | currency={e['currency']} | notes={e['notes']}")
    parts.append("---- SAVINGS GOALS ----")
    for goal in goals:
        parts.append(f"GOAL | name={goal['name']} | target={goal['target_amount']:.2f} | saved={goal['total_saved']:.2f} | deadline={goal['target_date']}")
        for c in goal['recent_contribs']:
            parts.append(f"GOAL_CONTRIB | date={c['date']} | amount={c['amount']:.2f}")

    context_text = "\n".join(parts)

    sources = {
        "recent_expenses": recent_expenses,
        "top_categories": top_categories,
        "recent_incomes": recent_incomes,
        "goals": goals,
        "monthly": monthly,
        "money_in_hand": money_in_hand
    }

    return context_text, sources



# Helper: call Gemini via Generative Language REST API
def _call_gemini_generate(prompt_text: str, max_tokens: int = 3000):
    """
    Calls Google Generative Language (Gemini) model via REST. Returns string on success or None.
    """
    key = os.environ.get("GOOGLE_API_KEY")
    if not key:
        return None, {"error": "GOOGLE_API_KEY not set"}

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key={key}"
    headers = {"Content-Type": "application/json"}

    body = {
        "contents": [
            {
                "parts": [
                    {"text": prompt_text}
                ]
            }
        ],
        "generationConfig": {
            "temperature": 0.2,
            "maxOutputTokens": max_tokens,
            "candidateCount": 1
        },
        "safetySettings": [
            {
                "category": "HARM_CATEGORY_HARASSMENT",
                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
            },
            {
                "category": "HARM_CATEGORY_HATE_SPEECH",
                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
            },
            {
                "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
            },
            {
                "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
                "threshold": "BLOCK_MEDIUM_AND_ABOVE"
            }
        ]
    }

    try:
        resp = requests.post(url, headers=headers, json=body, timeout=30)
        if resp.status_code != 200:
            return None, {"error": f"LLM HTTP {resp.status_code}", "body": resp.text}
        
        data = resp.json()

        if "candidates" in data and data["candidates"]:
            candidate = data["candidates"][0]
            if "content" in candidate and "parts" in candidate["content"] and candidate["content"]["parts"]:
                txt = candidate["content"]["parts"][0].get("text")
                return txt, {"raw": data}
        
        # Fallback if the structure is unexpected
        return None, {"error": "Could not parse LLM response", "body": resp.text}

    except Exception as e:
        return None, {"error": str(e), "trace": traceback.format_exc()}


# Main chat endpoint (RAG + LLM, fallback)
@bp.route("/chat", methods=["POST"])
@token_required
def expense_chat_rag():
    """
    POST { "message": "...", "history": [...] }
    Returns JSON: { reply, raw_llm, context, sources }
    """
    # use flask.g (imported) here — don't assign to variable name 'g' anywhere inside this function
    user = g.current_user
    payload = request.get_json(silent=True) or {}
    message = (payload.get("message") or "").strip()
    if not message:
        return jsonify({"error": "message required"}), 400

    db = SessionLocal()
    try:
        # Build retrieval context
        context_text, sources = _build_rag_context_for_user(db, user.id, days_back=180, max_entries=40)

        # optional: incorporate conversation history (simple concatenation)
        history = payload.get("history")
        hist_text = ""
        if history and isinstance(history, list):
            hist_text = "\n".join([f"{m.get('role','user').upper()}: {m.get('text','')}" for m in history[-6:]])

        # Compose LLM prompt (same as before)
        instruction = (
            "You are a friendly personal finance assistant specialized in suggesting "
            "concrete, actionable ways for the user to save money. Use the provided user data (transactions, income, savings goals) "
            "to produce personalized advice. Include: 1) quick top-3 actions the user can take right away, "
            "2) one medium-term change (behavioral or budget reallocation), and 3) one long-term suggestion. "
            "When referring to numbers, show exact amounts when available. If the user asked a specific question, answer it directly using the data. "
            "Always be concise and provide an actionable bullet-list at the end. Mark which items came from the user's data and include short provenance like [source: expense id 123] where possible."
        )

        prompt_parts = [
            instruction,
            "\n--- Conversation history ---\n",
            hist_text,
            "\n--- User question ---\n",
            message,
            "\n--- Retrieval context: user's transactions, goals and summary ---\n",
            context_text,
            "\n--- End context ---\n",
            "Answer now:"
        ]
        full_prompt = "\n".join([p for p in prompt_parts if p is not None and p != ""])

        # Call Gemini if key present
        reply = None
        raw = None
        llm_meta = {}
        if os.environ.get("GOOGLE_API_KEY"):
            llm_txt, meta = _call_gemini_generate(full_prompt, max_tokens=400)
            if llm_txt:
                reply = llm_txt.strip()
                raw = meta.get("raw") or meta
                llm_meta = {"provider": "gemini", "meta": meta}
            else:
                llm_meta = {"provider": "gemini", "meta": meta}
                current_app.logger.warning("Gemini call failed: %s", meta)
        else:
            current_app.logger.info("GOOGLE_API_KEY not set — using rule-based fallback")

        # Fallback logic (rule-based) if no LLM reply
        if not reply:
            # Build a compact rule-based answer
            top_cats = sources.get("top_categories", [])
            suggestions = []
            if top_cats:
                top = top_cats[0]
                cat = top["category"]
                amt = top["total"]
                suggestions.append(f"Your largest recent spending category is '{cat}' at {amt:.2f}. Try reducing it by 15% next month to save {amt*0.15:.2f}.")
                suggestions.append("Set a weekly budget for this category and track for 4 weeks.")
            else:
                suggestions.append("No expense category data available to compute targeted reductions. Review your transactions to ensure categories are set.")
            goals_list = sources.get("goals", [])
            if goals_list:
                for gg in goals_list[:2]:
                    saved = gg.get("total_saved", 0.0)
                    targ = gg.get("target_amount", 0.0)
                    if targ > 0:
                        pct = (saved / targ) * 100.0
                        suggestions.append(f"Goal '{gg['name']}': {saved:.2f}/{targ:.2f} ({pct:.1f}%). Consider a micro-target increase if behind schedule.")
            else:
                suggestions.append("No savings goals found — consider creating a goal to direct your savings.")
            money = sources.get("money_in_hand", 0.0)
            cur = sources.get("monthly", [])[-1] if sources.get("monthly") else None
            if cur:
                suggestions.append(f"This month net flow: {cur.get('net_flow',0):.2f}. If negative, prioritize reducing variable expenses.")
            else:
                suggestions.append(f"Total balance across entries (simple): {money:.2f}")
            reply = "Here are some tailored suggestions:\n\n" + "\n".join([f"- {s}" for s in suggestions])
            raw = {"fallback": True, "suggestions": suggestions}
            llm_meta = {"provider": "fallback", "meta": {}}

        # Return reply with used context summary & sources for transparency
        return jsonify({
            "reply": reply,
            "raw_llm_meta": llm_meta,
            "context_preview": (context_text[:5000] + ("...[truncated]" if len(context_text) > 5000 else "")),
            "sources": sources
        })
    except Exception as e:
        current_app.logger.exception("expense_chat_rag failed: %s", e)
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        db.close()


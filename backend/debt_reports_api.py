import os
import io
import traceback
from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, send_from_directory, current_app, g
from sqlalchemy.orm import Session
from db import SessionLocal, engine, Base
from models import User, FinancialEntry
from auth import token_required
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from datetime import datetime, timezone


try:
    from debt_plans_api import DebtPlan
except Exception:
    DebtPlan = None

try:
    from debt_api import DebtAlert
except Exception:

    try:
        from models import DebtAlert as DebtAlertModel
        DebtAlert = DebtAlertModel
    except Exception:
        DebtAlert = None

bp = Blueprint('debt_reports', __name__, url_prefix='/api/debt/reports')

REPORT_DIR = os.path.join(os.path.dirname(__file__), 'reports')
os.makedirs(REPORT_DIR, exist_ok=True)

# Create DB table for report metadata (optional lightweight table)
from sqlalchemy import Column, Integer, String, DateTime, Float, Text, ForeignKey, Boolean
from sqlalchemy.orm import relationship
class DebtReport(Base):
    __tablename__ = "debt_reports"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(300), nullable=False)
    filename = Column(String(500), nullable=False)
    mime = Column(String(100), default='application/pdf')
    size = Column(Integer, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    # relationship
    user = relationship("User")
    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "name": self.name,
            "filename": self.filename,
            "mime": self.mime,
            "size": self.size,
            "created_at": self.created_at
        }

# ensure table exists
Base.metadata.create_all(bind=engine)


def _gather_user_debt_data(db: Session, user_id: int, start: str = None, end: str = None):
    """
    Returns dict with DataFrames/lists for:
      - debt_entries (entry_type == 'DEBT')
      - debt_payments (entry_type == 'EXPENSES' with category containing debt or loan)
      - plans (DebtPlan rows if available)
      - alerts (DebtAlert rows if available)
    """
    q = db.query(FinancialEntry).filter(FinancialEntry.user_id == user_id)

    if start:
        q = q.filter(FinancialEntry.entry_date >= start)
    if end:
        q = q.filter(FinancialEntry.entry_date <= end)

    all_entries = q.order_by(FinancialEntry.entry_date.asc()).all()

    debt_entries = [e for e in all_entries if (e.entry_type == 'DEBT')]
    debt_payments = [e for e in all_entries if (e.entry_type == 'EXPENSES' and (e.category or '').lower().find('debt') != -1 or (e.category or '').lower().find('loan') != -1)]

    plans = []
    if DebtPlan is not None:
        try:
            plans = db.query(DebtPlan).filter(DebtPlan.user_id == user_id).order_by(DebtPlan.created_at.desc()).all()
        except Exception:
            plans = []

    alerts = []
    if DebtAlert is not None:
        try:
            alerts = db.query(DebtAlert).filter(DebtAlert.user_id == user_id).order_by(DebtAlert.due_date.asc()).all()
        except Exception:
            alerts = []

    # Convert to pandas for easier charting
    def entries_to_df(entries):
        if not entries:
            return pd.DataFrame(columns=['date', 'amount', 'vendor', 'category', 'notes'])
        rows = []
        for e in entries:
            rows.append({
                'date': pd.to_datetime(e.entry_date).date() if getattr(e, 'entry_date', None) else None,
                'amount': float(e.amount or 0.0),
                'vendor': e.vendor,
                'category': e.category,
                'notes': e.notes,
            })
        return pd.DataFrame(rows)

    return {
        'debt_entries': debt_entries,
        'debt_payments': debt_payments,
        'plans': plans,
        'alerts': alerts,
        'df_debt_entries': entries_to_df(debt_entries),
        'df_debt_payments': entries_to_df(debt_payments),
    }


def _make_pie_chart(amounts_by_type: dict) -> bytes:
    """
    amounts_by_type: dict label->value
    returns PNG bytes
    """
    labels = list(amounts_by_type.keys())
    vals = [max(0.0, float(amounts_by_type.get(k, 0.0) or 0.0)) for k in labels]
    fig, ax = plt.subplots(figsize=(6, 4), dpi=100)
    if sum(vals) <= 0:
        ax.text(0.5, 0.5, "No data", horizontalalignment='center', verticalalignment='center')
    else:
        ax.pie(vals, labels=labels, autopct='%1.1f%%', startangle=140)
        ax.axis('equal')
    buf = io.BytesIO()
    fig.savefig(buf, format='png', bbox_inches='tight')
    plt.close(fig)
    buf.seek(0)
    return buf.read()


def _render_pdf(user: User, name: str, data: dict, out_path: str):
    """
    Create a PDF including:
      - header with user & date
      - stats
      - pie chart of debt vs payments vs plans
      - short tables
    """
    pdf = canvas.Canvas(out_path, pagesize=A4)
    w, h = A4
    margin = 18 * mm
    x = margin
    y = h - margin

    pdf.setFont("Helvetica-Bold", 16)
    pdf.drawString(x, y, f"Debt Report — {name}")
    pdf.setFont("Helvetica", 10)
    y -= 18
    pdf.drawString(x, y, f"User: {user.name or user.email}")
    y -= 16

    # Summary numbers
    df_debt = data['df_debt_entries']
    df_pay = data['df_debt_payments']
    total_debt = float(df_debt['amount'].sum()) if not df_debt.empty else 0.0
    total_payments = float(df_pay['amount'].sum()) if not df_pay.empty else 0.0
    plans = data['plans'] or []
    total_plans = 0.0
    for p in plans:
        try:
            total_plans += float(getattr(p, 'principal', 0.0) or 0.0)
        except Exception:
            pass
    

    y_section_start = y

    # Column 1: Draw Text on the Left
    text_y = y
    pdf.setFont("Helvetica-Bold", 12)
    text_y -= 6
    pdf.drawString(x, text_y, "Quick summary")
    pdf.setFont("Helvetica", 10)
    text_y -= 14
    pdf.drawString(x, text_y, f"Total debt recorded: {total_debt:.2f}")
    text_y -= 12
    pdf.drawString(x, text_y, f"Total payments to debt-like categories: {total_payments:.2f}")
    text_y -= 12
    pdf.drawString(x, text_y, f"Total outstanding (sum of Debt Plans): {total_plans:.2f}")

    # Column 2: Draw Chart on the Right
    chart_width = 70 * mm
    chart_height = 50 * mm
    chart_x = w - margin - chart_width  # Align to right margin
    chart_y = y_section_start - chart_height # Align top with top of this section

    amounts = {"Debt": total_debt, "Payments": total_payments, "Plans": total_plans}
    img_bytes = _make_pie_chart(amounts)
    img_reader = ImageReader(io.BytesIO(img_bytes))
    pdf.drawImage(img_reader, chart_x, chart_y, width=chart_width, height=chart_height, preserveAspectRatio=True, mask='auto')

    # Update main 'y' to be below the tallest element (the chart) plus some padding
    y = chart_y - 24
    # --- MODIFICATION END ---


    # small tables: top 8 debts and top 8 payments
    pdf.setFont("Helvetica-Bold", 12)
    pdf.drawString(x, y, "Recent debts (type=DEBT)")
    y -= 14
    pdf.setFont("Helvetica", 9)
    df_debt2 = df_debt.sort_values('date', ascending=False).head(8) if not df_debt.empty else pd.DataFrame()
    if df_debt2.empty:
        pdf.drawString(x, y, "No debt records.")
        y -= 14
    else:
        for _, r in df_debt2.iterrows():
            pdf.drawString(x, y, f"{str(r['date'])} • {r['vendor'] or '-'} • {r['category'] or '-'} • {r['amount']:.2f}")
            y -= 12
            if y < margin + 80:
                pdf.showPage()
                y = h - margin

    y -= 6
    pdf.setFont("Helvetica-Bold", 12)
    pdf.drawString(x, y, "Recent payments (EXPENSES with debt/loan category)")
    y -= 14
    pdf.setFont("Helvetica", 9)
    df_pay2 = df_pay.sort_values('date', ascending=False).head(8) if not df_pay.empty else pd.DataFrame()
    if df_pay2.empty:
        pdf.drawString(x, y, "No payments recorded.")
        y -= 14
    else:
        for _, r in df_pay2.iterrows():
            pdf.drawString(x, y, f"{str(r['date'])} • {r['vendor'] or '-'} • {r['category'] or '-'} • {r['amount']:.2f}")
            y -= 12
            if y < margin + 80:
                pdf.showPage()
                y = h - margin

    # include plans
    if plans:
        y -= 6
        pdf.setFont("Helvetica-Bold", 12)
        pdf.drawString(x, y, "Debt Plans")
        y -= 14
        pdf.setFont("Helvetica", 9)
        for p in plans:
            try:
                principal = float(getattr(p, 'principal', 0.0) or 0.0)
                rate = float(getattr(p, 'annual_interest_pct', 0.0) or 0.0)
                pdf.drawString(x, y, f"{getattr(p, 'name', 'Plan')} • {principal:.2f} • {rate:.2f}%")
                y -= 12
            except Exception:
                continue
            if y < margin + 60:
                pdf.showPage()
                y = h - margin

    # include upcoming alerts
    if data['alerts']:
        y -= 6
        pdf.setFont("Helvetica-Bold", 12)
        pdf.drawString(x, y, "Upcoming Alerts")
        y -= 14
        pdf.setFont("Helvetica", 9)
        for a in data['alerts'][:8]:
            due = getattr(a, 'due_date', None)
            due_str = due.isoformat() if due is not None else '—'
            pdf.drawString(x, y, f"{getattr(a,'title','-')} • Due: {due_str} • Amt: {getattr(a,'amount', '-')}")
            y -= 12
            if y < margin + 60:
                pdf.showPage()
                y = h - margin

    pdf.save()


@bp.route("", methods=["GET"])
@token_required
def list_reports():
    user = g.current_user
    db = SessionLocal()
    try:
        items = db.query(DebtReport).filter(DebtReport.user_id == user.id).order_by(DebtReport.created_at.desc()).all()
        return jsonify({"items": [i.to_dict() for i in items]})
    finally:
        db.close()


@bp.route("", methods=["POST"])
@token_required
def create_report():
    """
    Generate a debt report PDF for current user.
    Accepts optional JSON:
      { "name": "Monthly debt snapshot Aug 2025", "start": "2025-01-01", "end": "2025-08-31", "include_plans": true, "include_alerts": true }
    Response: the created metadata object (201)
    """
    user = g.current_user
    payload = request.get_json(silent=True) or {}
    name = (payload.get("name") or f"Debt report {datetime.utcnow().date().isoformat()}")[:250]
    start = payload.get("start")
    end = payload.get("end")

    db = SessionLocal()
    try:
        data = _gather_user_debt_data(db, user.id, start=start, end=end)
        filename = f"debt_report_user{user.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}.pdf"
        out_path = os.path.join(REPORT_DIR, filename)
        _render_pdf(user, name, data, out_path)

        # store metadata
        size = os.path.getsize(out_path)
        r = DebtReport(user_id=user.id, name=name, filename=filename, size=size)
        db.add(r)
        db.commit()
        db.refresh(r)
        return jsonify(r.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("Debt report generation failed: %s", e)
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        db.close()


@bp.route("/<int:report_id>/download", methods=["GET"])
@token_required
def download_report(report_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        r = db.get(DebtReport, report_id)
        if not r or r.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        # send file
        return send_from_directory(REPORT_DIR, r.filename, as_attachment=True, download_name=r.filename, mimetype=r.mime)
    finally:
        db.close()


@bp.route("/<int:report_id>", methods=["DELETE"])
@token_required
def delete_report(report_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        r = db.get(DebtReport, report_id)
        if not r or r.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        # remove file if exists
        try:
            path = os.path.join(REPORT_DIR, r.filename)
            if os.path.exists(path):
                os.remove(path)
        except Exception:
            pass
        db.delete(r)
        db.commit()
        return jsonify({"status": "deleted"})
    finally:
        db.close()

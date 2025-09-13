from dotenv import load_dotenv
import os
import json
import math
import traceback
import requests
from datetime import datetime, timedelta
from flask import Blueprint, request, jsonify, current_app, g
from sqlalchemy import func, or_, case, Column, Integer, String, Float, DateTime, ForeignKey, Text, Boolean
from sqlalchemy.orm import relationship
from db import SessionLocal, Base, engine
from models import FinancialEntry, DebtPlan, DebtAlert, DebtBadge, DebtChatMessage, User
from auth import token_required
from apscheduler.schedulers.background import BackgroundScheduler



debt_bp = Blueprint("debt", __name__, url_prefix="/api/debt")

load_dotenv()

# Basic vendor keywords map
COMMON_LENDERS = [
    "bank", "loan", "finance", "credit", "mortgage", "leasing", "Lanka", "HNB", "SAMP", "JKH", "LOLC"
]


# ---------- Helpers ----------
def _identify_debt_entries_for_user(db, user_id):
    """
    Heuristics to find debt-related entries:
    - entry_type == 'DEBT'
    - OR (entry_type == 'EXPENSES' AND category contains 'debt' or 'loan')
    - OR vendor contains common lender keywords
    returns list of FinancialEntry ORM objects
    """
    q = db.query(FinancialEntry).filter(FinancialEntry.user_id == user_id)
    conds = []
    # entry_type == 'DEBT'
    conds.append(FinancialEntry.entry_type == 'DEBT')
    # expenses category like 'debt' or 'loan'
    conds.append(func.lower(FinancialEntry.category).like('%debt%'))
    conds.append(func.lower(FinancialEntry.category).like('%loan%'))
    # vendor contains lender keywords
    vendor_conds = []
    for kw in COMMON_LENDERS:
        vendor_conds.append(func.lower(FinancialEntry.vendor).like(f"%{kw.lower()}%"))
    # Combined filter: either entry_type DEBT or category matches or vendor matches
    q = q.filter(or_(
        FinancialEntry.entry_type == 'DEBT',
        func.lower(FinancialEntry.category).like('%debt%'),
        func.lower(FinancialEntry.category).like('%loan%'),
        *vendor_conds
    ))
    # Return list
    return q.order_by(FinancialEntry.entry_date.desc()).all()


def _aggregate_debt_by_vendor(entries):
    """
    Aggregate a list of entries into debt accounts per vendor.
    Logic:
      - treat entries where entry_type == 'DEBT' as borrowing (increase principal)
      - treat entries where entry_type == 'EXPENSES' and category like 'debt' as payments (decrease principal)
    """
    accounts = {}
    for e in entries:
        vendor = (e.vendor or "Unknown").strip()
        if vendor == "":
            vendor = "Unknown"
        rec = accounts.setdefault(vendor, {"vendor": vendor, "borrowed": 0.0, "paid": 0.0, "entries": []})
        amount = float(e.amount or 0.0)
        rec["entries"].append({
            "id": e.id,
            "entry_type": e.entry_type,
            "category": e.category,
            "amount": amount,
            "entry_date": e.entry_date.isoformat() if e.entry_date else None,
            "notes": e.notes,
            "reference": e.reference
        })
        if (e.entry_type or "").upper() == "DEBT":
            # assume positive amount = borrowed
            rec["borrowed"] += amount
        else:
            # consider as payment
            rec["paid"] += amount
    # compute outstanding
    for v, rec in accounts.items():
        rec["outstanding"] = round(rec["borrowed"] - rec["paid"], 2)
    return list(accounts.values())


def _calculate_money_in_hand_for_user(db, user_id):
    """
    A simple 'money in hand' heuristic: sum INCOME this month - sum EXPENSES/SAVINGS/INVESTMENTS/DEBT this month.
    Uses SQLAlchemy.case(...) with positional when-tuples to be compatible with modern SQLAlchemy.
    """
    now = datetime.utcnow()
    month_str = now.strftime("%Y-%m")

    # case() expects positional when-tuples like (cond, result), not a list
    income_case = case((FinancialEntry.entry_type == 'INCOME', FinancialEntry.amount), else_=0.0)
    out_case = case((FinancialEntry.entry_type.in_(['EXPENSES', 'SAVINGS', 'INVESTMENTS', 'DEBT']), FinancialEntry.amount), else_=0.0)

    q = db.query(
        func.coalesce(func.sum(income_case), 0).label('sum_income'),
        func.coalesce(func.sum(out_case), 0).label('sum_out')
    ).filter(
        FinancialEntry.user_id == user_id,
        func.strftime('%Y-%m', FinancialEntry.entry_date) == month_str
    )

    row = q.first()
    income = float(row.sum_income or 0.0)
    out = float(row.sum_out or 0.0)
    return income - out


# ---------- Endpoints ----------

@debt_bp.route("/summary", methods=["GET"])
@token_required
def debt_summary():
    """Return aggregate debt summary for the current user."""
    user = g.current_user
    db = SessionLocal()
    try:
        entries = _identify_debt_entries_for_user(db, user.id)
        accounts = _aggregate_debt_by_vendor(entries)
        total_borrowed = sum([a["borrowed"] for a in accounts])
        total_paid = sum([a["paid"] for a in accounts])
        total_outstanding = sum([a["outstanding"] for a in accounts])
        money_in_hand = _calculate_money_in_hand_for_user(db, user.id)
        # suggest badges
        badges = []
        # example badge logic
        if total_outstanding <= 0:
            badges.append({"badge_key": "debt_free", "title": "Debt-free", "description": "No outstanding debts — great job!"})
        elif total_outstanding < 10000:
            badges.append({"badge_key": "low_debt", "title": "Low debt", "description": "Your outstanding debt is low."})
        # list user's earned badges
        earned = db.query(DebtBadge).filter(DebtBadge.user_id == user.id).all()
        earned_list = [b.to_dict() for b in earned]
        return jsonify({
            "accounts": accounts,
            "total_borrowed": round(total_borrowed, 2),
            "total_paid": round(total_paid, 2),
            "total_outstanding": round(total_outstanding, 2),
            "money_in_hand": round(money_in_hand, 2),
            "suggested_badges": badges,
            "earned_badges": earned_list,
        })
    finally:
        db.close()



# payoff calculator helper (amortization w/ interest if provided)
def _estimate_payoff(principal: float, monthly_payment: float, interest_rate_pct: float = None, extra: float = 0.0):
    """
    Returns (months_needed, payoff_date, schedule[]), schedule includes monthly progress items.
    If interest_rate_pct is None: simple divide approach.
    """
    sched = []
    if principal <= 0:
        return 0, datetime.utcnow().date(), sched
    if interest_rate_pct:
        r = float(interest_rate_pct) / 100.0 / 12.0
        balance = principal
        month = 0
        mp = monthly_payment + extra
        while balance > 0 and month < 1000:
            month += 1
            interest = balance * r
            principal_paid = mp - interest
            if principal_paid <= 0:
                # payment not covering interest -> can't payoff
                return None, None, []
            balance = max(0.0, balance - principal_paid)
            sched.append({"month": month, "interest": round(interest, 4), "principal_paid": round(principal_paid, 4), "balance": round(balance, 4)})
        payoff_date = (datetime.utcnow().date() + timedelta(days=month * 30))
        return month, payoff_date.isoformat(), sched
    else:
        mp = monthly_payment + extra
        if mp <= 0:
            return None, None, []
        months = math.ceil(principal / mp)
        payoff_date = (datetime.utcnow().date() + timedelta(days=months * 30))
        # create simple schedule
        balance = principal
        for m in range(1, months + 1):
            pay = mp if m < months else balance
            balance = max(0.0, balance - pay)
            sched.append({"month": m, "payment": round(pay, 4), "balance": round(balance, 4)})
        return months, payoff_date.isoformat(), sched


# Alerts endpoints
@debt_bp.route("/alerts", methods=["GET"])
@token_required
def list_alerts():
    """List alerts for current user (optionally filter by upcoming/acknowledged)."""
    user = g.current_user
    db = SessionLocal()
    try:
        q = db.query(DebtAlert).filter(DebtAlert.user_id == user.id)
        show = request.args.get("show")  # 'upcoming', 'all', 'acknowledged', 'unack'
        if show == "upcoming":
            now = datetime.utcnow()
            q = q.filter(DebtAlert.due_date != None, DebtAlert.due_date >= now)
        elif show == "unack":
            q = q.filter(DebtAlert.acknowledged == False)
        elif show == "ack":
            q = q.filter(DebtAlert.acknowledged == True)
        items = [r.to_dict() for r in q.order_by(DebtAlert.due_date.asc().nulls_last(), DebtAlert.priority.desc(), DebtAlert.created_at.desc()).all()]
        return jsonify({"items": items})
    finally:
        db.close()


@debt_bp.route("/alerts", methods=["POST"])
@token_required
def create_alert():
    """
    Create an alert. Body accepts:
    { title, message, due_date (ISO), amount, vendor, recurrence ('none'|'daily'|'weekly'|'monthly'), priority }
    This implementation:
      - logs incoming payload for debugging
      - tries several ISO parsing strategies (accepts ' ', 'T', 'Z', with/without fractional seconds)
      - returns a SINGLE JSON object on success with HTTP 201
    """
    user = g.current_user
    data = request.get_json(silent=True) or {}
    current_app.logger.debug("create_alert payload: %s", data)

    title = (data.get("title") or "").strip()
    if not title:
        return jsonify({"error": "title required"}), 400

    message = data.get("message")
    due_date = None
    raw_due = data.get("due_date")
    if raw_due:
        s = str(raw_due).strip()
        # normalize common variants:
        # - replace trailing 'Z' with +00:00 so fromisoformat accepts it
        # - if space used between date/time and 'T' missing, insert T
        try:
            if s.endswith("Z"):
                s = s.replace("Z", "+00:00")
            if " " in s and "T" not in s:
                s = s.replace(" ", "T")
            # try direct fromisoformat
            due_date = datetime.fromisoformat(s)
        except Exception as e1:
            # try removing fractional seconds
            try:
                s2 = s.split(".")[0]
                if s2.endswith("+00:00"):
                    # ensure timezone kept if present
                    due_date = datetime.fromisoformat(s2)
                else:
                    # final fallback: parse naive date/time without timezone
                    due_date = datetime.fromisoformat(s2)
            except Exception as e2:
                current_app.logger.debug("due_date parse failed: %s / %s", e1, e2)
                return jsonify({"error": "due_date must be ISO format (e.g. 2025-08-30T10:00:00 or 2025-08-30 10:00)"}), 400

    amount = data.get("amount")
    vendor = data.get("vendor")
    recurrence = (data.get("recurrence") or "none").lower()
    priority = (data.get("priority") or "normal").lower()

    db = SessionLocal()
    try:
        a = DebtAlert(
            user_id=user.id,
            title=title,
            message=message,
            due_date=due_date,
            amount=float(amount) if amount is not None else None,
            vendor=vendor,
            recurrence=recurrence if recurrence in ("none", "daily", "weekly", "monthly") else None,
            priority=priority,
        )
        db.add(a)
        db.commit()
        db.refresh(a)
        # return single object + 201
        return jsonify(a.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("create_alert failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@debt_bp.route("/alerts/<int:alert_id>", methods=["PUT"])
@token_required
def update_alert(alert_id: int):
    user = g.current_user
    data = request.get_json() or {}
    db = SessionLocal()
    try:
        a = db.get(DebtAlert, alert_id)
        if not a or a.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        # update fields
        for field in ("title", "message", "amount", "vendor", "recurrence", "priority", "acknowledged"):
            if field in data:
                setattr(a, field, data[field])
        if "due_date" in data and data["due_date"]:
            try:
                a.due_date = datetime.fromisoformat(data["due_date"])
            except Exception:
                return jsonify({"error": "due_date invalid"}), 400
        db.add(a)
        db.commit()
        db.refresh(a)
        return jsonify(a.to_dict())
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@debt_bp.route("/alerts/<int:alert_id>/ack", methods=["POST"])
@token_required
def ack_alert(alert_id: int):
    """Acknowledge alert (user did action) - cancels further notifications for non-recurring alerts."""
    user = g.current_user
    db = SessionLocal()
    try:
        a = db.get(DebtAlert, alert_id)
        if not a or a.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        a.acknowledged = True
        db.add(a)
        db.commit()
        return jsonify(a.to_dict())
    finally:
        db.close()


# Endpoint to return alerts due in a window (for clients or server push)
@debt_bp.route("/alerts/pending", methods=["GET"])
@token_required
def list_pending_alerts():
    """
    Query param: minutes= how far ahead (default 10)
    Returns alerts whose due_date is <= now + minutes and last_notified_at is null or older than recurrence window.
    """
    user = g.current_user
    minutes = int(request.args.get("minutes") or 10)
    now = datetime.utcnow()
    window_end = now + timedelta(minutes=minutes)
    db = SessionLocal()
    try:
        q = db.query(DebtAlert).filter(
            DebtAlert.user_id == user.id,
            DebtAlert.acknowledged == False,
            DebtAlert.due_date != None,
            DebtAlert.due_date <= window_end
        )

        results = []
        for a in q.all():
            # check last_notified_at and recurrence rules to avoid duplicate notifications
            if a.last_notified_at:
                # if recurrence none and already notified -> skip
                if not a.recurrence or a.recurrence == "none":
                    continue
                # if recurrence daily and last_notified_at was today -> skip
                if a.recurrence == "daily" and a.last_notified_at.date() == now.date():
                    continue
                # weekly: skip if within 7 days
                if a.recurrence == "weekly" and (now - a.last_notified_at).days < 7:
                    continue
                # monthly: skip if same month
                if a.recurrence == "monthly" and a.last_notified_at.month == now.month and a.last_notified_at.year == now.year:
                    continue

            results.append(a.to_dict())

        return jsonify({"items": results})
    finally:
        db.close()


# ----------------------------
# Chatbot + RAG-style scaffold
# ----------------------------
# This implements:
# - retrieval: gather top-N debt-related entries and plans for the user and build a context
# - generation: by default uses a rule-based template to answer queries; if OPENAI_API_KEY
#   is set it will attempt to call OpenAI completions (simple POST to v1/completions or chat completions)
# optional; if set, will attempt better answers
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY")


def _build_retrieval_context(db, user_id, top_n=8):
    """
    Gather user's debt entries, plans, alerts and form a textual context for RAG.
    """
    entries = _identify_debt_entries_for_user(db, user_id)[:top_n]
    plans = db.query(DebtPlan).filter(DebtPlan.user_id == user_id).limit(top_n).all()
    alerts = db.query(DebtAlert).filter(DebtAlert.user_id == user_id).limit(top_n).all()
    parts = []
    parts.append(f"User ID: {user_id}")
    for e in entries:
        parts.append(f"ENTRY | date={e.entry_date} | type={e.entry_type} | cat={e.category} | vendor={e.vendor} | amount={e.amount} | currency={e.currency} | notes={e.notes or ''}")
    for p in plans:
        parts.append(f"PLAN | name={p.name} | vendor={p.vendor} | principal={p.principal} | annual_interest_pct={p.annual_interest_pct} | minimum_payment={p.minimum_payment or 0.0} | target_payment={p.target_payment or 0.0} | start_date={p.start_date} | notes={p.notes} | active={p.active}")
    for a in alerts:
        parts.append(f"ALERT | title={a.title} | message={a.message} | due_date={a.due_date} | amount={a.amount} | vendor={a.vendor} | recurrence={a.recurrence} | acknowledged={a.acknowledged} | last_notified_at={a.last_notified_at} | created_at={a.created_at}")
    context = "\n".join(parts)
    return context


def _call_gemini(prompt: str, max_tokens=1000):
    """
    Minimal Google Gemini API call.
    """
    key = GOOGLE_API_KEY
    if not key:
        return None

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key={key}"
    
    headers = {"Content-Type": "application/json"}

    body = {
        "contents": [
            {
                "parts": [
                    {"text": f"You are a helpful financial assistant. Use the given data to answer the user's questions about debts and payments.\n\n{prompt}"}
                ]
            }
        ],
        "generationConfig": {
            "temperature": 0.2,
            "maxOutputTokens": max_tokens
        }
    }

    try:
        r = requests.post(url, headers=headers, json=body, timeout=30)

        if r.status_code != 200:
            logger.warning("Gemini API call failed: %s %s", r.status_code, r.text)
            return None
            
        data = r.json()
        
        # Extract the text from the 'candidates' part of the response.
        msg = None
        if "candidates" in data and len(data["candidates"]) > 0:
            # Check if 'parts' exist and are not empty
            content = data["candidates"][0].get("content", {})
            parts = content.get("parts", [])
            if parts:
                 msg = parts[0].get("text")

        return msg

    except Exception as e:
        logger.exception("Gemini API call error: %s", e)
        return None


@debt_bp.route("/chat", methods=["POST"])
@token_required
def debt_chat():
    """
    Body: { "message": "How much do I owe to bank X? What should I do?" }
    Returns: { "reply": "...", "context": "...", "raw_llm": null or text }
    """
    user = g.current_user
    data = request.get_json() or {}
    message = (data.get("message") or "").strip()
    if not message:
        return jsonify({"error": "message required"}), 400

    db = SessionLocal()
    try:
        # build context
        context = _build_retrieval_context(db, user.id, top_n=12)
        # store user message
        cm = DebtChatMessage(user_id=user.id, role="user", content=message)
        db.add(cm); db.commit()

        # try LLM if key available
        llm_reply = None
        if GOOGLE_API_KEY:
            prompt = f"User question: {message}\n\nContext:\n{context}\n\nAnswer concisely and give actionable steps and an estimate if possible."
            llm_reply = _call_gemini(prompt)
            
            print(llm_reply)
            if llm_reply:
                # store assistant message
                am = DebtChatMessage(user_id=user.id, role="assistant", content=llm_reply)
                db.add(am); db.commit()
                return jsonify({"reply": llm_reply, "context": context, "raw_llm": True})

        # fallback rule-based answer using context: basic extraction
        # extract totals
        entries = _identify_debt_entries_for_user(db, user.id)
        agg = _aggregate_debt_by_vendor(entries)
        total_outstanding = sum([a["outstanding"] for a in agg])
        total_borrowed = sum([a["borrowed"] for a in agg])
        total_paid = sum([a["paid"] for a in agg])
        money_in_hand = _calculate_money_in_hand_for_user(db, user.id)

        # naive patterns
        msg_low = message.lower()
        reply = "I looked at your debts and here's a short summary:\n\n"
        reply += f"- Total borrowed (detected): {round(total_borrowed,2)}\n- Total paid (detected): {round(total_paid,2)}\n- Estimated outstanding: {round(total_outstanding,2)}\n"
        reply += f"\nYour current month money-in-hand estimate: {round(money_in_hand,2)}\n\n"

        # quick actionable suggestions
        reply += "Suggestions:\n"
        if total_outstanding <= 0:
            reply += "- You have no outstanding debts detected. Keep up the good work!\n"
        else:
            reply += "- Prioritize high-interest debts (create plans to pay extra when possible).\n"
            if money_in_hand > 0 and money_in_hand < total_outstanding:
                reply += f"- You have {round(money_in_hand,2)} available this month — consider applying a portion to the smallest outstanding debt to gain momentum.\n"
            reply += "- Consider creating a Debt Payment Plan with planned monthly payments to visualize payoff dates (I can create one if you give principal & monthly payment).\n"

        # try to satisfy specific question forms
        if "how long" in msg_low or "payoff" in msg_low or "when" in msg_low:
            # if user mentions vendor name, try to give vendor-specific estimate
            matched = None
            for acc in agg:
                if acc["vendor"].lower() in msg_low:
                    matched = acc
                    break
            if matched:
                # default simple estimate: divide outstanding by money_in_hand or some safe monthly payment
                sample_monthly = max(100, money_in_hand * 0.5) if money_in_hand > 0 else 100
                months = math.ceil(max(1, matched["outstanding"]) / sample_monthly)
                reply += f"\nEstimate: If you pay {sample_monthly:.2f} per month towards {matched['vendor']}, you will clear it in about {months} months.\n"
            else:
                # generic
                sample_monthly = max(100, money_in_hand * 0.5) if money_in_hand > 0 else 100
                months = math.ceil(max(1, total_outstanding) / sample_monthly)
                reply += f"\nGeneric estimate: With approx {sample_monthly:.2f} per month, you could clear all debts in about {months} months.\n"

        # store assistant message (fallback)
        am = DebtChatMessage(user_id=user.id, role="assistant", content=reply)
        db.add(am); db.commit()
        return jsonify({"reply": reply, "context": context, "raw_llm": False})
    except Exception as e:
        current_app.logger.exception("debt_chat failed: %s", e)
        return jsonify({"error": str(e), "trace": traceback.format_exc()}), 500
    finally:
        db.close()
        

# --------------------
# Scheduler: mark due alerts as notified periodically
# --------------------
def _mark_alert_notified(db_session, alert_id):
    a = db_session.get(DebtAlert, alert_id)
    if not a:
        return
    a.last_notified_at = datetime.utcnow()
    db_session.add(a)
    db_session.commit()


def _scan_and_mark_due_alerts():
    """
    Runs periodically (every minute) and marks alerts whose due_date <= now.
    This doesn't send push itself, but marks last_notified_at so push workers or clients can act.
    """
    try:
        db = SessionLocal()
        now = datetime.utcnow()
        # select alerts due in the past minute that are not acknowledged and haven't been notified recently
        q = db.query(DebtAlert).filter(
            DebtAlert.acknowledged == False,
            DebtAlert.due_date != None,
            DebtAlert.due_date <= now
        )
        for a in q.all():
            # skip if already notified and not time for recurrence
            if a.last_notified_at:
                # handle recurrence windows
                if not a.recurrence or a.recurrence == "none":
                    continue
                if a.recurrence == "daily" and a.last_notified_at.date() == now.date():
                    continue
                if a.recurrence == "weekly" and (now - a.last_notified_at).days < 7:
                    continue
                if a.recurrence == "monthly" and a.last_notified_at.month == now.month and a.last_notified_at.year == now.year:
                    continue
            # mark notified
            a.last_notified_at = now
            db.add(a)
            # optionally log / push via FCM here
            current_app.logger.info("Marked alert %s as notified for user %s", a.id, a.user_id)
        db.commit()
    except Exception as e:
        current_app.logger.exception("scan_and_mark_due_alerts failed: %s", e)
    finally:
        try:
            db.close()
        except Exception:
            pass


# Simple "tips" endpoint - rule based suggestions
@debt_bp.route("/tips", methods=["GET"])
@token_required
def debt_tips():
    user = g.current_user
    db = SessionLocal()
    try:
        entries = _identify_debt_entries_for_user(db, user.id)
        agg = _aggregate_debt_by_vendor(entries)
        tips = []
        if not agg:
            tips.append("We did not detect debts — good. Maintain emergency savings and avoid high-interest credit.")
        else:
            tips.append("List all debts and aim for the smallest-balance-first (snowball) or highest-interest-first (avalanche).")
            total_outstanding = sum([a["outstanding"] for a in agg])
            if total_outstanding > 50000:
                tips.append("Your outstanding debt is significant — consider negotiating lower rates or consolidating high-interest debts.")
            tips.append("Set up automatic reminders before due dates. Make more than the minimum payment when possible.")
        return jsonify({"tips": tips})
    finally:
        db.close()


# Start APScheduler in module-level so app can import it and it will run in background
scheduler = BackgroundScheduler()
scheduler.add_job(_scan_and_mark_due_alerts, "interval", seconds=60, id="debt_alert_scan", replace_existing=True)
scheduler.start()

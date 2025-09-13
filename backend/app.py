import os
from datetime import datetime, date

from flask import Flask, request, jsonify, g, send_from_directory
from flask_cors import CORS
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
import pandas as pd
from apscheduler.schedulers.background import BackgroundScheduler

from db import engine, Base, SessionLocal
from ocr import extract_text
from parser import parse_ocr_text
from categorizer import guess_type_detailed

from predictor import predict_user_money_in_hand, schedule_retrain_user, retrain_user_model, get_monthly_net_flow_df
from models import User, FinancialEntry, CommunityPost, CommunityComment, CommunityVote, InvestmentPlan, NewsArticle, NewsBookmark, DebtAlert, DebtBadge, DebtPlan
from auth import create_token_for_user, token_required

from community_api import bp as community_bp
from invest_suggestion import invest_suggestion_bp
from commodity_forecast import commodity_bp
from news_rss import news_bp
from stock_forecast import stock_bp

from debt_api import debt_bp, _scan_and_mark_due_alerts
from cost_savings_api import bp as cost_savings_bp
from credit_api import credit_bp
from debt_plans_api import bp as debt_plans_bp
from debt_reports_api import bp as debt_reports_bp

# Config
UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "uploads")
ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "tiff", "bmp", "gif"}

os.makedirs(UPLOAD_DIR, exist_ok=True)

# Flask app
app = Flask(__name__)
CORS(app, supports_credentials=True)

app.register_blueprint(community_bp)
app.register_blueprint(invest_suggestion_bp)
app.register_blueprint(commodity_bp)
app.register_blueprint(news_bp)
app.register_blueprint(stock_bp)
app.register_blueprint(debt_bp)
app.register_blueprint(cost_savings_bp)
app.register_blueprint(credit_bp)
app.register_blueprint(debt_plans_bp)
app.register_blueprint(debt_reports_bp)


# Create DB tables
Base.metadata.create_all(bind=engine)


def run_alert_scan():
    with app.app_context():
        _scan_and_mark_due_alerts()

scheduler = BackgroundScheduler()
scheduler.add_job(
    run_alert_scan,
    'interval',
    seconds=6000,
    id='debt_alert_scan',
    replace_existing=True
)
scheduler.start()

# Helpers
def allowed_file(filename: str) -> bool:
    if not filename:
        return False
    ext = filename.rsplit(".", 1)[-1].lower()
    return ext in ALLOWED_EXTENSIONS


def entry_to_dict(entry: FinancialEntry) -> dict:
    return {
        "id": entry.id,
        "entry_type": entry.entry_type,
        "category": entry.category,
        "amount": entry.amount,
        "currency": entry.currency,
        "vendor": entry.vendor,
        "reference": entry.reference,
        "notes": entry.notes,
        "entry_date": entry.entry_date.isoformat() if entry.entry_date else None,
        "created_at": entry.created_at.isoformat() if entry.created_at else None,
        "updated_at": entry.updated_at.isoformat() if entry.updated_at else None,
        "source": entry.source,
        "raw_text": entry.raw_text,
    }


# Routes

@app.get("/api/health")
def health():
    return jsonify({"status": "ok"})


@app.get("/api/categories")
def categories():
    return jsonify({
        "entry_types": ["INCOME", "SAVINGS", "EXPENSES", "INVESTMENTS", "DEBT"],
        "suggested_categories": [
            "Groceries", "Transport", "Utilities", "Rent", "Dining", "Medical",
            "Education", "Entertainment", "Salary", "Interest", "Stocks", "Loans",
        ]
    })


# --------- AUTH ----------
@app.post("/api/auth/register")
def auth_register():
    data = request.get_json() or {}
    email = (data.get("email") or "").strip().lower()
    password = data.get("password")
    name = data.get("name")
    if not email or not password:
        return jsonify({"error": "email and password required"}), 400

    db = SessionLocal()
    try:
        existing = db.query(User).filter(User.email == email).first()
        if existing:
            return jsonify({"error": "Email already registered"}), 400
        hashed = generate_password_hash(password)
        user = User(email=email, name=name, password_hash=hashed)
        db.add(user)
        db.commit()
        db.refresh(user)
        token = create_token_for_user(user.id)
        return jsonify({"token": token, "user": {"id": user.id, "email": user.email, "name": user.name}}), 201
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@app.post("/api/auth/login")
def auth_login():
    data = request.get_json() or {}
    email = (data.get("email") or "").strip().lower()
    password = data.get("password")
    if not email or not password:
        return jsonify({"error": "email and password required"}), 400

    db = SessionLocal()
    try:
        user = db.query(User).filter(User.email == email).first()
        if not user or not check_password_hash(user.password_hash, password):
            return jsonify({"error": "Invalid credentials"}), 401
        token = create_token_for_user(user.id)
        return jsonify({"token": token, "user": {"id": user.id, "email": user.email, "name": user.name}})
    finally:
        db.close()
        
        
@app.post("/api/auth/update-profile")
@token_required
def update_profile():

    user = g.current_user
    data = request.get_json() or {}
    new_name = data.get("name")
    old_pwd = data.get("old_password")
    new_pwd = data.get("new_password")

    if new_pwd and not old_pwd:
        return jsonify({"error": "old_password is required to change password"}), 400

    db = SessionLocal()
    try:
        db_user = db.get(User, user.id)
        if not db_user:
            return jsonify({"error": "User not found"}), 404

        if new_name is not None:
            db_user.name = str(new_name).strip() or None

        if new_pwd:
            # verify current
            if not check_password_hash(db_user.password_hash, old_pwd):
                return jsonify({"error": "Current password is incorrect"}), 401
            db_user.password_hash = generate_password_hash(new_pwd)

        db.add(db_user)
        db.commit()
        db.refresh(db_user)

        return jsonify({"status": "ok", "user": {"id": db_user.id, "email": db_user.email, "name": db_user.name}})
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@app.get("/api/auth/me")
@token_required
def auth_me():
    user = g.current_user
    return jsonify({"id": user.id, "email": user.email, "name": user.name})
    

@app.get("/api/predict/monthly_series/<int:user_id>")
@token_required
def api_predict_monthly_series(user_id: int):
    # ensure user only requests their own data (unless you allow admin)
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error": "Forbidden"}), 403

    try:
        df = get_monthly_net_flow_df(user_id)  # returns pandas df with columns ds,y
        app.logger.debug("monthly_series df head: %s", getattr(df, "head", lambda: df)())

        # If df is empty, return empty series quickly
        if df is None or df.empty:
            return jsonify({"series": []})

        # Ensure 'ds' column is datetime dtype
        if "ds" not in df.columns:
            # defensive fallback: try to create from index or month column
            if "month" in df.columns:
                df["ds"] = pd.to_datetime(df["month"].astype(str) + "-01", errors="coerce")
            else:
                # nothing we can do reliably
                df["ds"] = pd.to_datetime(df.index, errors="coerce")

        # Convert to datetime, coerce errors to NaT
        df["ds"] = pd.to_datetime(df["ds"], errors="coerce")

        # Drop rows where ds is NaT (or handle them with a default)
        df = df[df["ds"].notna()].copy()
        if df.empty:
            return jsonify({"series": []})

        # Format dates as YYYY-MM-DD reliably
        df["ds_str"] = df["ds"].dt.strftime("%Y-%m-%d")

        # Ensure y exists and is numeric; fill NaN with 0.0
        if "y" not in df.columns:
            # try to compute 'y' if you have net_flow column
            if "net_flow" in df.columns:
                df["y"] = pd.to_numeric(df["net_flow"], errors="coerce").fillna(0.0)
            else:
                df["y"] = 0.0
        else:
            df["y"] = pd.to_numeric(df["y"], errors="coerce").fillna(0.0)

        # Build JSON list
        rows = [{"ds": ds, "y": float(y)} for ds, y in zip(df["ds_str"].tolist(), df["y"].tolist())]

        return jsonify({"series": rows})
    except Exception as exc:
        tb = traceback.format_exc()
        app.logger.exception("monthly_series failed for user %s: %s", user_id, exc)
        # return traceback for debugging (remove/strip in production)
        return jsonify({"error": str(exc), "trace": tb}), 500


# GET /api/predict/money_in_hand/<user_id>
@app.get("/api/predict/money_in_hand/<int:user_id>")
@token_required
def api_predict_money_in_hand(user_id: int):
    # only allow users to predict their own data unless you're admin
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error": "Forbidden"}), 403
    res = predict_user_money_in_hand(user_id)
    if "error" in res:
        return jsonify({"error": res["error"]}), 500
    return jsonify(res)


# POST /api/predict/retrain/<user_id>  (manually trigger retrain for a single user)
@app.post("/api/predict/retrain/<int:user_id>")
@token_required
def api_retrain_user(user_id: int):
    if getattr(g, "current_user", None) and g.current_user.id != user_id:
        return jsonify({"error": "Forbidden"}), 403

    # Query param ?mode=sync to force synchronous retrain for testing
    mode = request.args.get("mode", "scheduled")
    try:
        if mode == "sync":
            result = retrain_user_model_sync(user_id)
            return jsonify({"status": "done", "result": result})
        else:
            job_id = schedule_retrain_user(user_id)
            return jsonify({"status": "scheduled", "job_id": job_id})
    except Exception as e:
        return jsonify({"error": str(e)}), 500



# --------- OCR upload endpoint (returns parsed draft) ----------
@app.post("/api/ocr/upload")
@token_required
def ocr_upload():
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    f = request.files["file"]
    filename = secure_filename(f.filename or "upload.jpg")
    if not allowed_file(filename):
        return jsonify({"error": "File type not allowed"}), 400

    save_path = os.path.join(UPLOAD_DIR, f"{datetime.utcnow().strftime('%Y%m%d%H%M%S%f')}_{filename}")
    try:
        f.save(save_path)
    except Exception as e:
        return jsonify({"error": f"Failed to save file: {e}"}), 500

    try:
        raw_text = extract_text(save_path)
        parsed = parse_ocr_text(raw_text)
        parsed["source"] = "ocr"
        d = guess_type_detailed(parsed.get("vendor"), parsed.get("raw_text"), parsed.get("amount"))
        # attach suggestion info
        parsed["suggested_type"] = d["type"]
        parsed["suggested_confidence"] = d["confidence"]
        parsed["suggested_reasons"] = d["reasons"]
        return jsonify(parsed)
    except Exception as e:
        return jsonify({"error": f"OCR processing failed: {e}"}), 500


# --------- Entries (user-scoped) ----------
@app.get("/api/entries")
@token_required
def list_entries():
    user = g.current_user
    db = SessionLocal()
    try:
        q = db.query(FinancialEntry).filter(FinancialEntry.user_id == user.id)

        entry_type = request.args.get("entry_type")
        if entry_type:
            q = q.filter(FinancialEntry.entry_type == entry_type)

        start = request.args.get("start")
        end = request.args.get("end")
        if start:
            q = q.filter(FinancialEntry.entry_date >= start)
        if end:
            q = q.filter(FinancialEntry.entry_date <= end)

        items = [entry_to_dict(e) for e in q.order_by(FinancialEntry.entry_date.desc()).all()]
        print('\n')
        print(items)
        return jsonify({"items": items})
    finally:
        db.close()


@app.post("/api/entries")
@token_required
def create_entry():
    user = g.current_user
    data = request.get_json() or {}
    required_fields = ["entry_type", "amount", "entry_date"]
    for f in required_fields:
        if f not in data or data[f] in (None, ""):
            return jsonify({"error": f"{f} is required"}), 400

    db = SessionLocal()
    try:
        entry = FinancialEntry(
            user_id=user.id,
            entry_type=data["entry_type"],
            category=data.get("category"),
            amount=float(data["amount"]),
            currency=data.get("currency", "LKR"),
            vendor=data.get("vendor"),
            reference=data.get("reference"),
            notes=data.get("notes"),
            entry_date=date.fromisoformat(data["entry_date"]),
            source=data.get("source", "manual"),
            raw_text=data.get("raw_text"),
        )
        db.add(entry)
        db.commit()
        db.refresh(entry)
        
        #print('\n')
        #print(entry)
        
        return jsonify(entry_to_dict(entry)), 201
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        db.close()


@app.get("/api/entries/<int:entry_id>")
@token_required
def get_entry(entry_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        entry = db.get(FinancialEntry, entry_id)
        if not entry or entry.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        return jsonify(entry_to_dict(entry))
    finally:
        db.close()


@app.put("/api/entries/<int:entry_id>")
@token_required
def update_entry(entry_id: int):
    user = g.current_user
    data = request.get_json() or {}
    db = SessionLocal()
    try:
        entry = db.get(FinancialEntry, entry_id)
        if not entry or entry.user_id != user.id:
            return jsonify({"error": "Not found"}), 404

        for field in ["entry_type", "category", "currency", "vendor", "reference", "notes", "raw_text", "source"]:
            if field in data:
                setattr(entry, field, data[field])

        if "amount" in data:
            entry.amount = float(data["amount"]) if data["amount"] is not None else None
        if "entry_date" in data and data["entry_date"]:
            entry.entry_date = date.fromisoformat(data["entry_date"])

        db.commit()
        db.refresh(entry)
        return jsonify(entry_to_dict(entry))
    except Exception as e:
        db.rollback()
        return jsonify({"error": str(e)}), 400
    finally:
        db.close()


@app.delete("/api/entries/<int:entry_id>")
@token_required
def delete_entry(entry_id: int):
    user = g.current_user
    db = SessionLocal()
    try:
        entry = db.get(FinancialEntry, entry_id)
        if not entry or entry.user_id != user.id:
            return jsonify({"error": "Not found"}), 404
        db.delete(entry)
        db.commit()
        return jsonify({"status": "deleted"})
    finally:
        db.close()


# Serve uploaded images (only for debug/dev)
@app.get("/uploads/<path:filename>")
def uploaded_file(filename):
    return send_from_directory(UPLOAD_DIR, filename)


if __name__ == "__main__":
    # In dev: set FLASK_ENV=development
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=True)


import os
import logging
from datetime import datetime, date, timedelta, timezone
from typing import Dict, Optional, Tuple, Any, List
from sqlalchemy import text

import pandas as pd
import numpy as np
from joblib import dump, load
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from db import engine, SessionLocal
from models import FinancialEntry, User

# Prophet
from prophet import Prophet
from prophet.diagnostics import cross_validation

LOG = logging.getLogger("predictor")
LOG.setLevel(logging.INFO)

# Configuration
MODEL_DIR = os.environ.get("MODEL_DIR", os.path.join(os.path.dirname(__file__), "user_models"))
GLOBAL_MODEL_PATH = os.path.join(MODEL_DIR, "global_model.pkl")
os.makedirs(MODEL_DIR, exist_ok=True)

# Scheduler (shared)
scheduler = BackgroundScheduler(timezone="UTC")
scheduler.start()

# ---- Utilities: monthly aggregation ----
def get_monthly_net_flow_df(user_id: int) -> pd.DataFrame:
    """
    Returns a dataframe with columns ['ds','y'] where ds = month start (Timestamp),
    y = net monthly flow = SUM(INCOME) - SUM(EXPENSES,SAVINGS,INVESTMENTS,DEBT)
    Includes month gaps (filled with 0) from first month seen to current month-1.
    """
    query = """
    SELECT
      strftime('%Y-%m', entry_date) AS month,
      SUM(CASE WHEN entry_type = 'INCOME' THEN amount ELSE 0 END) -
      SUM(CASE WHEN entry_type IN ('EXPENSES','SAVINGS','INVESTMENTS','DEBT') THEN amount ELSE 0 END) AS net_flow
    FROM financial_entries
    WHERE user_id = :uid
    GROUP BY month
    ORDER BY month
    """
    with engine.connect() as conn:
        df = pd.read_sql(query, conn, params={"uid": user_id})

    if df.empty:
        return pd.DataFrame(columns=["ds", "y"])

    # convert to datetimes on first of month
    df["ds"] = pd.to_datetime(df["month"] + "-01", format="%Y-%m-%d", errors="coerce")
    df["y"] = pd.to_numeric(df["net_flow"], errors="coerce").fillna(0.0)

    df = df[["ds", "y"]].sort_values("ds").reset_index(drop=True)

    # Fill monthly gaps from first recorded month to latest month (exclusive or inclusive)
    start = df["ds"].min()
    # ensure at least one row
    end = (pd.to_datetime(date.today()).replace(day=1) - pd.offsets.MonthBegin(0))  # current month start
    # include the latest completed month (we will forecast next month)
    all_months = pd.date_range(start=start, end=end, freq="MS")  # MS = month start
    df = df.set_index("ds").reindex(all_months, fill_value=0.0).rename_axis("ds").reset_index()
    df["y"] = df["y"].astype(float)
    return df


def get_user_current_balance(user_id: int) -> float:
    """
    Compute current cumulative balance (total income - total outflows) across all time for the user.
    This is used as a base balance to which predicted next-month net flow is added to produce predicted money in hand.
    """
    query = """
    SELECT
      SUM(CASE WHEN entry_type = 'INCOME' THEN amount ELSE -amount END) AS balance
    FROM financial_entries
    WHERE user_id = :uid
    """
    with engine.connect() as conn:
        res = conn.execute(text(query), {"uid": user_id}).fetchone()
        val = res[0] if res and res[0] is not None else 0.0
    try:
        return float(val)
    except Exception:
        return 0.0


# ---- Model IO ----
def _model_path_for_user(user_id: int) -> str:
    return os.path.join(MODEL_DIR, f"user_{user_id}_money_in_hand_model.pkl")


def save_model_for_user(user_id: int, model: Prophet) -> None:
    path = _model_path_for_user(user_id)
    dump(model, path)
    LOG.info("Saved model for user %s -> %s", user_id, path)


def load_model_for_user(user_id: int) -> Optional[Prophet]:
    path = _model_path_for_user(user_id)
    if not os.path.exists(path):
        return None
    try:
        model = load(path)
        LOG.info("Loaded model for user %s from %s", user_id, path)
        return model
    except Exception as e:
        LOG.exception("Failed loading model for user %s: %s", user_id, e)
        return None


def save_global_model(model: Prophet) -> None:
    dump(model, GLOBAL_MODEL_PATH)
    LOG.info("Saved global model -> %s", GLOBAL_MODEL_PATH)


def load_global_model() -> Optional[Prophet]:
    if not os.path.exists(GLOBAL_MODEL_PATH):
        return None
    try:
        return load(GLOBAL_MODEL_PATH)
    except Exception as e:
        LOG.exception("Failed loading global model: %s", e)
        return None


# ---- Training / Retraining ----
def _train_prophet(df: pd.DataFrame, yearly_seasonality: bool = True) -> Prophet:
    """
    Train Prophet model on monthly data. df must have columns ds (datetime) and y (float).
    """
    model = Prophet(yearly_seasonality=yearly_seasonality, weekly_seasonality=False, daily_seasonality=False)

    model.fit(df)
    return model


def retrain_user_model(user_id: int, force: bool = False) -> Dict[str, Any]:
    """
    Retrain (or train) model for given user. Returns a dict with training metadata.
    If not enough data (<3 months), does not train personalized model but returns info and optionally ensures global fallback exists.
    """
    LOG.info("Retrain requested for user %s (force=%s)", user_id, force)
    try:
        df = get_monthly_net_flow_df(user_id)
        n_months = len(df)
        LOG.info("User %s: monthly series length=%s", user_id, n_months)

        if n_months < 3 and not force:
            LOG.info("Not enough data to train personalized model for user %s (n=%s).", user_id, n_months)
            # ensure global model exists: optionally train global if not present
            gm = load_global_model()
            if gm is None:
                LOG.info("Global model missing; training global model now.")
                _train_global_model()
            return {"status": "insufficient_data", "n_months": n_months, "trained": False}

        # train personalized model (use yearly seasonality allowed)
        if df.empty or df["y"].isnull().all():
            raise ValueError("Empty or invalid monthly series for user %s" % user_id)

        model = _train_prophet(df)
        save_model_for_user(user_id, model)
        return {"status": "ok", "n_months": n_months, "trained": True, "trained_at": datetime.utcnow().isoformat()}
    except Exception as e:
        LOG.exception("Retraining failed for user %s: %s", user_id, e)
        return {"status": "error", "error": str(e)}


def _train_global_model() -> Dict[str, Any]:
    """
    Train a global model aggregated across users (sum or mean per month) to use as fallback for users with insufficient personal history.
    Aggregates monthly net flows across users (by month) and trains a model.
    """
    LOG.info("Training global fallback model...")
    # Query aggregated monthly net flow across all users
    query = """
    SELECT
      strftime('%Y-%m', entry_date) AS month,
      SUM(CASE WHEN entry_type = 'INCOME' THEN amount ELSE 0 END) -
      SUM(CASE WHEN entry_type IN ('EXPENSES','SAVINGS','INVESTMENTS','DEBT') THEN amount ELSE 0 END) AS net_flow
    FROM financial_entries
    GROUP BY month
    ORDER BY month
    """
    with engine.connect() as conn:
        df = pd.read_sql(query, conn)

    if df.empty:
        LOG.warning("No global data available to train global model.")
        return {"status": "no_data"}

    df["ds"] = pd.to_datetime(df["month"] + "-01", format="%Y-%m-%d", errors="coerce")
    df["y"] = pd.to_numeric(df["net_flow"], errors="coerce").fillna(0.0)
    df = df[["ds", "y"]].sort_values("ds").reset_index(drop=True)

    try:
        model = _train_prophet(df)
        save_global_model(model)
        return {"status": "ok", "trained_at": datetime.utcnow().isoformat()}
    except Exception as e:
        LOG.exception("Global training failed: %s", e)
        return {"status": "error", "error": str(e)}


# ---- Prediction endpoint helper ----
def predict_user_next_month_net_flow(user_id: int) -> Dict[str, Any]:
    """
    Predict next month's net_flow for the user using user's model or fallback.
    Returns {predicted_net_flow, lower, upper, model_used, confidence, raw_forecast_rows,...}
    Recommended to round numeric results to 2 decimals in API response.
    """
    try:
        df = get_monthly_net_flow_df(user_id)
        if df.empty:
            # no history: fallback to zero prediction and confidence low
            return {"predicted_net_flow": 0.0, "lower": 0.0, "upper": 0.0, "model_used": "none", "confidence": 0.0}

        model = load_model_for_user(user_id)
        model_used = "user_model"
        # if user model missing or insufficient data, use global
        if model is None:
            LOG.info("User %s model missing; trying global model", user_id)
            model = load_global_model()
            model_used = "global_model"

        if model is None:
            # no models available - fallback: simple average of recent months
            recent_mean = float(df["y"].tail(3).mean()) if len(df) >= 1 else 0.0
            return {
                "predicted_net_flow": round(recent_mean, 2),
                "lower": round(recent_mean, 2),
                "upper": round(recent_mean, 2),
                "model_used": "fallback_average",
                "confidence": 0.25,
            }

        # prepare future dataframe for next month (periods=1, freq='M' -> month end; Prophet expects monthly ds values)
        # Prophet uses 'MS' or 'M' handling; easiest: create future with periods=1 and freq='MS' starting after last ds
        last_ds = df["ds"].max()
        # create future frame of 1 month beyond last_ds
        future = model.make_future_dataframe(periods=1, freq='M')
        # predict
        forecast = model.predict(future)
        # forecast row for the next month will be last row
        pred_row = forecast.iloc[-1]
        yhat = float(pred_row["yhat"])
        lower = float(pred_row.get("yhat_lower", yhat))
        upper = float(pred_row.get("yhat_upper", yhat))

        # simplistic "confidence" estimate from Prophet intervals: narrower interval => higher confidence
        width = max(1e-6, abs(upper - lower))
        # heuristic: confidence = 1 / (1 + width/scale) scaled into 0..1
        scale = max(1.0, max(abs(yhat), 1.0))
        conf = max(0.0, min(0.99, 1.0 / (1.0 + (width / (scale * 2.0)))))

        return {
            "predicted_net_flow": round(yhat, 2),
            "lower": round(lower, 2),
            "upper": round(upper, 2),
            "model_used": model_used,
            "confidence": round(float(conf), 3),
            "raw_score": None,
        }
    except Exception as e:
        LOG.exception("Prediction failed for user %s: %s", user_id, e)
        return {"error": str(e)}


def predict_user_money_in_hand(user_id: int) -> Dict[str, Any]:
    """
    Computes predicted money in hand for next month end = current_total_balance + predicted next month net_flow.
    Returns detailed json including current_balance and predicted_net_flow.
    """
    try:
        pred = predict_user_next_month_net_flow(user_id)
        if "error" in pred:
            return pred
        predicted_net = pred["predicted_net_flow"]
        lower = pred.get("lower", predicted_net)
        upper = pred.get("upper", predicted_net)
        model_used = pred.get("model_used")

        current_balance = get_user_current_balance(user_id)
        predicted_money = round(current_balance + predicted_net, 2)
        lower_money = round(current_balance + lower, 2)
        upper_money = round(current_balance + upper, 2)

        return {
            "user_id": user_id,
            "current_balance": round(float(current_balance), 2),
            "predicted_net_flow_next_month": predicted_net,
            "predicted_money_in_hand_next_month": predicted_money,
            "predicted_money_lower": lower_money,
            "predicted_money_upper": upper_money,
            "model_used": model_used,
            "confidence": pred.get("confidence", 0.0),
        }
    except Exception as e:
        LOG.exception("Money-in-hand prediction error for user %s: %s", user_id, e)
        return {"error": str(e)}


# ---- Scheduling helpers ----
def schedule_retrain_user(user_id: int, when: Optional[datetime] = None, delay_seconds: int = 2, misfire_grace: int = 3600) -> str:
    """
    Schedule a one-off retrain job for a user.
    Returns the scheduler job id.
    """
    try:
        if when is None:
            run_date = datetime.now(timezone.utc) + timedelta(seconds=delay_seconds)
        else:
            # if provided datetime is naive, assume it's local and convert to UTC
            if when.tzinfo is None:
                run_date = when.astimezone(timezone.utc)
            else:
                run_date = when.astimezone(timezone.utc)

        job = scheduler.add_job(
            func=retrain_user_model,
            trigger="date",
            run_date=run_date,
            args=[user_id],
            replace_existing=False,
            misfire_grace_time=misfire_grace,
            coalesce=True,
            max_instances=1,
        )
        LOG.info("Scheduled retrain job %s for user %s at %s (UTC)", job.id, user_id, run_date.isoformat())
        return job.id
    except Exception as e:
        LOG.exception("Failed to schedule retrain for user %s: %s", user_id, e)
        raise


def schedule_monthly_retrain_all(day: int = 1, hour: int = 3, minute: int = 0) -> None:
    """
    Schedule monthly retraining job for all users via cron (default: day 1 at 03:00 UTC).
    """
    LOG.info("Scheduling monthly retrain of all users on day=%s %02d:%02d", day, hour, minute)
    # job runs monthly on day at specified time
    trigger = CronTrigger(day=day, hour=hour, minute=minute)
    scheduler.add_job(retrain_all_users, trigger)


def retrain_all_users() -> None:
    LOG.info("Retraining models for all users (cron job)")
    # Get all user IDs
    db = SessionLocal()
    try:
        users = db.query(User.id).all()
        for (uid,) in users:
            try:
                retrain_user_model(uid)
            except Exception:
                LOG.exception("Failed retrain for user %s in retrain_all_users", uid)
    finally:
        db.close()


# start scheduled monthly retrain by default (day 1 at 03:00)
try:
    schedule_monthly_retrain_all()
except Exception as e:
    LOG.exception("Failed to schedule monthly retrain: %s", e)


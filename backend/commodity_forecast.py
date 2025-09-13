import os
import json
import joblib
import logging
from datetime import datetime
from flask import Blueprint, jsonify, request, current_app
import pandas as pd

try:
    import yfinance as yf
except Exception:
    yf = None

try:
    from prophet import Prophet
except Exception:
    Prophet = None

from auth import token_required   # adjust import path if using package-style imports

commodity_bp = Blueprint("commodity_forecast", __name__, url_prefix="/api/invest")

MODEL_DIR = os.path.join(os.path.dirname(__file__), "models", "commodities")
os.makedirs(MODEL_DIR, exist_ok=True)

# Map common commodity symbols to yfinance tickers
SYMBOL_MAP = {
    "GOLD": "GC=F",    # Gold futures 
    "CRUDE": "CL=F",   # Crude Oil futures
    "BRENT": "BZ=F",   # Brent Oil futures
    "SILVER": "SI=F",   # Silver futures
    "COPPER": "HG=F",   # Copper futures
    "CORN": "ZC=F",     # Corn futures
    "SOYBEAN": "ZS=F",  # Soybean futures
    "SOYOIL": "ZL=F",   # Soybean Oil futures
    "COCOA": "CC=F",    # Cocoa futures
    "COFFEE": "KC=F",   # Coffee futures
    "WHEAT": "ZW=F",    # Wheat futures
    "COTTON": "CT=F",   # Cotton futures
    "SUGAR": "SB=F",    # Sugar futures
}

log = logging.getLogger("commodity_forecast")


def _resolve_ticker(symbol: str) -> str:
    s = (symbol or "").strip().upper()
    if s in SYMBOL_MAP:
        return SYMBOL_MAP[s]
    return s


def _model_path_for(symbol: str) -> str:
    safe = symbol.replace("/", "_").replace("\\", "_")
    return os.path.join(MODEL_DIR, f"commodity_{safe}.pkl")


def _find_close_column(columns):
    """
    Given an iterable of column labels (could be strings or tuples for MultiIndex),
    return the first column label that refers to a 'close' field (case-insensitive).
    If not found, return None.
    """
    for col in columns:
        # tuple (MultiIndex)
        if isinstance(col, tuple):
            for part in col:
                try:
                    if isinstance(part, str) and "close" in part.lower():
                        return col
                except Exception:
                    continue
        else:
            try:
                if isinstance(col, str) and "close" in col.lower():
                    return col
            except Exception:
                continue
    return None


def _fetch_price_history(ticker: str, period_days: int = 365):
    """
    Fetch daily close prices for the ticker using yfinance.
    Returns DataFrame with columns ['ds','y'] where ds is datetime and y is float close.
    Defensive handling for yfinance differences (MultiIndex, different column names).
    """
    if yf is None:
        raise RuntimeError("yfinance not available; install with `pip install yfinance`")

    period_str = f"{max(30, int(period_days))}d"
    # explicitly set auto_adjust True
    df = yf.download(ticker, period=period_str, interval="1d", progress=False, auto_adjust=True)

    print(df.head())
    print("columns:", df.columns)

    if df is None or df.empty:
        return pd.DataFrame(columns=["ds", "y"])

    # If df has DatetimeIndex (usual), reset_index to get a date column
    if isinstance(df.index, pd.DatetimeIndex):
        dfc = df.reset_index()
        date_col = dfc.columns[0]
    else:
        dfc = df.reset_index()
        date_col = dfc.columns[0]

    # If dfc.columns is MultiIndex, columns will be tuples; create a list view we can search
    cols = list(dfc.columns)

    # Try to find a close-like column robustly
    close_col = _find_close_column(cols)

    if close_col is None:
        # if no close-like column, attempt to pick the last numeric column as fallback
        numeric_cols = [c for c in cols if pd.api.types.is_numeric_dtype(dfc[c])]
        # remove the date column if present
        numeric_cols = [c for c in numeric_cols if c != date_col]
        if numeric_cols:
            close_col = numeric_cols[-1]

    if close_col is None:
        # nothing usable - return empty to let caller handle fallback
        current_app.logger.error("No close-like column found for ticker %s; columns: %s", ticker, cols)
        return pd.DataFrame(columns=["ds", "y"])

    # create a clean df with ds and y — selecting close_col works whether it's string or tuple
    try:
        dfc2 = dfc[[date_col, close_col]].copy()
    except Exception as e:
        # debug: log columns and raise a controlled empty DF
        current_app.logger.exception("Failed to select date and close columns (%s, %s): %s", date_col, close_col, e)
        return pd.DataFrame(columns=["ds", "y"])

    # rename to ds/y for Prophet
    dfc2.columns = ["ds", "y"]
    # ensure ds is datetime (naive)
    dfc2["ds"] = pd.to_datetime(dfc2["ds"], errors="coerce").dt.tz_localize(None)
    # coerce y to numeric and drop NaNs
    dfc2["y"] = pd.to_numeric(dfc2["y"], errors="coerce")
    dfc2 = dfc2.dropna(subset=["ds", "y"]).reset_index(drop=True)
    return dfc2[["ds", "y"]]


def _safe_float(v):
    try:
        return float(v)
    except Exception:
        return None


@commodity_bp.route("/commodity_forecast/<string:symbol>", methods=["GET"])
@token_required
def commodity_forecast(symbol: str):
    """
    GET /api/invest/commodity_forecast/<symbol>?period_days=365&horizon_days=30
    """
    ticker = _resolve_ticker(symbol)
    period_days = int(request.args.get("period_days", 365))
    horizon_days = int(request.args.get("horizon_days", 30))

    # fetch history
    try:
        df = _fetch_price_history(ticker, period_days=period_days)
    except Exception as e:
        current_app.logger.exception("Price fetch failed for %s: %s", ticker, e)
        return jsonify({"error": f"Failed to fetch price history: {e}"}), 500

    # if no data return friendly error / fallback
    if df.empty or len(df) < 10:
        last_price = None
        if not df.empty:
            last_price = _safe_float(df["y"].iloc[-1])
        return jsonify({
            "symbol": symbol,
            "ticker": ticker,
            "recent": [{"ds": r["ds"].strftime("%Y-%m-%d"), "y": float(r["y"])} for _, r in df.tail(90).iterrows()],
            "prediction": {
                "horizon_days": horizon_days,
                "yhat": last_price,
                "yhat_lower": last_price,
                "yhat_upper": last_price,
                "confidence": 0.0,
                "method": "fallback_last_value_or_no_data"
            }
        })

    model_path = _model_path_for(ticker)

    # Prepare training dataframe — use the most recent portion to limit training time
    try:
        if len(df) > 800:
            df_train = df.tail(800).copy()
        else:
            df_train = df.copy()

        # Defensive cleaning: ensure required columns and numeric y
        df_train = df_train[["ds", "y"]].copy()
        df_train["ds"] = pd.to_datetime(df_train["ds"], errors="coerce").dt.tz_localize(None)
        df_train["y"] = pd.to_numeric(df_train["y"], errors="coerce")
        df_train = df_train.dropna(subset=["ds", "y"]).reset_index(drop=True)

        # if too few rows after cleaning fallback
        if df_train.shape[0] < 10:
            last_price = _safe_float(df["y"].iloc[-1])
            return jsonify({
                "symbol": symbol,
                "ticker": ticker,
                "recent": [{"ds": r["ds"].strftime("%Y-%m-%d"), "y": float(r["y"])} for _, r in df.tail(90).iterrows()],
                "prediction": {
                    "horizon_days": horizon_days,
                    "yhat": last_price,
                    "yhat_lower": last_price,
                    "yhat_upper": last_price,
                    "confidence": 0.0,
                    "method": "fallback_insufficient_clean_data"
                }
            })

        # If Prophet isn't installed, fallback to last-value method
        if Prophet is None:
            last_val = float(df_train["y"].iloc[-1])
            return jsonify({
                "symbol": symbol,
                "ticker": ticker,
                "recent": [{"ds": r["ds"].strftime("%Y-%m-%d"), "y": float(r["y"])} for _, r in df.tail(90).iterrows()],
                "prediction": {"horizon_days": horizon_days, "yhat": last_val, "yhat_lower": last_val, "yhat_upper": last_val, "confidence": 0.0, "method": "fallback_no_prophet"}
            })

        # Fit model
        m = Prophet(yearly_seasonality=True, weekly_seasonality=False, daily_seasonality=False)
        m.fit(df_train)

        # persist model for reuse (best-effort)
        try:
            joblib.dump(m, model_path)
        except Exception:
            current_app.logger.warning("Failed to persist commodity model to %s", model_path)

        future = m.make_future_dataframe(periods=horizon_days, freq="D")
        forecast = m.predict(future)

        # take the last forecasted day of the horizon
        fh = forecast.tail(horizon_days)
        if fh.empty:
            yhat = None
            yhat_lower = None
            yhat_upper = None
        else:
            last = fh.iloc[-1]
            yhat = _safe_float(last.get("yhat"))
            yhat_lower = _safe_float(last.get("yhat_lower"))
            yhat_upper = _safe_float(last.get("yhat_upper"))

        # compute a simple confidence metric: smaller CI width => higher confidence
        confidence = 0.0
        if yhat is not None and yhat_upper is not None and yhat_lower is not None and abs(yhat) > 1e-9:
            width = float(yhat_upper) - float(yhat_lower)
            rel = min(1.0, max(0.0, width / (abs(float(yhat)) + 1e-6)))
            confidence = float(max(0.0, 1.0 - rel))

        recent = [{"ds": r["ds"].strftime("%Y-%m-%d"), "y": float(r["y"])} for _, r in df.tail(90).iterrows()]

        return jsonify({
            "symbol": symbol,
            "ticker": ticker,
            "recent": recent,
            "prediction": {
                "horizon_days": horizon_days,
                "yhat": yhat,
                "yhat_lower": yhat_lower,
                "yhat_upper": yhat_upper,
                "confidence": round(confidence, 3),
                "method": "prophet",
            },
            "model_path": model_path if os.path.exists(model_path) else None
        })

    except Exception as e:
        current_app.logger.exception("Commodity forecast failed for %s: %s", ticker, e)
        return jsonify({"error": str(e)}), 500


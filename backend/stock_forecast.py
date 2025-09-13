import os
import json
import math
import traceback
from datetime import timedelta
from flask import Blueprint, request, jsonify, current_app
from db import SessionLocal
import pandas as pd
import numpy as np

# ML libs
try:
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader, TensorDataset
    TORCH_AVAILABLE = True
except Exception:
    TORCH_AVAILABLE = False

from sklearn.preprocessing import MinMaxScaler
import joblib

# set up blueprint
stock_bp = Blueprint("stock_forecast", __name__, url_prefix="/api/invest")

# directories
BASE_DIR = os.path.dirname(os.path.dirname(__file__)) if os.path.basename(os.path.dirname(__file__)) != "" else os.getcwd()
DATA_DIR = os.path.join(BASE_DIR, os.path.dirname(__file__), "stock_dataset")
MODEL_DIR = os.path.join(BASE_DIR, os.path.dirname(__file__), "models", "stock")
os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs(DATA_DIR, exist_ok=True)

# Helpful constants
DEFAULT_TIME_STEP = 60
DEFAULT_EPOCHS = 40
DEFAULT_BATCH = 32
DEFAULT_FUTURE_DAYS = 183  # ~6 months


# ----------------------------------------------
# Utilities: robust CSV loader / column detection
# ----------------------------------------------
def _find_date_and_close_columns(df: pd.DataFrame):

    date_candidates = ['Trade Date', 'Date', 'trade_date', 'date', 'Date Time']
    close_candidates = ['Close (Rs.)', 'Close', 'Adj Close', 'Adj_Close', 'close', 'ClosePrice', 'Close Price']
    date_col = None
    close_col = None
    cols_lower = {c.lower(): c for c in df.columns}

    # date
    for cand in date_candidates:
        if cand in df.columns:
            date_col = cand
            break
        if cand.lower() in cols_lower:
            date_col = cols_lower[cand.lower()]
            break

    # close
    for cand in close_candidates:
        if cand in df.columns:
            close_col = cand
            break
        if cand.lower() in cols_lower:
            close_col = cols_lower[cand.lower()]
            break

    # last effort: pick first datetime-like col as date and last numeric col as close
    if date_col is None:
        for c in df.columns:
            try:
                pd.to_datetime(df[c].iloc[0])
                date_col = c
                break
            except Exception:
                continue

    if close_col is None:
        numeric_cols = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])]
        if numeric_cols:
            close_col = numeric_cols[-1]

    return date_col, close_col


def load_stock_csv(file_path: str) -> pd.DataFrame:
    if not os.path.exists(file_path):
        raise FileNotFoundError(file_path)
    # try a few parsers
    df = pd.read_csv(file_path)
    date_col, close_col = _find_date_and_close_columns(df)
    if date_col is None or close_col is None:
        # try with parse_dates param
        df_try = pd.read_csv(file_path, parse_dates=True, infer_datetime_format=True)
        date_col, close_col = _find_date_and_close_columns(df_try)
        if date_col is None or close_col is None:
            raise ValueError("Could not find date and close columns in CSV. Expected columns like 'Trade Date' and 'Close (Rs.)' or similar.")
        df = df_try

    # convert & sort by date ascending
    df[date_col] = pd.to_datetime(df[date_col], errors='coerce')
    df = df.dropna(subset=[date_col])
    df = df.sort_values(by=date_col, ascending=True).reset_index(drop=True)
    # keep only ds (date) and y (close)
    series = df[[date_col, close_col]].copy()
    series.columns = ['ds', 'y']
    series['y'] = pd.to_numeric(series['y'], errors='coerce')
    series = series.dropna(subset=['y']).reset_index(drop=True)
    return series


# --------------------
# LSTM model (PyTorch)
# --------------------
if TORCH_AVAILABLE:
    class LSTMModel(nn.Module):
        def __init__(self, input_size=1, hidden_size=64, num_layers=2, output_size=1):
            super(LSTMModel, self).__init__()
            self.hidden_size = hidden_size
            self.num_layers = num_layers
            self.lstm = nn.LSTM(input_size, hidden_size, num_layers, batch_first=True)
            self.fc = nn.Linear(hidden_size, output_size)

        def forward(self, x):
            # x: (batch, seq, features)
            h0 = torch.zeros(self.num_layers, x.size(0), self.hidden_size)
            c0 = torch.zeros(self.num_layers, x.size(0), self.hidden_size)
            out, _ = self.lstm(x, (h0, c0))
            out = self.fc(out[:, -1, :])
            return out


# -----------------------
# training & prediction
# -----------------------
def prepare_lstm_data(y_series: pd.Series, time_step=DEFAULT_TIME_STEP):
    arr = y_series.values.reshape(-1, 1)
    scaler = MinMaxScaler(feature_range=(0, 1))
    scaled = scaler.fit_transform(arr)
    X, y = [], []
    for i in range(len(scaled) - time_step):
        X.append(scaled[i:i+time_step, 0])
        y.append(scaled[i+time_step, 0])
    if len(X) == 0:
        return None  # insufficient data
    X = np.array(X).reshape(-1, time_step, 1)
    y = np.array(y).reshape(-1, 1)
    # split 80/20
    split = int(0.8 * len(X))
    X_train, X_test = X[:split], X[split:]
    y_train, y_test = y[:split], y[split:]
    # convert to torch
    X_train_t = torch.from_numpy(X_train).float()
    y_train_t = torch.from_numpy(y_train).float()
    X_test_t = torch.from_numpy(X_test).float()
    y_test_t = torch.from_numpy(y_test).float()
    return X_train_t, y_train_t, X_test_t, y_test_t, scaler, time_step


def train_lstm(X_train, y_train, epochs=DEFAULT_EPOCHS, batch_size=DEFAULT_BATCH, hidden_size=64, lr=1e-3):
    model = LSTMModel(hidden_size=hidden_size)
    criterion = nn.MSELoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=lr)
    dataset = TensorDataset(X_train, y_train)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=True)
    last_loss = None
    for epoch in range(epochs):
        model.train()
        epoch_loss = 0.0
        for xb, yb in loader:
            optimizer.zero_grad()
            out = model(xb)
            loss = criterion(out, yb)
            loss.backward()
            optimizer.step()
            epoch_loss = loss.item()
        last_loss = epoch_loss
        current_app.logger.info(f"LSTM train epoch {epoch+1}/{epochs}, loss={last_loss:.6f}")
    return model, last_loss


def predict_future_lstm(model, series_values, scaler, time_step, future_days=DEFAULT_FUTURE_DAYS):
    # series_values: pandas Series of raw prices (ascending)
    model.eval()
    preds = []
    # take last `time_step` values
    sequence = series_values.values[-time_step:].reshape(-1, 1)
    scaled = scaler.transform(sequence)
    last_seq = torch.from_numpy(scaled.reshape(1, time_step, 1)).float()
    for _ in range(future_days):
        with torch.no_grad():
            out = model(last_seq)
        # out shape (1,1)
        val = out.numpy().reshape(-1, 1)
        # append predicted scaled value to sequence
        preds.append(val[0, 0])
        # shift last_seq and append val
        next_scaled = np.array(val).reshape(1, 1, 1)
        last_seq = torch.cat((last_seq[:, 1:, :], torch.from_numpy(next_scaled).float()), dim=1)
    # invert scaling
    preds_arr = np.array(preds).reshape(-1, 1)
    inv = scaler.inverse_transform(preds_arr)
    # return flattened floats
    return [float(x[0]) for x in inv]


# ------------------------
# Simple fallback methods
# ------------------------
def fallback_last_value(series_values, future_days):
    last = float(series_values.values[-1])
    return [last for _ in range(future_days)]


def fallback_linear_extrap(series_values, future_days):
    # perform linear regression on last N points
    n = min(30, len(series_values))
    y = np.array(series_values.values[-n:])
    x = np.arange(len(y))
    if len(y) < 2:
        return fallback_last_value(series_values, future_days)
    a, b = np.polyfit(x, y, 1)  # y = a*x + b
    last_x = len(y) - 1
    preds = []
    for i in range(1, future_days + 1):
        preds.append(float(a * (last_x + i) + b))
    return preds


# ------------------------
# Endpoints
# ------------------------
@stock_bp.route("/stock/datasets", methods=["GET"])
def list_datasets():
    """List CSV files in stock_dataset folder."""
    try:
        files = []
        for f in os.listdir(DATA_DIR):
            if f.lower().endswith(".csv"):
                path = os.path.join(DATA_DIR, f)
                stat = os.stat(path)
                files.append({
                    "filename": f,
                    "size": stat.st_size,
                    "modified": int(stat.st_mtime)
                })
        files = sorted(files, key=lambda x: x["filename"])
        return jsonify({"datasets": files})
    except Exception as e:
        current_app.logger.exception("list_datasets failed: %s", e)
        return jsonify({"error": str(e)}), 500


@stock_bp.route("/stock/preview", methods=["GET"])
def preview_dataset():
    """Preview last N rows of a CSV dataset. ?filename=...&n=20"""
    filename = request.args.get("filename")
    n = int(request.args.get("n", 20))
    if not filename:
        return jsonify({"error": "filename required"}), 400
    path = os.path.join(DATA_DIR, filename)
    try:
        df = load_stock_csv(path)
        # convert to friendly JSON: last n rows
        rows = []
        for _, r in df.tail(n).iterrows():
            rows.append({"ds": pd.to_datetime(r["ds"]).strftime("%Y-%m-%d"), "y": float(r["y"])})
        return jsonify({"preview": rows, "count": len(df)})
    except Exception as e:
        current_app.logger.exception("preview failed: %s", e)
        return jsonify({"error": str(e)}), 400


@stock_bp.route("/stock/forecast", methods=["POST"])
def forecast_stock():
    """
    POST payload JSON:
      { "filename": "COMB.csv", "future_days": 183, "epochs": 40, "time_step": 60 }
    Returns:
      {
        "filename": "...",
        "count": N,
        "last_date": "YYYY-MM-DD",
        "predictions": [{"ds":"YYYY-MM-DD","price": 123.45}, ...],
        "model_cached": true/false,
        "train_loss": 0.0123
      }
    """
    data = request.get_json() or {}
    filename = data.get("filename")
    future_days = int(data.get("future_days", DEFAULT_FUTURE_DAYS))
    epochs = int(data.get("epochs", DEFAULT_EPOCHS))
    time_step = int(data.get("time_step", DEFAULT_TIME_STEP))
    batch_size = int(data.get("batch_size", DEFAULT_BATCH))
    hidden_size = int(data.get("hidden_size", 64))

    if not filename:
        return jsonify({"error": "filename required"}), 400

    path = os.path.join(DATA_DIR, filename)
    if not os.path.exists(path):
        return jsonify({"error": f"file not found: {filename}"}), 404

    model_base = os.path.join(MODEL_DIR, filename.replace(".csv", ""))
    model_path = model_base + "_lstm.pt"
    scaler_path = model_base + "_scaler.pkl"
    meta_path = model_base + "_meta.json"

    try:
        df = load_stock_csv(path)  # returns df with ds,y
        if df.empty or len(df) < 10:
            return jsonify({"error": "insufficient data in CSV"}), 400

        count = len(df)
        last_date = pd.to_datetime(df["ds"].iloc[-1]).strftime("%Y-%m-%d")

        # If cached model & scaler exist, load them and use for prediction (fast)
        if os.path.exists(model_path) and os.path.exists(scaler_path) and os.path.exists(meta_path):
            try:
                # load scaler
                scaler = joblib.load(scaler_path)
                # load meta to read time_step used at training
                meta = json.load(open(meta_path, "r"))
                ts_used = int(meta.get("time_step", time_step))
                # load model only if torch available
                if TORCH_AVAILABLE:
                    model = LSTMModel(hidden_size=meta.get("hidden_size", 64))
                    model.load_state_dict(torch.load(model_path, map_location=torch.device('cpu')))
                    # predict
                    preds = predict_future_lstm(model, df["y"], scaler, ts_used, future_days=future_days)
                    predictions = []
                    start_date = pd.to_datetime(df["ds"].iloc[-1]) + timedelta(days=1)
                    for i, p in enumerate(preds):
                        predictions.append({"ds": (start_date + timedelta(days=i)).strftime("%Y-%m-%d"), "price": round(float(p), 4)})
                    return jsonify({
                        "filename": filename,
                        "count": count,
                        "last_date": last_date,
                        "predictions": predictions,
                        "model_cached": True,
                        "method": "lstm",
                        "note": "used cached model",
                    })
                else:
                    # no torch -> fallback to linear extrap using scaler trained data
                    preds = fallback_linear_extrap(df["y"], future_days)
                    start_date = pd.to_datetime(df["ds"].iloc[-1]) + timedelta(days=1)
                    predictions = [{"ds": (start_date + timedelta(days=i)).strftime("%Y-%m-%d"), "price": round(float(p), 4)} for i, p in enumerate(preds)]
                    return jsonify({"filename": filename, "count": count, "last_date": last_date, "predictions": predictions, "model_cached": False, "method": "fallback_linear_no_torch", "note": "torch not available"})
            except Exception as ex:
                current_app.logger.exception("Failed using cached model: %s", ex)
                # fall through to retrain

        # Not cached or failed to use cache -> train model (if available)
        if TORCH_AVAILABLE:
            # prepare data
            prep = prepare_lstm_data(df["y"], time_step=time_step)
            if prep is None:
                # insufficient data for time_step
                preds = fallback_linear_extrap(df["y"], future_days)
                start_date = pd.to_datetime(df["ds"].iloc[-1]) + timedelta(days=1)
                predictions = [{"ds": (start_date + timedelta(days=i)).strftime("%Y-%m-%d"), "price": round(float(p), 4)} for i, p in enumerate(preds)]
                return jsonify({"filename": filename, "count": count, "last_date": last_date, "predictions": predictions, "model_cached": False, "method": "fallback_insufficient_for_lstm"})
            X_train, y_train, X_test, y_test, scaler, ts_used = prep
            # train
            model, train_loss = train_lstm(X_train, y_train, epochs=epochs, batch_size=batch_size, hidden_size=hidden_size)
            # persist model + scaler + meta
            try:
                torch.save(model.state_dict(), model_path)
                joblib.dump(scaler, scaler_path)
                json.dump({"time_step": ts_used, "hidden_size": hidden_size}, open(meta_path, "w"))
            except Exception:
                current_app.logger.exception("Failed to persist model artifacts")

            preds = predict_future_lstm(model, df["y"], scaler, ts_used, future_days=future_days)
            start_date = pd.to_datetime(df["ds"].iloc[-1]) + timedelta(days=1)
            predictions = [{"ds": (start_date + timedelta(days=i)).strftime("%Y-%m-%d"), "price": round(float(p), 4)} for i, p in enumerate(preds)]
            return jsonify({"filename": filename, "count": count, "last_date": last_date, "predictions": predictions, "model_cached": False, "method": "lstm", "train_loss": train_loss})
        else:
            # no Torch -> fallback linear extrap
            preds = fallback_linear_extrap(df["y"], future_days)
            start_date = pd.to_datetime(df["ds"].iloc[-1]) + timedelta(days=1)
            predictions = [{"ds": (start_date + timedelta(days=i)).strftime("%Y-%m-%d"), "price": round(float(p), 4)} for i, p in enumerate(preds)]
            return jsonify({"filename": filename, "count": count, "last_date": last_date, "predictions": predictions, "model_cached": False, "method": "fallback_linear_no_torch"})
    except Exception as e:
        tb = traceback.format_exc()
        current_app.logger.exception("stock forecast failed for %s: %s", filename, e)
        return jsonify({"error": str(e), "trace": tb}), 500


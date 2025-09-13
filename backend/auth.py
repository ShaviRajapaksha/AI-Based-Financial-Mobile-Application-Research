import os
import jwt
from datetime import datetime, timedelta
from functools import wraps
from flask import request, jsonify, g
from db import SessionLocal
from models import User

# Auth config (move these here so other modules can import auth helpers)
SECRET_KEY = os.environ.get("SECRET_KEY", "change_this_secret_in_prod")
ACCESS_TOKEN_EXPIRES_DAYS = int(os.environ.get("ACCESS_TOKEN_EXPIRES_DAYS", "7"))

def create_token_for_user(user_id: int) -> str:
    """
    Create a JWT token for the given user id.
    Keep this in auth.py so app.py (register/login) can import it.
    """
    payload = {
        "user_id": user_id,
        "exp": datetime.utcnow() + timedelta(days=ACCESS_TOKEN_EXPIRES_DAYS),
        "iat": datetime.utcnow(),
    }
    token = jwt.encode(payload, SECRET_KEY, algorithm="HS256")
    # PyJWT >=2 returns str
    return token

def decode_token(token: str) -> dict:
    """
    Decode and validate the JWT token. Raises jwt exceptions on invalid/expired.
    """
    payload = jwt.decode(token, SECRET_KEY, algorithms=["HS256"])
    return payload

def token_required(f):
    """
    Decorator to require a valid Bearer token.
    On success attaches SQLAlchemy User model instance to flask.g.current_user.
    """
    @wraps(f)
    def wrapped(*args, **kwargs):
        auth = request.headers.get("Authorization", None)
        if not auth:
            return jsonify({"error": "Authorization header required"}), 401
        parts = auth.split()
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return jsonify({"error": "Invalid Authorization header"}), 401
        token = parts[1]
        try:
            payload = decode_token(token)
            user_id = payload.get("user_id")
            db = SessionLocal()
            try:
                user = db.get(User, user_id)
            finally:
                db.close()
            if not user:
                return jsonify({"error": "Invalid token (user not found)"}), 401
            # attach model instance for downstream handlers
            g.current_user = user
        except jwt.ExpiredSignatureError:
            return jsonify({"error": "Token expired"}), 401
        except jwt.InvalidTokenError:
            return jsonify({"error": "Invalid token"}), 401
        except Exception as e:
            return jsonify({"error": f"Token decode error: {e}"}), 401
        return f(*args, **kwargs)
    return wrapped

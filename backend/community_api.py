from flask import Blueprint, request, jsonify, g, current_app
from datetime import datetime
from sqlalchemy import Column, Integer, String, Text, DateTime, ForeignKey, func, desc
from sqlalchemy.orm import relationship, Session
from sqlalchemy.exc import SQLAlchemyError
from auth import token_required

from db import Base, SessionLocal
from models import User, CommunityVote, CommunityComment, CommunityPost


bp = Blueprint("community", __name__, url_prefix="/api/community")

# --------------------
# Utilities
# --------------------
def _page_params():
    try:
        page = int(request.args.get("page", "1"))
        page_size = int(request.args.get("page_size", "20"))
    except Exception:
        page, page_size = 1, 20
    page = max(1, page)
    page_size = max(1, min(200, page_size))
    return page, page_size

def _parse_vote_value(body):
    try:
        v = int(body.get("value"))
        if v == 0:
            return 0
        return 1 if v > 0 else -1
    except Exception:
        return None


# --------------------
# Endpoints
# --------------------

@bp.route("/posts", methods=["GET"])
def list_posts():
    """
    GET /api/community/posts?page=1&page_size=20&q=search
    Returns paginated posts with:
    - author_name
    - vote_score (sum of values)
    - comment_count
    - user_vote (value for current user)
    """
    page, page_size = _page_params()
    q = (request.args.get("q") or "").strip()

    db = SessionLocal()
    try:
        # base query
        base = db.query(CommunityPost)

        if q:
            like = f"%{q.lower()}%"
            base = base.filter(func.lower(CommunityPost.title).like(like) | func.lower(CommunityPost.body).like(like))

        # total count
        total = base.count()

        # get page of posts ordered by score (aggregate) and recency
        # We'll build aggregation using subqueries for efficiency.

        # aggregate vote scores per post
        vote_scores = db.query(
            CommunityVote.post_id.label("post_id"),
            func.coalesce(func.sum(CommunityVote.value), 0).label("score")
        ).filter(CommunityVote.post_id.isnot(None)).group_by(CommunityVote.post_id).subquery()

        # comment counts per post
        comment_counts = db.query(
            CommunityComment.post_id.label("post_id"),
            func.count(CommunityComment.id).label("count")
        ).group_by(CommunityComment.post_id).subquery()

        # join posts with author, vote_scores, comment_counts
        q_posts = db.query(
            CommunityPost,
            func.coalesce(vote_scores.c.score, 0).label("vote_score"),
            func.coalesce(comment_counts.c.count, 0).label("comment_count"),
            User.name.label("author_name"),
            User.email.label("author_email")
        ).outerjoin(vote_scores, CommunityPost.id == vote_scores.c.post_id
        ).outerjoin(comment_counts, CommunityPost.id == comment_counts.c.post_id
        ).join(User, CommunityPost.user_id == User.id
        )

        if q:
            like = f"%{q.lower()}%"
            q_posts = q_posts.filter(func.lower(CommunityPost.title).like(like) | func.lower(CommunityPost.body).like(like))

        # order by score desc then recent
        q_posts = q_posts.order_by(desc("vote_score"), desc(CommunityPost.created_at))

        offset = (page - 1) * page_size
        rows = q_posts.offset(offset).limit(page_size).all()

        # prepare ids for user votes
        post_ids = [r[0].id for r in rows]

        user_vote_map = {}
        user = getattr(g, "current_user", None)
        if user and post_ids:
            votes = db.query(CommunityVote.post_id, CommunityVote.value).filter(
                CommunityVote.user_id == user.id,
                CommunityVote.post_id.in_(post_ids)
            ).all()
            for pid, val in votes:
                user_vote_map[pid] = int(val)

        items = []
        for row in rows:
            post = row[0]
            extra = {
                "vote_score": int(row[1] or 0),
                "comment_count": int(row[2] or 0),
                "author_name": row[3] or row[4] or "User",
                "user_vote": int(user_vote_map.get(post.id, 0))
            }
            items.append(post.to_dict(extra=extra))

        return jsonify({
            "items": items,
            "page": page,
            "page_size": page_size,
            "total": total
        })
    except Exception as e:
        current_app.logger.exception("list_posts failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@bp.route("/posts", methods=["POST"])
@bp.route("/posts/", methods=["POST"])
@token_required
def create_post():
    """
    POST /api/community/posts
    Body: { title, body }
    Requires auth (token_required wrapper is recommended on your side).
    """
    # user auth: rely on g.current_user (caller should use token_required)
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    data = request.get_json(silent=True) or {}
    title = (data.get("title") or "").strip()
    body = data.get("body")
    if not title:
        return jsonify({"error": "title required"}), 400

    db = SessionLocal()
    try:
        p = CommunityPost(user_id=user.id, title=title, body=body)
        db.add(p)
        db.commit()
        db.refresh(p)
        return jsonify(p.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("create_post failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@bp.route("/posts/<int:post_id>", methods=["GET"])
def get_post(post_id: int):
    """
    GET /api/community/posts/<id>?comments_page=1&comments_page_size=20
    Returns post details + paginated comments + vote info (including user_vote)
    """
    comments_page = int(request.args.get("comments_page", "1"))
    comments_page_size = int(request.args.get("comments_page_size", "50"))
    comments_page = max(1, comments_page)
    comments_page_size = max(1, min(200, comments_page_size))

    db = SessionLocal()
    try:
        post = db.get(CommunityPost, post_id)
        if not post:
            return jsonify({"error": "Not found"}), 404

        # post vote score
        post_score_row = db.query(func.coalesce(func.sum(CommunityVote.value), 0)).filter(CommunityVote.post_id == post_id).scalar()
        post_score = int(post_score_row or 0)

        # current user's vote for post
        user = getattr(g, "current_user", None)
        user_vote = 0
        if user:
            uv = db.query(CommunityVote).filter(CommunityVote.post_id == post_id, CommunityVote.user_id == user.id).first()
            user_vote = int(uv.value) if uv else 0

        # comments with vote scores and pagination
        comment_votes = db.query(
            CommunityVote.comment_id.label("comment_id"),
            func.coalesce(func.sum(CommunityVote.value), 0).label("score")
        ).filter(CommunityVote.comment_id.isnot(None)).group_by(CommunityVote.comment_id).subquery()

        cbase = db.query(
            CommunityComment,
            func.coalesce(comment_votes.c.score, 0).label("vote_score"),
            User.name.label("author_name"),
            User.email.label("author_email")
        ).outerjoin(comment_votes, CommunityComment.id == comment_votes.c.comment_id
        ).join(User, CommunityComment.user_id == User.id
        ).filter(CommunityComment.post_id == post_id)

        # order comments by score desc then recency
        cbase = cbase.order_by(desc("vote_score"), desc(CommunityComment.created_at))

        total_comments = cbase.count()
        offset = (comments_page - 1) * comments_page_size
        crow_rows = cbase.offset(offset).limit(comments_page_size).all()

        comment_ids = [r[0].id for r in crow_rows]
        comment_user_vote_map = {}
        if user and comment_ids:
            cvs = db.query(CommunityVote.comment_id, CommunityVote.value).filter(
                CommunityVote.user_id == user.id,
                CommunityVote.comment_id.in_(comment_ids)
            ).all()
            for cid, val in cvs:
                comment_user_vote_map[cid] = int(val)

        comments_out = []
        for r in crow_rows:
            c = r[0]
            extra = {
                "vote_score": int(r[1] or 0),
                "author_name": r[2] or r[3] or "User",
                "user_vote": int(comment_user_vote_map.get(c.id, 0))
            }
            comments_out.append(c.to_dict(extra=extra))

        post_out = post.to_dict(extra={
            "vote_score": post_score,
            "user_vote": user_vote,
            "author_name": getattr(post.user, "name", None) or getattr(post.user, "email", None) or "User",
            "comment_count": total_comments
        })

        return jsonify({
            "post": post_out,
            "comments": comments_out,
            "comments_page": comments_page,
            "comments_page_size": comments_page_size,
            "comments_total": total_comments
        })
    except Exception as e:
        current_app.logger.exception("get_post failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


@bp.route("/posts/<int:post_id>/comments", methods=["POST"])
@token_required
def create_comment(post_id: int):
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    data = request.get_json(silent=True) or {}
    body = (data.get("body") or "").strip()
    if not body:
        return jsonify({"error": "body required"}), 400

    db = SessionLocal()
    try:
        post = db.get(CommunityPost, post_id)
        if not post:
            return jsonify({"error": "Post not found"}), 404
        c = CommunityComment(post_id=post_id, user_id=user.id, body=body)
        db.add(c)
        db.commit()
        db.refresh(c)
        return jsonify(c.to_dict()), 201
    except Exception as e:
        db.rollback()
        current_app.logger.exception("create_comment failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


# --------------------
# Votes: posts
# --------------------
@bp.route("/posts/<int:post_id>/vote", methods=["POST"])
@token_required
def vote_post(post_id: int):
    """
    Body: { "value": 1 | -1 | 0 }  (0 to remove vote)
    """
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    body = request.get_json(silent=True) or {}
    v = _parse_vote_value(body)
    if v is None:
        return jsonify({"error": "value must be -1, 0 or 1"}), 400

    db = SessionLocal()
    try:
        post = db.get(CommunityPost, post_id)
        if not post:
            return jsonify({"error": "Post not found"}), 404

        existing = db.query(CommunityVote).filter(
            CommunityVote.user_id == user.id,
            CommunityVote.post_id == post_id
        ).first()

        if v == 0:
            if existing:
                db.delete(existing)
                db.commit()
            # recompute score
        else:
            if existing:
                existing.value = v
                existing.created_at = datetime.utcnow()
                db.add(existing)
            else:
                nv = CommunityVote(user_id=user.id, post_id=post_id, value=v)
                db.add(nv)
            db.commit()

        # return new aggregated score and user_vote
        score = db.query(func.coalesce(func.sum(CommunityVote.value), 0)).filter(CommunityVote.post_id == post_id).scalar() or 0
        return jsonify({"status": "ok", "post_id": post_id, "vote_score": int(score), "user_vote": v})
    except SQLAlchemyError as e:
        db.rollback()
        current_app.logger.exception("vote_post error: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


# --------------------
# Votes: comments
# --------------------
@bp.route("/posts/<int:post_id>/comments/<int:comment_id>/vote", methods=["POST"])
@token_required
def vote_comment(post_id: int, comment_id: int):
    """
    Body: { "value": 1 | -1 | 0 }  (0 to remove)
    """
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    body = request.get_json(silent=True) or {}
    v = _parse_vote_value(body)
    if v is None:
        return jsonify({"error": "value must be -1, 0 or 1"}), 400

    db = SessionLocal()
    try:
        comment = db.get(CommunityComment, comment_id)
        if not comment or comment.post_id != post_id:
            return jsonify({"error": "Comment not found"}), 404

        existing = db.query(CommunityVote).filter(
            CommunityVote.user_id == user.id,
            CommunityVote.comment_id == comment_id
        ).first()

        if v == 0:
            if existing:
                db.delete(existing)
                db.commit()
        else:
            if existing:
                existing.value = v
                existing.created_at = datetime.utcnow()
                db.add(existing)
            else:
                nv = CommunityVote(user_id=user.id, comment_id=comment_id, value=v)
                db.add(nv)
            db.commit()

        score = db.query(func.coalesce(func.sum(CommunityVote.value), 0)).filter(CommunityVote.comment_id == comment_id).scalar() or 0
        return jsonify({"status": "ok", "comment_id": comment_id, "vote_score": int(score), "user_vote": v})
    except SQLAlchemyError as e:
        db.rollback()
        current_app.logger.exception("vote_comment error: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


# Update post
@bp.route("/posts/<int:post_id>", methods=["POST", "PUT"])
@token_required
def update_post(post_id: int):
    """
    Update a post's title/body. Owner-only.
    Accepts POST (compatibility) or PUT (RESTful).
    Body JSON: { "title": "...", "body": "..." }
    """
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    data = request.get_json(silent=True) or {}
    title = (data.get("title") or "").strip()
    body = data.get("body")

    if not title:
        return jsonify({"error": "title required"}), 400

    db = SessionLocal()
    try:
        post = db.get(CommunityPost, post_id)
        if not post:
            return jsonify({"error": "Post not found"}), 404
        # owner check
        if post.user_id != user.id:
            return jsonify({"error": "Forbidden"}), 403

        post.title = title
        post.body = body
        db.add(post)
        db.commit()
        db.refresh(post)

        # include same extras as list/get responses for convenience
        extra = {
            "author_name": getattr(post.user, "name", None) or getattr(post.user, "email", None) or "User",
        }
        return jsonify(post.to_dict(extra=extra))
    except Exception as e:
        db.rollback()
        current_app.logger.exception("update_post failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


# Delete post
@bp.route("/posts/<int:post_id>/delete", methods=["POST"])
@token_required
def delete_post_compat(post_id: int):
    """
    Delete a post. Owner-only.
    This endpoint exists to match frontend calls to POST /posts/<id>/delete.
    """
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    db = SessionLocal()
    try:
        post = db.get(CommunityPost, post_id)
        if not post:
            return jsonify({"error": "Post not found"}), 404
        if post.user_id != user.id:
            return jsonify({"error": "Forbidden"}), 403

        db.delete(post)
        db.commit()
        return jsonify({"status": "deleted", "post_id": post_id})
    except Exception as e:
        db.rollback()
        current_app.logger.exception("delete_post_compat failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


# Also provide a RESTful DELETE /posts/<id>
@bp.route("/posts/<int:post_id>", methods=["DELETE"])
@token_required
def delete_post_rest(post_id: int):
    """
    RESTful delete (DELETE /api/community/posts/<id>).
    """
    user = getattr(g, "current_user", None)
    if not user:
        return jsonify({"error": "Authentication required"}), 401

    db = SessionLocal()
    try:
        post = db.get(CommunityPost, post_id)
        if not post:
            return jsonify({"error": "Post not found"}), 404
        if post.user_id != user.id:
            return jsonify({"error": "Forbidden"}), 403

        db.delete(post)
        db.commit()
        return jsonify({"status": "deleted", "post_id": post_id})
    except Exception as e:
        db.rollback()
        current_app.logger.exception("delete_post_rest failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()


import feedparser
import requests
from datetime import datetime
from flask import Blueprint, request, jsonify, current_app, g
from db import SessionLocal
from models import NewsArticle, NewsBookmark
from auth import token_required
from sqlalchemy import or_
import time

news_bp = Blueprint("news_rss", __name__, url_prefix="/api/invest")


DEFAULT_FEEDS = [
    "http://feeds.reuters.com/reuters/businessNews",          # Reuters Business
    "https://finance.yahoo.com/news/rssindex",               # Yahoo Finance news index
    "https://www.marketwatch.com/rss/topstories",            # MarketWatch top stories
    "https://www.cnbc.com/id/100003114/device/rss/rss.html", # CNBC top (may work; many CNBC RSS paths exist)
    # You can add more feeds here. Some websites change URLs; the code is defensive.
]

# Helper to get or create article row by URL
def _get_or_create_article(db, provider, external_id, title, description, url, url_to_image, published_at, content):
    if not url:
        # create a synthetic unique key using title+time if no url (rare)
        url = f"about:missing:{hash(title)}:{int(time.time())}"
    existing = db.query(NewsArticle).filter(NewsArticle.url == url).first()
    if existing:
        # update some fields if changed (best effort)
        changed = False
        if title and existing.title != title:
            existing.title = title; changed = True
        if description is not None and existing.description != description:
            existing.description = description; changed = True
        if url_to_image and existing.url_to_image != url_to_image:
            existing.url_to_image = url_to_image; changed = True
        if published_at and existing.published_at != published_at:
            existing.published_at = published_at; changed = True
        if content and existing.content != content:
            existing.content = content; changed = True
        if changed:
            db.add(existing)
            db.commit()
            db.refresh(existing)
        return existing
    art = NewsArticle(
        provider=provider,
        external_id=external_id,
        title=title or "",
        description=description,
        url=url,
        url_to_image=url_to_image,
        published_at=published_at,
        content=content,
    )
    db.add(art)
    db.commit()
    db.refresh(art)
    return art

def _parse_date(entry):
    # feedparser gives 'published_parsed' as time.struct_time often, and 'published' as a string
    try:
        if getattr(entry, "published_parsed", None):
            return datetime.fromtimestamp(time.mktime(entry.published_parsed))
    except Exception:
        pass
    try:
        if entry.get("published"):
            # try ISO or common formats
            return datetime.fromisoformat(entry.get("published").replace("Z", "+00:00"))
    except Exception:
        pass
    return None

def _feed_to_entries(feed_url, query=None, max_items=20):
    """Fetch feed (or Google News RSS for query) and yield parsed entries (dicts)."""
    # If feed_url is 'google', build Google News RSS search URL using query
    if feed_url == "google_news_search":
        q = request.args.get("q", "finance markets")
        # limit injection/length
        q_enc = requests.utils.requote_uri(q)  # safe encoding
        # google news rss search pattern
        url = f"https://news.google.com/rss/search?q={q_enc}&hl=en-US&gl=US&ceid=US:en"
    else:
        url = feed_url

    try:
        parsed = feedparser.parse(url)
        # feedparser sets 'entries' list
        entries = parsed.get("entries", [])[:max_items]
        out = []
        for e in entries:
            link = e.get("link") or e.get("id") or None
            title = e.get("title") or ""
            description = e.get("summary") or e.get("description") or None
            # image: some feeds put media:content or media_thumbnail
            image = None
            if "media_thumbnail" in e and isinstance(e["media_thumbnail"], list) and e["media_thumbnail"]:
                image = e["media_thumbnail"][0].get("url")
            if not image and "media_content" in e and isinstance(e["media_content"], list) and e["media_content"]:
                image = e["media_content"][0].get("url")
            # published date
            published = _parse_date(e)
            content = None
            if "content" in e and isinstance(e["content"], list) and e["content"]:
                content = e["content"][0].get("value")
            elif "summary" in e:
                content = e.get("summary")
            out.append({
                "title": title,
                "description": description,
                "url": link,
                "url_to_image": image,
                "published_at": published,
                "content": content,
            })
        return out
    except Exception as ex:
        current_app.logger.exception("Feed parse failed for %s: %s", url, ex)
        return []

@news_bp.route("/news", methods=["GET"])
def list_news():
    """
    Aggregate news from RSS sources and return items (with caching).
    Query params:
      q: search keywords (used in Google News RSS query)
      page, page_size
    """
    q = (request.args.get("q") or "finance markets").strip()
    page = max(1, int(request.args.get("page", 1)))
    page_size = max(1, min(100, int(request.args.get("page_size", 20))))

    # We will fetch Google News search results + a few standard feeds, combine,
    # deduplicate by URL, cache into DB and return a page.
    sources = ["google_news_search"] + DEFAULT_FEEDS

    aggregated = []
    seen_urls = set()

    # fetch from each source (limited items per source)
    for src in sources:
        try:
            items = _feed_to_entries(src, query=q, max_items=40)
            for it in items:
                url = it.get("url")
                if not url:
                    continue
                if url in seen_urls:
                    continue
                seen_urls.add(url)
                aggregated.append((src, it))
        except Exception:
            current_app.logger.exception("Failed to fetch source %s", src)
            continue

    # Sort aggregated by published_at desc where available
    def _pub_key(item):
        dt = item[1].get("published_at")
        return dt if dt is not None else datetime.fromtimestamp(0)
    aggregated.sort(key=_pub_key, reverse=True)

    # Persist up to N articles (but don't flood DB on each request — insert only first N missing)
    db = SessionLocal()
    try:
        results = []
        max_persist = 200
        persisted = 0
        for src, it in aggregated:
            if persisted >= max_persist:
                break
            url = it["url"]
            # ensure url is not None
            if not url:
                continue
            # check existing
            existing = db.query(NewsArticle).filter(NewsArticle.url == url).first()
            published_at = it.get("published_at")
            art = None
            if existing:
                art = existing
            else:
                # create
                try:
                    art = _get_or_create_article(db, provider="rss:"+str(src), external_id=None,
                                                 title=it.get("title"), description=it.get("description"),
                                                 url=url, url_to_image=it.get("url_to_image"),
                                                 published_at=published_at, content=it.get("content"))
                    persisted += 1
                except Exception:
                    db.rollback()
                    current_app.logger.exception("Failed to persist article %s", url)
                    continue
            # bookmarked flag for current user (if logged in)
            bookmarked = False
            if getattr(g, "current_user", None):
                bm = db.query(NewsBookmark).filter(NewsBookmark.user_id == g.current_user.id, NewsBookmark.article_id == art.id).first()
                bookmarked = bool(bm)
            d = art.to_dict(include_content=False)
            d["bookmarked"] = bookmarked
            results.append(d)
        # pagination
        total = len(results)
        start = (page - 1) * page_size
        end = start + page_size
        page_items = results[start:end]
        return jsonify({"items": page_items, "source": "rss_aggregated", "totalResults": total})
    finally:
        db.close()

@news_bp.route("/news/<int:article_id>", methods=["GET"])
def get_article(article_id: int):
    db = SessionLocal()
    try:
        art = db.get(NewsArticle, article_id)
        if not art:
            return jsonify({"error": "Not found"}), 404
        bookmarked = False
        if getattr(g, "current_user", None):
            bm = db.query(NewsBookmark).filter(NewsBookmark.user_id == g.current_user.id, NewsBookmark.article_id == art.id).first()
            bookmarked = bool(bm)
        d = art.to_dict(include_content=True)
        d["bookmarked"] = bookmarked
        return jsonify(d)
    finally:
        db.close()

@news_bp.route("/news/bookmark", methods=["POST"])
@token_required
def bookmark_article():
    data = request.get_json() or {}
    article_id = data.get("article_id")
    url = data.get("url")
    if not article_id and not url:
        return jsonify({"error": "article_id or url required"}), 400

    db = SessionLocal()
    try:
        if article_id:
            art = db.get(NewsArticle, int(article_id))
            if not art:
                return jsonify({"error": "Article not found"}), 404
        else:
            # try to fetch metadata for url using requests + feedparser fallback
            try:
                r = requests.get(url, timeout=8)
                # parse HTML title quickly
                title = data.get("title")
                description = data.get("description")
                image = data.get("url_to_image")
                # If no title, try a quick parse via feedparser (feedparser can parse single-page entries)
                if not title:
                    parsed = feedparser.parse(url)
                    if parsed and parsed.get("entries"):
                        e = parsed["entries"][0]
                        title = title or e.get("title")
                        description = description or e.get("summary")
                        if "media_thumbnail" in e and isinstance(e["media_thumbnail"], list) and e["media_thumbnail"]:
                            image = image or e["media_thumbnail"][0].get("url")
                art = _get_or_create_article(db, provider="manual", external_id=None, title=title or url, description=description, url=url, url_to_image=image, published_at=None, content=None)
            except Exception:
                db.rollback()
                current_app.logger.exception("bookmark by url failed for %s", url)
                return jsonify({"error": "failed to fetch url metadata"}), 500
        # create bookmark if missing
        existing = db.query(NewsBookmark).filter(NewsBookmark.user_id == g.current_user.id, NewsBookmark.article_id == art.id).first()
        if existing:
            return jsonify({"status": "already_bookmarked", "bookmark": existing.to_dict()})
        bm = NewsBookmark(user_id=g.current_user.id, article_id=art.id)
        db.add(bm)
        db.commit()
        db.refresh(bm)
        return jsonify({"status": "bookmarked", "bookmark": bm.to_dict()})
    except Exception as e:
        db.rollback()
        current_app.logger.exception("Bookmark failed: %s", e)
        return jsonify({"error": str(e)}), 500
    finally:
        db.close()

@news_bp.route("/news/bookmarks", methods=["GET"])
@token_required
def list_bookmarks():
    db = SessionLocal()
    try:
        rows = db.query(NewsBookmark).filter(NewsBookmark.user_id == g.current_user.id).order_by(NewsBookmark.created_at.desc()).all()
        items = []
        for b in rows:
            a = db.get(NewsArticle, b.article_id)
            items.append({"bookmark": b.to_dict(), "article": a.to_dict(include_content=False) if a else None})
        return jsonify(items)
    finally:
        db.close()

@news_bp.route("/news/bookmarks/<int:bookmark_id>", methods=["DELETE"])
@token_required
def delete_bookmark(bookmark_id: int):
    db = SessionLocal()
    try:
        bm = db.get(NewsBookmark, bookmark_id)
        if not bm or bm.user_id != g.current_user.id:
            return jsonify({"error": "Not found or forbidden"}), 404
        db.delete(bm)
        db.commit()
        return jsonify({"status": "deleted"})
    finally:
        db.close()


from sqlalchemy import Column, Integer, String, Float, Date, DateTime, Text, ForeignKey, UniqueConstraint, Boolean
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from db import Base
from datetime import datetime
import json


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(255), unique=True, nullable=False, index=True)
    name = Column(String(120), nullable=True)
    password_hash = Column(String(255), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    entries = relationship("FinancialEntry", back_populates="user")


class FinancialEntry(Base):
    __tablename__ = "financial_entries"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)

    # Core fields
    entry_type = Column(String(20), nullable=False)  # INCOME | SAVINGS | EXPENSES | INVESTMENTS | DEBT
    category = Column(String(50), nullable=True)
    amount = Column(Float, nullable=False)
    currency = Column(String(8), default="LKR")

    vendor = Column(String(120), nullable=True)
    reference = Column(String(120), nullable=True)
    notes = Column(Text, nullable=True)

    entry_date = Column(Date, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    source = Column(String(20), default="manual")
    raw_text = Column(Text, nullable=True)

    user = relationship("User", back_populates="entries")
    

class CommunityPost(Base):
    __tablename__ = "community_posts"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    title = Column(String(300), nullable=False)
    body = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = relationship("User")

    def to_dict(self, extra=None):
        d = {
            "id": self.id,
            "user_id": self.user_id,
            "title": self.title,
            "body": self.body,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "author_name": getattr(self.user, "name", None) or getattr(self.user, "email", None) or "User",
        }
        if extra:
            d.update(extra)
        return d


class CommunityComment(Base):
    __tablename__ = "community_comments"
    id = Column(Integer, primary_key=True)
    post_id = Column(Integer, ForeignKey("community_posts.id", ondelete="CASCADE"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    body = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = relationship("User")
    post = relationship("CommunityPost")

    def to_dict(self, extra=None):
        d = {
            "id": self.id,
            "post_id": self.post_id,
            "user_id": self.user_id,
            "body": self.body,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "author_name": getattr(self.user, "name", None) or getattr(self.user, "email", None) or "User",
        }
        if extra:
            d.update(extra)
        return d


class CommunityVote(Base):
    """
    Generic vote table. Either post_id or comment_id must be set.
    value: -1 or 1
    """
    __tablename__ = "community_votes"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    post_id = Column(Integer, ForeignKey("community_posts.id", ondelete="CASCADE"), nullable=True, index=True)
    comment_id = Column(Integer, ForeignKey("community_comments.id", ondelete="CASCADE"), nullable=True, index=True)
    value = Column(Integer, nullable=False)  # 1 or -1
    created_at = Column(DateTime, default=datetime.utcnow)

    user = relationship("User")


class InvestmentPlan(Base):
    __tablename__ = "investment_plans"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    goal_name = Column(String(300), nullable=False)
    target_amount = Column(Float, nullable=False)
    horizon_months = Column(Integer, nullable=False)
    risk_profile = Column(String(50), nullable=True)
    expected_annual_return = Column(Float, nullable=True)
    monthly_sip = Column(Float, nullable=True)
    allocation = Column(Text, nullable=True)  # store JSON
    notes = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    def to_dict(self):
        out = {
            "id": self.id,
            "user_id": self.user_id,
            "goal_name": self.goal_name,
            "target_amount": float(self.target_amount or 0.0),
            "horizon_months": self.horizon_months,
            "risk_profile": self.risk_profile,
            "expected_annual_return": float(self.expected_annual_return or 0.0),
            "monthly_sip": float(self.monthly_sip or 0.0),
            "allocation": json.loads(self.allocation) if self.allocation else {},
            "notes": self.notes,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }
        return out


class NewsArticle(Base):
    __tablename__ = "news_articles"
    id = Column(Integer, primary_key=True)
    provider = Column(String(100), nullable=False)            # e.g. 'newsapi'
    external_id = Column(String(255), nullable=True, index=True)  # provider-specific id (if any)
    title = Column(String(1000), nullable=False)
    description = Column(Text, nullable=True)
    url = Column(String(2000), nullable=False, unique=True)
    url_to_image = Column(String(2000), nullable=True)
    published_at = Column(DateTime, nullable=True)
    content = Column(Text, nullable=True)
    fetched_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    bookmarks = relationship("NewsBookmark", back_populates="article", cascade="all, delete-orphan")

    def to_dict(self, include_content=True):
        return {
            "id": self.id,
            "provider": self.provider,
            "external_id": self.external_id,
            "title": self.title,
            "description": self.description,
            "url": self.url,
            "url_to_image": self.url_to_image,
            "published_at": self.published_at.isoformat() if self.published_at else None,
            "content": (self.content if include_content else None),
            "fetched_at": self.fetched_at.isoformat() if self.fetched_at else None,
        }


class NewsBookmark(Base):
    __tablename__ = "news_bookmarks"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    article_id = Column(Integer, ForeignKey("news_articles.id", ondelete="CASCADE"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User")
    article = relationship("NewsArticle", back_populates="bookmarks")

    __table_args__ = (UniqueConstraint("user_id", "article_id", name="uq_user_article_bookmark"),)

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "article_id": self.article_id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }        


class DebtPlan(Base):
    __tablename__ = "debt_plans"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(200), nullable=False)
    vendor = Column(String(200), nullable=True)
    principal = Column(Float, nullable=False)
    annual_interest_pct = Column(Float, nullable=False, default=0.0)  # e.g., 12.5 meaning 12.5% pa
    minimum_payment = Column(Float, nullable=True)  # monthly minimum (optional)
    target_payment = Column(Float, nullable=True)   # monthly payment user intends
    start_date = Column(DateTime, default=datetime.utcnow)
    notes = Column(Text, nullable=True)
    active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = relationship("User")

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "name": self.name,
            "vendor": self.vendor,
            "principal": self.principal,
            "annual_interest_pct": self.annual_interest_pct,
            "minimum_payment": self.minimum_payment,
            "target_payment": self.target_payment,
            "start_date": self.start_date.isoformat() if self.start_date else None,
            "notes": self.notes,
            "active": bool(self.active),
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class DebtAlert(Base):
    __tablename__ = "debt_alerts"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    title = Column(String(300), nullable=False)
    message = Column(Text, nullable=True)
    due_date = Column(DateTime, nullable=True, index=True)          # when payment is due
    amount = Column(Float, nullable=True)                           # optional target amount
    vendor = Column(String(200), nullable=True)                     # optional vendor / creditor
    recurrence = Column(String(32), nullable=True)                  # none | daily | weekly | monthly
    priority = Column(String(32), default="normal")                 # low | normal | high
    acknowledged = Column(Boolean, default=False)                   # user marked done
    last_notified_at = Column(DateTime, nullable=True)              # timestamp when last notification was created
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = relationship("User")

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "title": self.title,
            "message": self.message,
            "due_date": self.due_date.isoformat() if self.due_date else None,
            "amount": self.amount,
            "vendor": self.vendor,
            "recurrence": self.recurrence,
            "priority": self.priority,
            "acknowledged": bool(self.acknowledged),
            "last_notified_at": self.last_notified_at.isoformat() if self.last_notified_at else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }



class DebtBadge(Base):
    __tablename__ = "debt_badges"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    badge_key = Column(String(100), nullable=False)
    title = Column(String(200), nullable=False)
    description = Column(Text, nullable=True)
    earned_at = Column(DateTime, default=datetime.utcnow)

    user = relationship("User")

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "badge_key": self.badge_key,
            "title": self.title,
            "description": self.description,
            "earned_at": self.earned_at.isoformat() if self.earned_at else None,
        }


class DebtChatMessage(Base):
    __tablename__ = "debt_chat_messages"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    role = Column(String(20), nullable=False)  # 'user' or 'assistant' or 'system'
    content = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    user = relationship("User")

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "role": self.role,
            "content": self.content,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


from typing import Optional, Dict, List
import re

# Normalize helper
def _norm(s: Optional[str]) -> str:
    return (s or "").lower().strip()

# Pattern groups with weights and labels
# Higher weight -> stronger evidence
# Each item: (compiled_regex, weight, human_label)
_INCOME_PATTERNS = [
    (re.compile(r"\b(salary|salary credit|payroll|payroll deposit|payroll credit|pay check|paycheck|pay roll|wage|wages)\b", re.I), 3.0, "salary/payroll"),
    (re.compile(r"\b(direct deposit|direct-deposit|directdeposit|deposit received|payment received|credited|credited to)\b", re.I), 2.5, "direct deposit/credit"),
    (re.compile(r"\b(pension|pension payment|annuity)\b", re.I), 2.5, "pension/annuity"),
    (re.compile(r"\b(interest|interest credited|interest paid|dividend|dividends)\b", re.I), 2.5, "interest/dividend"),
    (re.compile(r"\b(refund|rebate|cashback|reimburs(e|ed)|reimbursement)\b", re.I), 2.0, "refund/rebate/cashback"),
    (re.compile(r"\b(received|payment received|amount received)\b", re.I), 1.8, "received/payment received"),
    (re.compile(r"\b(salary payment|salary transfer)\b", re.I), 3.0, "salary/transfer"),
]

# Deposit-specific patterns (helpful when vendor is "Bank Transfer" text)
_DEPOSIT_PATTERNS = [
    (re.compile(r"\b(credited|credit)\b", re.I), 1.5, "credited"),
    (re.compile(r"\b(deposit|deposited)\b", re.I), 1.5, "deposit"),
]

_INVESTMENT_PATTERNS = [
    (re.compile(r"\b(stock|shares|brokerage|trade|bought|sold|mutual fund|etf|ipo|dividend reinvestment|dividend reinvest)\b", re.I), 2.5, "stock/mutual/etf"),
    (re.compile(r"\b(capital gain|capital gains|gain on sale|sell order|buy order)\b", re.I), 2.5, "capital gain / trade"),
    (re.compile(r"\b(broker|brokerage|clearing|settlement)\b", re.I), 1.8, "brokerage"),
    (re.compile(r"\b(crypto|bitcoin|ethereum|coin)\b", re.I), 2.5, "crypto"),
]

_DEBT_PATTERNS = [
    (re.compile(r"\b(loan payment|loan instalment|loan installment|emi|installment|repayment)\b", re.I), 2.8, "loan/emi"),
    (re.compile(r"\b(mortgage|mortgage payment)\b", re.I), 3.0, "mortgage"),
    (re.compile(r"\b(credit card|creditcard|cc payment|card payment|card auth|card ending)\b", re.I), 2.2, "credit card"),
    (re.compile(r"\b(overdue|due|arrears|past due)\b", re.I), 2.0, "overdue/due"),
]

_SAVINGS_PATTERNS = [
    (re.compile(r"\b(savings transfer|transfer to savings|transfer to saver|save to)\b", re.I), 2.5, "transfer to savings"),
    (re.compile(r"\b(savings account|savings deposit|fixed deposit|fd|term deposit)\b", re.I), 2.5, "savings/fixed deposit"),
    (re.compile(r"\b(auto save|save)\b", re.I), 1.2, "save"),
]

_EXPENSE_PATTERNS = [
    (re.compile(r"\b(total|grand total|amount due|amount paid|subtotal)\b", re.I), 1.5, "total/amount paid"),
    (re.compile(r"\b(invoice|tax|gst|vat|service charge|shipping|delivery)\b", re.I), 1.8, "invoice/taxes/fees"),
    # merchant-style patterns: store name followed by amount or card details e.g. "WALMART 1234"
    (re.compile(r"\b(card|card transaction|card payment|card auth|card ending|authorization)\b", re.I), 1.8, "card transaction"),
    (re.compile(r"\b(merchant|store|shop|supermarket|restaurant|cafe|hotel|uber|dine|eat|dinner|lunch|coffee|bar)\b", re.I), 1.5, "merchant/retail"),
    (re.compile(r"\b(paid to|paid at|paid)\b", re.I), 1.4, "paid"),
]

# Generic vendor patterns that sometimes indicate income (e.g., "DIRECT DEPOSIT - ACME CORP")
_VENDOR_INCOME_PATTERNS = [
    (re.compile(r"\b(direct deposit|deposit from|transfer from|payment from)\b", re.I), 2.0, "transfer from"),
]

# Fallback keywords (lowercase)
_INCOME_KEYWORDS = ["salary", "payroll", "pension", "interest", "dividend", "bonus", "refund", "rebate", "cashback", "commission", "royalty"]
_INVESTMENT_KEYWORDS = ["stock", "mutual", "etf", "broker", "dividend", "crypto", "bitcoin"]
_DEBT_KEYWORDS = ["loan", "mortgage", "emi", "installment", "installment", "credit card", "arrears"]
_SAVINGS_KEYWORDS = ["savings", "fixed deposit", "fd", "term deposit"]

# Utility: run pattern list against text, return score and reasons
def _apply_patterns(text: str, patterns) -> (float, List[str]):
    score = 0.0
    reasons: List[str] = []
    if not text:
        return score, reasons
    for regex, weight, label in patterns:
        if regex.search(text):
            score += weight
            reasons.append(label)
    return score, reasons

# Main detailed guess function
def guess_type_detailed(vendor: Optional[str], raw_text: Optional[str], amount: Optional[float] = None) -> Dict:
    """
    Return a dict with:
      - type: one of INCOME,SAVINGS,EXPENSES,INVESTMENTS,DEBT
      - confidence: float 0..1 (higher = stronger separation)
      - reasons: list of human-readable signals found
    """
    v = _norm(vendor)
    r = _norm(raw_text)

    # aggregate per-category scores and reasons
    scores = {
        "INCOME": 0.0,
        "INVESTMENTS": 0.0,
        "DEBT": 0.0,
        "SAVINGS": 0.0,
        "EXPENSES": 0.0,
    }
    reasons = {k: [] for k in scores.keys()}

    # Income patterns
    s, rs = _apply_patterns(v + "\n" + r, _INCOME_PATTERNS)
    scores["INCOME"] += s
    reasons["INCOME"].extend(rs)

    # Deposit phrases (helpful to strengthen income)
    s, rs = _apply_patterns(v + "\n" + r, _DEPOSIT_PATTERNS)
    scores["INCOME"] += s * 0.8  # weaker but supportive
    reasons["INCOME"].extend(rs)

    # Vendor-level direct deposit patterns
    s, rs = _apply_patterns(v, _VENDOR_INCOME_PATTERNS)
    scores["INCOME"] += s
    reasons["INCOME"].extend(rs)

    # Investments
    s, rs = _apply_patterns(v + "\n" + r, _INVESTMENT_PATTERNS)
    scores["INVESTMENTS"] += s
    reasons["INVESTMENTS"].extend(rs)

    # Debt
    s, rs = _apply_patterns(v + "\n" + r, _DEBT_PATTERNS)
    scores["DEBT"] += s
    reasons["DEBT"].extend(rs)

    # Savings
    s, rs = _apply_patterns(v + "\n" + r, _SAVINGS_PATTERNS)
    scores["SAVINGS"] += s
    reasons["SAVINGS"].extend(rs)

    # Expenses (merchant/total)
    s, rs = _apply_patterns(v + "\n" + r, _EXPENSE_PATTERNS)
    scores["EXPENSES"] += s
    reasons["EXPENSES"].extend(rs)

    # Heuristic: merchant-like vendor (store names) -> expense
    if v and re.search(r"\b(store|supermarket|shop|mart|restaurant|cafe|hotel|dining|bar|restaurant|restaurant|market|bakery)\b", v, re.I):
        scores["EXPENSES"] += 1.2
        reasons["EXPENSES"].append("merchant vendor detected")

    # If raw_text contains "paid to" or "paid at" - expense
    if re.search(r"\b(paid to|paid at|payment to|amount paid)\b", r, re.I):
        scores["EXPENSES"] += 1.2
        reasons["EXPENSES"].append("paid/amount paid phrase")

    # Amount heuristics:
    # - very small positive amounts may be fees/refunds, but not used here
    # - negative-looking amounts in OCR (e.g., '-50') -> likely expense (if present in raw_text)
    if raw_text and re.search(r"[-−]\s*\d+(\.\d+)?", raw_text):
        scores["EXPENSES"] += 1.6
        reasons["EXPENSES"].append("negative amount detected (likely expense)")

    # Keywords fallback checks (low weight)
    for kw in _INCOME_KEYWORDS:
        if kw in v or kw in r:
            scores["INCOME"] += 0.4
            reasons["INCOME"].append(f"keyword:{kw}")
    for kw in _INVESTMENT_KEYWORDS:
        if kw in v or kw in r:
            scores["INVESTMENTS"] += 0.4
            reasons["INVESTMENTS"].append(f"keyword:{kw}")
    for kw in _DEBT_KEYWORDS:
        if kw in v or kw in r:
            scores["DEBT"] += 0.4
            reasons["DEBT"].append(f"keyword:{kw}")
    for kw in _SAVINGS_KEYWORDS:
        if kw in v or kw in r:
            scores["SAVINGS"] += 0.4
            reasons["SAVINGS"].append(f"keyword:{kw}")

    # If nothing matches strongly, lean on "EXPENSES" default
    # But allow INCOME detection from weak signals + deposit phrase
    # Compute final selection
    # Sum up scores and find max
    max_type = None
    max_score = -1.0
    total_score = 0.0
    for k, sc in scores.items():
        total_score += max(0.0, sc)
        if sc > max_score:
            max_score = sc
            max_type = k

    # defensive fallback
    if max_type is None:
        max_type = "EXPENSES"
        max_score = 0.0

    # Calculate a confidence measure: how separated the max score is from the runner-up
    # Find runner-up
    runner_up = 0.0
    for k, sc in scores.items():
        if k == max_type:
            continue
        if sc > runner_up:
            runner_up = sc

    # If both are zero, confidence small; else compute separation ratio
    # confidence ∈ [0,1]; formula: (max - runner_up) / (max + runner_up + 1e-6)
    if max_score + runner_up <= 1e-9:
        confidence = 0.15  # very low confidence
    else:
        confidence = (max_score - runner_up) / (max_score + runner_up + 1e-9)
        # normalize into [0.05, 0.99] roughly
        if confidence < 0.05:
            confidence = 0.05
        if confidence > 0.99:
            confidence = 0.99

    # Also boost confidence if max_score is fairly strong (> ~3.0)
    if max_score >= 4.5:
        confidence = max(confidence, 0.9)
    elif max_score >= 3.0:
        confidence = max(confidence, 0.75)
    elif max_score >= 1.5:
        confidence = max(confidence, 0.5)

    # return human-readable reasons (dedupe)
    dedup_reasons = []
    seen = set()
    for rlabel in reasons.get(max_type, []):
        if rlabel not in seen:
            dedup_reasons.append(rlabel)
            seen.add(rlabel)

    return {
        "type": max_type,
        "confidence": round(float(confidence), 3),
        "score": round(float(max_score), 3),
        "runner_up_score": round(float(runner_up), 3),
        "reasons": dedup_reasons,
        "raw_scores": {k: round(float(v), 3) for k, v in scores.items()},
    }

# Backwards-compatible function
def guess_type(vendor: Optional[str], raw_text: Optional[str], amount: Optional[float] = None) -> str:
    d = guess_type_detailed(vendor, raw_text, amount)
    return d["type"]


import re
from dateutil import parser as dateparser
from typing import Optional, Dict

AMOUNT_PAT = re.compile(r"(?i)(total|amount|balance|paid|subtotal)[:\s]*([+-]?[\d.,]+)")
CURRENCY_PAT = re.compile(r"(?i)\b(LKR|USD|EUR|GBP|INR|AUD|CAD|JPY|CNY|SGD)\b")
DATE_PAT = re.compile(r"(?i)(\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})")
REF_PAT = re.compile(r"(?i)(invoice|receipt|ref|reference|bill)\s*#?\s*([A-Za-z0-9-]+)")

def safe_parse_date(text: str) -> Optional[str]:
    try:
        dt = dateparser.parse(text, dayfirst=True, fuzzy=True)
        return dt.date().isoformat()
    except Exception:
        return None

def parse_ocr_text(raw_text: str) -> Dict:
    # Vendor heuristic: first non-empty line that isn't clearly header
    lines = [ln.strip() for ln in raw_text.splitlines() if ln.strip()]
    vendor = lines[0] if lines else None

    # Amount
    amount = None
    for m in AMOUNT_PAT.finditer(raw_text):
        val = m.group(2).replace(",", "")
        try:
            amount = float(val)
        except ValueError:
            continue
    # Currency
    currency = "LKR"
    c = CURRENCY_PAT.search(raw_text)
    if c:
        currency = c.group(1).upper()

    # Date
    entry_date = None
    for m in DATE_PAT.finditer(raw_text):
        iso = safe_parse_date(m.group(0))
        if iso:
            entry_date = iso
            break

    # Reference
    ref = None
    r = REF_PAT.search(raw_text)
    if r:
        ref = r.group(2)

    return {
        "vendor": vendor,
        "amount": amount,
        "currency": currency,
        "entry_date": entry_date,
        "reference": ref,
        "raw_text": raw_text,
    }

import cv2
import pytesseract
from PIL import Image
import numpy as np
from typing import Tuple

# set tesseract cmd path on Windows if needed
# pytesseract.pytesseract.tesseract_cmd = r"C:\\Program Files\\Tesseract-OCR\\tesseract.exe"
# need to install tesseract ocr globally

def preprocess(image_path: str) -> np.ndarray:
    img = cv2.imdecode(np.fromfile(image_path, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        img = cv2.imread(image_path)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    # Denoise & threshold
    blur = cv2.GaussianBlur(gray, (3, 3), 0)
    th = cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY, 25, 15)
    return th

def extract_text(image_path: str) -> str:
    proc = preprocess(image_path)
    # OCR config for receipts
    config = "--oem 3 --psm 6"
    text = pytesseract.image_to_string(proc, config=config)
    return text

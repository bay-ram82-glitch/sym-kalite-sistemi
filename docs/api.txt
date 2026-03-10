# -*- coding: utf-8 -*-
"""
PC tarafında çalışan Flask API.
- Excel: C:\\kalite_api\\veri.xlsx

Endpointler:
- GET  /where
- GET  /config
- POST /config
- GET  /models
- GET  /kontrol-processleri
- GET  /kontrol-turleri
- GET  /vin-lookup?vin=...(&testPath=...)
- POST /submit-report          -> PDF üretir (kaliteReportsDir içine)
- POST /label-zpl              -> ZPL üretir
- POST /print-label (opsiyonel)-> ZPL'i yazıcıya RAW basar (pywin32 gerekir)
"""

import json
import os
import socket
import sqlite3
import pandas as pd

from pathlib import Path
from typing import Any, Dict, List, Tuple
from datetime import datetime

from flask import Flask, jsonify, request, redirect
from openpyxl import load_workbook

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

from reportlab.platypus import (
    SimpleDocTemplate,
    Table,
    TableStyle,
    Paragraph,
    Spacer,
    Image,
    Flowable,
    PageBreak,
)

# -------------------------
# Paths / Defaults
# -------------------------
APP_DIR = Path(__file__).resolve().parent
CONFIG_PATH = APP_DIR / "config.json"

DB_PATH = APP_DIR / "kalite.db"

EXCEL_PATH = r"C:\kalite_api\veri.xlsx"

DEFAULT_TEST_REPORTS_DIR = r"C:\TEST_RAPORLARI"
DEFAULT_KALITE_REPORTS_DIR = r"C:\KALITE_RAPORLARI"

DEFAULT_ISO = {
    "isoPublishDate": "21.08.2024",
    "isoFormNo": "FR-054",
    "isoRevNo": "03",
    "isoRevDate": "02.01.2026",
}

DEFAULT_CFG = {
    "testReportsDir": DEFAULT_TEST_REPORTS_DIR,
    "kaliteReportsDir": DEFAULT_KALITE_REPORTS_DIR,
    "labelMode": "zpl",
    "printerName": "",
    "logoPath": "",  # ✅ PC'den okunacak logo dosya yolu (örn: C:\\kalite_api\\assets\\logo.png)
    **DEFAULT_ISO,
}


def get_conn():
    conn = sqlite3.connect("kalite.db", timeout=30)
    conn.row_factory = sqlite3.Row
    return conn

# -------------------------
# Türkçe font (kutucuk sorununu çözer)
# -------------------------
FONTS_DIR = APP_DIR / "fonts"
FONT_REGULAR = FONTS_DIR / "DejaVuSans.ttf"
FONT_BOLD = FONTS_DIR / "DejaVuSans-Bold.ttf"
_FONTS_REGISTERED = False


def register_tr_fonts() -> None:
    """Fontları 1 kere register et. Dosyalar yoksa net hata ver."""
    global _FONTS_REGISTERED
    if _FONTS_REGISTERED:
        return

    if not FONT_REGULAR.exists() or not FONT_BOLD.exists():
        raise FileNotFoundError(
            "Türkçe font bulunamadı.\n"
            "Şu dosyaları api.py ile aynı klasördeki fonts klasörüne koy:\n"
            f"- {FONT_REGULAR}\n"
            f"- {FONT_BOLD}\n"
        )

    pdfmetrics.registerFont(TTFont("TR", str(FONT_REGULAR)))
    pdfmetrics.registerFont(TTFont("TRB", str(FONT_BOLD)))
    _FONTS_REGISTERED = True


# -------------------------
# Flask
# -------------------------
app = Flask(__name__)

# -------------------------
# Config helpers
# -------------------------
def load_config() -> Dict[str, Any]:
    cfg = dict(DEFAULT_CFG)
    if CONFIG_PATH.exists():
        try:
            loaded = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                cfg.update(loaded)
        except Exception:
            pass
    return cfg


def save_config(cfg: Dict[str, Any]) -> None:
    CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")


def get_test_reports_dir() -> str:
    cfg = load_config()
    p = str(cfg.get("testReportsDir") or "").strip()
    return p or DEFAULT_TEST_REPORTS_DIR


def get_kalite_reports_dir() -> str:
    cfg = load_config()
    p = str(cfg.get("kaliteReportsDir") or "").strip()
    return p or DEFAULT_KALITE_REPORTS_DIR


# -------------------------
# Photo storage (tablet upload)
# -------------------------
def get_photos_base_dir() -> Path:
    '''
    Fotoğraflar, kaliteReportsDir altında saklanır:
      <kaliteReportsDir>/_photos/<VIN>/<siraNo>.jpg
    '''
    base = Path(get_kalite_reports_dir()) / "_photos"
    base.mkdir(parents=True, exist_ok=True)
    return base


def get_vin_photo_dir(vin: str) -> Path:
    vin_up = (vin or "").strip().upper() or "VIN"
    d = get_photos_base_dir() / vin_up
    d.mkdir(parents=True, exist_ok=True)
    return d


def find_latest_photo_for_vin(vin: str) -> str:
    '''
    Eğer birden fazla foto varsa, en yüksek siraNo'lu jpg'i döndürür.
    (Dosya adı: 1.jpg, 2.jpg, 35.jpg gibi)
    '''
    d = Path(get_kalite_reports_dir()) / "_photos" / (vin or "").strip().upper()
    if not d.exists():
        return ""
    best_p = None
    best_no = -1
    for p in d.glob("*.jpg"):
        try:
            no = int(p.stem.strip().split("_")[-1])
        except Exception:
            no = -1
        if no > best_no:
            best_no = no
            best_p = p
    return str(best_p) if best_p else ""


# ✅ VIN için tüm fotoğrafları sıra no'ya göre döndür
def get_all_photos_for_vin(vin: str) -> List[str]:
    """
    <kaliteReportsDir>/_photos/<VIN>/<siraNo>.jpg dosyalarını siraNo'ya göre sıralı döndürür.
    """
    d = Path(get_kalite_reports_dir()) / "_photos" / (vin or "").strip().upper()
    if not d.exists():
        return []

    photos: List[Tuple[int, str]] = []
    for p in d.glob("*.jpg"):
        try:
            no = int(p.stem.strip())
        except Exception:
            no = 0
        photos.append((no, str(p)))

    photos.sort(key=lambda x: x[0])
    return [p for _, p in photos]


# -------------------------
# Excel helpers
# -------------------------
def open_wb():
    if not Path(EXCEL_PATH).exists():
        raise FileNotFoundError(f"Excel bulunamadı: {EXCEL_PATH}")
    return load_workbook(EXCEL_PATH, data_only=True)


def norm(s: Any) -> str:
    return str(s or "").strip().lower().replace("ı", "i").replace("İ", "i")


def pick_col(row_values: List[Any], wanted: List[str]) -> int:
    headers = [norm(v) for v in row_values]
    wanted_norm = [norm(w) for w in wanted]
    for wi in wanted_norm:
        if wi in headers:
            return headers.index(wi)
    return -1


def vin_to_prefix_seri(vin: str) -> Tuple[str, int]:
    vin = (vin or "").strip().upper()
    if len(vin) != 17:
        raise ValueError("VIN 17 karakter olmalı")
    prefix = vin[:12]
    try:
        seri = int(vin[-5:])
    except Exception:
        raise ValueError("VIN son 5 karakter sayısal olmalı")
    return prefix, seri


def find_model_parti(prefix: str, seri: int) -> Tuple[str, str]:
    wb = open_wb()
    try:
        ws = wb["ŞASE VE PARTİ NO"]
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            raise ValueError("ŞASE VE PARTİ NO sayfası boş")

        header = list(rows[0])
        i_prefix = pick_col(header, ["PREFIX", "prefix"])
        i_start = pick_col(header, ["START", "start", "SERIBAS", "SERI BAS", "BASLANGIC", "Başlangıç"])
        i_end = pick_col(header, ["END", "end", "SERIBIT", "SERI BIT", "BITIS", "Bitiş"])
        i_model = pick_col(header, ["MODEL", "model"])
        i_parti = pick_col(header, ["PARTİ", "PARTI", "PARTI NO", "PARTI NO.", "PARTINO", "PARTİNO", "Parti No"])

        if min(i_prefix, i_start, i_end, i_model, i_parti) < 0:
            raise ValueError("ŞASE VE PARTİ NO başlıkları beklenen formatta değil")

        for r in rows[1:]:
            if not r:
                continue
            rp = str(r[i_prefix] or "").strip()
            if rp != prefix:
                continue

            try:
                s_start = int(str(r[i_start] or "").strip())
                s_end = int(str(r[i_end] or "").strip())
            except Exception:
                continue

            if s_start <= seri <= s_end:
                model = str(r[i_model] or "").strip()
                parti = str(r[i_parti] or "").strip()
                if model:
                    return model, parti

        raise ValueError("VIN aralığı bulunamadı")
    finally:
        wb.close()


def get_renkler_for_model(model: str) -> List[Dict[str, str]]:
    wb = open_wb()
    try:
        ws = wb["MODEL RENK VE KOD"]
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            return []

        header = list(rows[0])
        i_model = pick_col(header, ["MODEL", "model"])
        i_renk = pick_col(header, ["RENK", "renk", "Renk"])
        i_stok = pick_col(header, ["STOK KODU", "stok kodu", "STOK", "Stok", "stok"])

        if min(i_model, i_renk, i_stok) < 0:
            raise ValueError("MODEL RENK VE KOD başlıkları beklenen formatta değil")

        out: List[Dict[str, str]] = []
        for r in rows[1:]:
            if not r:
                continue
            rm = str(r[i_model] or "").strip()
            if rm.lower() != model.lower():
                continue
            renk = str(r[i_renk] or "").strip()
            stok = str(r[i_stok] or "").strip()
            if renk or stok:
                out.append({"renk": renk, "stokKodu": stok})

        return out
    finally:
        wb.close()


def list_models_unique() -> List[str]:
    wb = open_wb()
    try:
        ws = wb["MODEL RENK VE KOD"]
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            return []

        header = list(rows[0])
        i_model = pick_col(header, ["MODEL", "model"])
        if i_model < 0:
            raise ValueError("MODEL RENK VE KOD içinde Model sütunu bulunamadı")

        seen = set()
        out: List[str] = []
        for r in rows[1:]:
            if not r:
                continue
            m = str(r[i_model] or "").strip()
            if not m:
                continue
            k = m.lower()
            if k in seen:
                continue
            seen.add(k)
            out.append(m)

        out.sort(key=lambda s: s.lower())
        return out
    finally:
        wb.close()


def kontrol_processleri() -> List[Dict[str, Any]]:
    wb = open_wb()
    try:
        ws = wb["Kontrol Processleri"]
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            return []

        header = list(rows[0])
        i_sira = pick_col(header, ["SIRA", "Sıra No", "SIRA NO", "sira", "no"])
        i_proc = pick_col(header, ["PROCESS", "Process", "process", "PROSESLER", "Prosesler"])
        i_tur = pick_col(header, ["KONTROL TÜRÜ", "Kontrol Türü", "Kontrol Turu", "kontrol turu", "kontrol"])

        if min(i_sira, i_proc, i_tur) < 0:
            raise ValueError("Kontrol Processleri başlıkları beklenen formatta değil")

        out: List[Dict[str, Any]] = []
        for r in rows[1:]:
            if not r:
                continue
            sira_s = str(r[i_sira] or "").strip()
            proc = str(r[i_proc] or "").strip()
            tur = str(r[i_tur] or "").strip()

            try:
                sira_i = int(sira_s)
            except Exception:
                sira_i = 0

            if sira_i > 0 and proc and tur:
                out.append({"siraNo": sira_i, "process": proc, "kontrolTuru": tur})

        out.sort(key=lambda x: x["siraNo"])
        return out
    finally:
        wb.close()


def test_raporu_var_mi(vin: str, override_dir: str = "") -> bool:

    import os

    base = (override_dir or "").strip() or get_test_reports_dir()

    print("ARAMA KLASÖRÜ:", base)

    if not os.path.exists(base):
        print("KLASÖR YOK")
        return False

    print("KLASÖRDEKİ DOSYALAR:")

    for f in os.listdir(base):
        print("DOSYA:", f)

        if vin.upper() in f.upper():
            print("EŞLEŞME BULUNDU:", f)
            return True

    print("PDF BULUNAMADI")
    return False

def get_hatalar_index() -> List[Dict[str, Any]]:
    wb = open_wb()
    try:
        ws = wb["Hatalar İndex"]
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            return []

        header = list(rows[0])

        i_parca = pick_col(header, ["PARÇA", "Parça", "parca"])
        i_aciklama = pick_col(header, ["HATA AÇIKLAMASI", "Hata Açıklaması"])
        i_tur = pick_col(header, ["TÜR", "Tür"])
        i_seviye = pick_col(header, ["SEVİYE", "Seviye"])
        i_kaynak = pick_col(header, ["KAYNAK", "Kaynak"])
        i_istasyon = pick_col(header, ["İSTASYON", "İstasyon"])
        i_kontrol = pick_col(header, ["KONTROL MADDELERI", "Kontrol Maddeleri"])

        out: List[Dict[str, Any]] = []

        for r in rows[1:]:
            if not r:
                continue

            out.append({
                "parca": str(r[i_parca] or "").strip(),
                "aciklama": str(r[i_aciklama] or "").strip(),
                "tur": str(r[i_tur] or "").strip(),
                "seviye": str(r[i_seviye] or "").strip(),
                "kaynak": str(r[i_kaynak] or "").strip(),
                "istasyon": str(r[i_istasyon] or "").strip(),
                "kontrolAdi": str(r[i_kontrol] or "").strip(),
            })

        return out
    finally:
        wb.close()

def sync_kontroller_from_excel():
    conn = get_conn()
    cur = conn.cursor()

    items = kontrol_processleri()
    print("Excelden gelen:", items)

    # tabloyu temizle
    cur.execute("DELETE FROM kontroller")

    for it in items:
        cur.execute("""
            INSERT INTO kontroller (sira_no, kontrol_adi)
            VALUES (?, ?)
        """, (
            it.get("siraNo"),
            it.get("process"),
        ))

    conn.commit()
    conn.close()

def get_kontrol_id_by_name(kontrol_adi: str):
    conn = get_conn()
    cur = conn.cursor()

    cur.execute("""
        SELECT id FROM kontroller
        WHERE LOWER(TRIM(kontrol_adi)) = LOWER(TRIM(?))
        LIMIT 1
    """, (kontrol_adi,))

    row = cur.fetchone()
    conn.close()

    return row["id"] if row else None

# -------------------------
# PDF helpers
# -------------------------
def _get_logo_path_from_cfg(cfg: Dict[str, Any]) -> str:
    p = str(cfg.get("logoPath") or "").strip()
    if not p:
        return ""
    try:
        if os.path.exists(p) and os.path.isfile(p):
            return p
    except Exception:
        pass
    return ""


class IsoBox(Flowable):
    def __init__(self, cfg: Dict[str, Any], width: float, height: float, border: float = 1.0):
        super().__init__()
        self.cfg = cfg
        self.width = width
        self.height = height
        self.border = border
        self.rows = [
            ("YAYIN TARİHİ", str(cfg.get("isoPublishDate", ""))),
            ("FORM NO", str(cfg.get("isoFormNo", ""))),
            ("REV NO", str(cfg.get("isoRevNo", ""))),
            ("REV. TARİHİ", str(cfg.get("isoRevDate", ""))),
        ]

    def wrap(self, availWidth, availHeight):
        return self.width, self.height

    def draw(self):
        c = self.canv
        w = self.width
        h = self.height

        rows = 4
        row_h = h / rows
        split_x = 0.60 * w

        c.setLineWidth(self.border)

        c.line(split_x, 0, split_x, h)
        for i in range(1, rows):
            y = i * row_h
            c.line(0, y, w, y)

        pad_x = 2.0 * mm
        for idx, (k, v) in enumerate(self.rows):
            y_top = h - (idx * row_h)
            y_mid = y_top - row_h / 2

            c.setFont("TRB", 8.7)
            c.drawString(pad_x, y_mid - 3, k)

            c.setFont("TRB", 8.7)
            text_w = c.stringWidth(v, "TRB", 8.7)
            vx0 = split_x + (w - split_x - text_w) / 2
            c.drawString(vx0, y_mid - 3, v)


def _story_height(flowables: List[Flowable], doc: SimpleDocTemplate) -> float:
    total = 0.0
    for f in flowables:
        try:
            _, h = f.wrap(doc.width, doc.height)
        except Exception:
            h = getattr(f, "height", 0.0) or 0.0
        total += float(h or 0.0)
    return total


def _draw_photo_box(canv, doc: SimpleDocTemplate, border: float, height: float, photo_path: str = "") -> None:
    if height <= 0:
        return

    x = float(doc.leftMargin)
    y = float(doc.bottomMargin)
    w = float(doc.width)
    h = float(height)

    canv.saveState()
    canv.setLineWidth(border)
    canv.setStrokeColor(colors.black)
    canv.setFillColor(colors.white)
    canv.rect(x, y, w, h, stroke=1, fill=0)

    if photo_path:
        try:
            if os.path.exists(photo_path) and os.path.isfile(photo_path):
                img = ImageReader(photo_path)
                iw, ih = img.getSize()
                pad = 1.5 * mm
                aw = max(1.0, w - 2 * pad)
                ah = max(1.0, h - 2 * pad)
                scale = min(aw / float(iw), ah / float(ih))
                dw = float(iw) * scale
                dh = float(ih) * scale
                dx = x + pad + (aw - dw) / 2.0
                dy = y + pad + (ah - dh) / 2.0
                canv.drawImage(img, dx, dy, width=dw, height=dh, preserveAspectRatio=True, mask='auto')
                canv.restoreState()
                return
        except Exception:
            pass

    canv.setFillColor(colors.lightgrey)
    canv.setFont("TRB", 22)
    canv.drawCentredString(x + w / 2.0, y + (h / 2.0) - 7, "FOTOĞRAF")
    canv.restoreState()


# -------------------------
# PDF (Şablon - 35 satır)
# -------------------------
def build_submit_report_pdf(data: Dict[str, Any]) -> str:
    register_tr_fonts()

    cfg = load_config()
    report_dir = get_kalite_reports_dir()
    os.makedirs(report_dir, exist_ok=True)

    vin = str(data.get("vin") or "VIN").strip().upper()

    # ✅ tek foto yerine tüm foto listesi
    photo_list = get_all_photos_for_vin(vin)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    file_name = f"FR054_KK_{vin}_{ts}.pdf"
    pdf_path = os.path.join(report_dir, file_name)

    BORDER = 1

    s_title = ParagraphStyle("title", fontName="TRB", fontSize=14, leading=16, alignment=TA_CENTER)
    s_info_lbl = ParagraphStyle("info_lbl", fontName="TRB", fontSize=8.6, leading=9.6, alignment=TA_LEFT)
    s_info_val = ParagraphStyle("info_val", fontName="TR", fontSize=8.6, leading=9.6, alignment=TA_LEFT)

    s_head = ParagraphStyle("thead", fontName="TRB", fontSize=8.2, leading=9.0, alignment=TA_CENTER)
    s_cell = ParagraphStyle("cell", fontName="TR", fontSize=7.6, leading=8.2, alignment=TA_LEFT)
    s_cell_c = ParagraphStyle("cellc", fontName="TR", fontSize=7.6, leading=8.2, alignment=TA_CENTER)

    s_ok = ParagraphStyle("ok", fontName="TRB", fontSize=10.0, leading=10.0, alignment=TA_CENTER, textColor=colors.green)
    s_nok = ParagraphStyle("nok", fontName="TRB", fontSize=10.0, leading=10.0, alignment=TA_CENTER, textColor=colors.red)
    s_small = ParagraphStyle("small", fontName="TR", fontSize=7.0, leading=7.8, alignment=TA_LEFT)

    # ------- Logo Flowable -------
    logo_flow = Spacer(1, 1)
    logo_path = _get_logo_path_from_cfg(cfg)
    if logo_path:
        try:
            img = Image(logo_path)
            img.drawWidth = 36 * mm
            img.drawHeight = 18 * mm
            logo_flow = img
        except Exception:
            logo_flow = Spacer(1, 1)

    # ------- ISO Box -------
    iso_w = 54 * mm
    iso_h = 22 * mm
    iso_box = IsoBox(cfg, width=iso_w, height=iso_h, border=BORDER)

    title = Paragraph("ÜRETİM SONU KALİTE KONTROL FORMU", s_title)

    header_tbl = Table(
        [[logo_flow, title, iso_box]],
        colWidths=[40 * mm, 115 * mm, iso_w],
        rowHeights=[iso_h],
    )
    header_tbl.setStyle(TableStyle([
        ("BOX", (0, 0), (-1, -1), BORDER, colors.black),
        ("LINEAFTER", (0, 0), (0, 0), BORDER, colors.black),
        ("LINEAFTER", (1, 0), (1, 0), BORDER, colors.black),

        ("ALIGN", (0, 0), (0, 0), "CENTER"),
        ("VALIGN", (0, 0), (0, 0), "MIDDLE"),

        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (1, 0), (1, 0), "CENTER"),

        ("LEFTPADDING", (2, 0), (2, 0), 0),
        ("RIGHTPADDING", (2, 0), (2, 0), 0),
        ("TOPPADDING", (2, 0), (2, 0), 0),
        ("BOTTOMPADDING", (2, 0), (2, 0), 0),

        ("LEFTPADDING", (0, 0), (1, 0), 1.2 * mm),
        ("RIGHTPADDING", (0, 0), (1, 0), 1.2 * mm),
        ("TOPPADDING", (0, 0), (1, 0), 1.0 * mm),
        ("BOTTOMPADDING", (0, 0), (1, 0), 1.0 * mm),
    ]))

    info_rows = [
        ("ŞASE NO", data.get("vin", "")),
        ("ENGINE NO", data.get("motorNo", "")),
        ("MODEL", data.get("model", "")),
        ("RENK", data.get("renk", "")),
        ("PARTİ NO", data.get("partiNo", "")),
        ("TARİH", data.get("tarihSaat", "")),
    ]
    info_data = [[Paragraph(k, s_info_lbl), Paragraph(str(v or ""), s_info_val)] for k, v in info_rows]
    info_tbl = Table(info_data, colWidths=[30 * mm, 179 * mm], rowHeights=[5.3 * mm] * 6)
    info_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), BORDER, colors.black),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 1.2 * mm),
        ("RIGHTPADDING", (0, 0), (-1, -1), 1.2 * mm),
        ("TOPPADDING", (0, 0), (-1, -1), 0.6 * mm),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0.6 * mm),
    ]))

    items = list(data.get("items", []) or [])
    while len(items) < 35:
        items.append({"siraNo": len(items) + 1, "process": "", "kontrolTuru": "", "cevap": ""})
    items = items[:35]

    table_data = [[
        Paragraph("NO", s_head),
        Paragraph("PROSESLER", s_head),
        Paragraph("KONTROL TÜRÜ", s_head),
        Paragraph("OK", s_head),
        Paragraph("NOK", s_head),
    ]]

    for i, it in enumerate(items, start=1):
        sira = str(it.get("siraNo") or i)
        proc = str(it.get("process") or "")
        tur = str(it.get("kontrolTuru") or "")
        cevap = str(it.get("cevap") or "").strip().upper()

        ok_mark = Paragraph("✓", s_ok) if cevap == "OK" else Paragraph("", s_cell_c)
        nok_mark = Paragraph("X", s_nok) if cevap == "NOK" else Paragraph("", s_cell_c)

        table_data.append([
            Paragraph(sira, s_cell_c),
            Paragraph(proc, s_cell),
            Paragraph(tur, s_cell_c),
            ok_mark,
            nok_mark,
        ])

    main_tbl = Table(
        table_data,
        colWidths=[10 * mm, 130 * mm, 35 * mm, 17 * mm, 17 * mm],
        rowHeights=[5.2 * mm] + [4.10 * mm] * 35,
        repeatRows=1,
    )
    main_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), BORDER, colors.black),
        ("BACKGROUND", (0, 0), (-1, 0), colors.lightgrey),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (0, 0), (-1, 0), "CENTER"),
        ("LEFTPADDING", (0, 0), (-1, -1), 1.0 * mm),
        ("RIGHTPADDING", (0, 0), (-1, -1), 1.0 * mm),
        ("TOPPADDING", (0, 0), (-1, -1), 0.15 * mm),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0.15 * mm),
    ]))

    sonuc = str(data.get("sonuc") or "").strip().upper()
    if sonuc == "OK":
        sonuc_par = Paragraph("TEST SONUCU : <font color='green'><b>OK ✓</b></font>", s_info_lbl)
    elif sonuc == "NOK":
        sonuc_par = Paragraph("TEST SONUCU : <font color='red'><b>NOK X</b></font>", s_info_lbl)
    else:
        sonuc_par = Paragraph("TEST SONUCU : -", s_info_lbl)

    sonuc_tbl = Table([[sonuc_par]], colWidths=[209 * mm], rowHeights=[5.6 * mm])
    sonuc_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), BORDER, colors.black),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 2.0 * mm),
        ("RIGHTPADDING", (0, 0), (-1, -1), 1.0 * mm),
        ("TOPPADDING", (0, 0), (-1, -1), 0.6 * mm),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0.6 * mm),
    ]))

    aciklama = Paragraph(
        "AÇIKLAMA : Tüm maddelerin uygun (OK) olması durumunda testten geçer. "
        "Aksi takdirde en az bir adet uygunsuz (NOK) olması durumunda testten geçemez.",
        s_small,
    )

    operator_name = str(data.get("operator") or "").strip()
    kontrolor_name = str(data.get("kontrolor") or "").strip()

    op_left = Paragraph("TEST OPERATÖRÜ : " + operator_name, s_small)
    ko_right = Paragraph(
        "KONTROLÖR : " + kontrolor_name + "<br/><br/><br/><br/><br/><br/>İmza: _______________________________________",
        s_small,
    )

    op_ko_tbl = Table(
        [[op_left, ko_right]],
        colWidths=[104.5 * mm, 104.5 * mm],
        rowHeights=[26 * mm],
    )
    op_ko_tbl.setStyle(TableStyle([
        ("LINEABOVE", (0, 0), (-1, 0), BORDER, colors.black),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 2.0 * mm),
        ("RIGHTPADDING", (0, 0), (-1, -1), 2.0 * mm),
        ("TOPPADDING", (0, 0), (-1, -1), 0.3 * mm),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0.3 * mm),
    ]))

    # ------- Document build -------
    doc = SimpleDocTemplate(
        pdf_path,
        pagesize=A4,
        leftMargin=2 * mm,
        rightMargin=2 * mm,
        topMargin=2 * mm,
        bottomMargin=1 * mm,
    )

    pre_story = [
        header_tbl,
        Spacer(1, 1.2 * mm),
        info_tbl,
        Spacer(1, 1.2 * mm),
        main_tbl,
        Spacer(1, 1.1 * mm),
        sonuc_tbl,
        Spacer(1, 0.8 * mm),
        aciklama,
        Spacer(1, 1.0 * mm),
        op_ko_tbl,
    ]

    # ---------------------------------------------------------
    # ✅ FOTO GRID (4'lü - SAĞDAN BAŞLAYARAK)
    # ---------------------------------------------------------
    GRID_ROW_H = 40 * mm
    GRID_NEED_H = float(GRID_ROW_H + (1 * mm))

    used_h = _story_height(pre_story, doc)
    remaining = float(doc.height) - used_h
    if remaining < 0:
        remaining = 0.0

    # ✅ DÜZELTME: fonksiyon HER ZAMAN build_submit_report_pdf içinde ve doğru girintide
    def _make_grid_for_chunk(chunk_paths: List[str]) -> Table:
        cell_w = doc.width / 4.0

        row: List[Flowable] = []
        for path in chunk_paths:
            try:
                img = Image(path)
                img._restrictSize(cell_w - 1 * mm, GRID_ROW_H - 0.5 * mm)
                row.append(img)
            except Exception:
                row.append(Paragraph("", s_cell_c))

        while len(row) < 4:
              row.append(Paragraph("", s_cell_c))

        grid = Table([row], colWidths=[cell_w] * 4, rowHeights=[GRID_ROW_H])
        grid.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), BORDER, colors.black),
            ("ALIGN", (0, 0), (-1, -1), "CENTER"),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 0),
            ("RIGHTPADDING", (0, 0), (-1, -1), 0),
            ("TOPPADDING", (0, 0), (-1, -1), 0),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
        ]))
        return grid

    story = list(pre_story)

    if photo_list:
        chunks = [photo_list[i:i + 4] for i in range(0, len(photo_list), 4)]

        # ilk chunk 1. sayfaya sığıyorsa ekle, sığmıyorsa pagebreak ile başlat
        if remaining >= GRID_NEED_H:
            story.append(Spacer(1, 0.0 * mm))
            story.append(_make_grid_for_chunk(chunks[0]))
            start_idx = 1
        else:
            story.append(PageBreak())
            start_idx = 0

        for idx in range(start_idx, len(chunks)):
            if idx > start_idx or start_idx == 0:
                if idx != start_idx:
                    story.append(PageBreak())
            story.append(Spacer(1, 0.5 * mm))
            story.append(_make_grid_for_chunk(chunks[idx]))

    doc.build(story)
    return pdf_path


# -------------------------
# Zebra ZPL label
# -------------------------
def build_zpl_label(payload: Dict[str, Any]) -> str:
    vin = str(payload.get("vin") or "").strip().upper()
    motor = str(payload.get("motorNo") or "").strip().upper()
    model = str(payload.get("model") or "").strip()
    sonuc = str(payload.get("sonuc") or "").strip().upper()
    ts = str(payload.get("tarihSaat") or datetime.now().strftime("%d.%m.%Y %H:%M")).strip()

    zpl = f"""
^XA
^CI28
^PW800
^LL400
^FO20,20^A0N,35,35^FDKALITE KONTROL^FS
^FO20,65^A0N,28,28^FDModel: {model}^FS
^FO20,100^A0N,28,28^FDMotor: {motor}^FS
^FO20,135^A0N,28,28^FDTarih: {ts}^FS
^FO20,175^A0N,30,30^FDSonuc: {sonuc}^FS
^FO20,220^BY3,2,80^BCN,80,Y,N,N
^FD{vin}^FS
^FO20,315^A0N,26,26^FDVIN: {vin}^FS
^XZ
""".strip()
    return zpl


def try_print_raw_zpl(printer_name: str, zpl: str) -> Tuple[bool, str]:
    try:
        import win32print  # type: ignore
    except Exception:
        return False, "pywin32 yok. Kur: pip install pywin32"

    if not str(printer_name or "").strip():
        return False, "printerName boş. /config ile yazıcı adını kaydet."

    try:
        hPrinter = win32print.OpenPrinter(printer_name)
        try:
            win32print.StartDocPrinter(hPrinter, 1, ("ZPL_LABEL", None, "RAW"))
            win32print.StartPagePrinter(hPrinter)
            win32print.WritePrinter(hPrinter, zpl.encode("utf-8"))
            win32print.EndPagePrinter(hPrinter)
            win32print.EndDocPrinter(hPrinter)
        finally:
            win32print.ClosePrinter(hPrinter)
        return True, "OK"
    except Exception as e:
        return False, f"Yazdırma hatası: {e}"


# -------------------------
# Routes
# -------------------------
@app.get("/where")
def where():
    try:
        wb = open_wb()
        sheets = wb.sheetnames
        wb.close()
    except Exception:
        sheets = []
    return jsonify({"excelPath": EXCEL_PATH, "sheetNames": sheets})


@app.get("/config")
def get_config():
    return jsonify(load_config())


@app.post("/config")
def post_config():
    data = request.get_json(silent=True) or {}
    cfg = load_config()

    def set_str_if_present(key: str):
        if key in data:
            v = str(data.get(key) or "").strip()
            if v != "":
                cfg[key] = v

    set_str_if_present("testReportsDir")
    set_str_if_present("kaliteReportsDir")
    set_str_if_present("logoPath")

    if "labelMode" in data:
        v = str(data.get("labelMode") or "").strip()
        if v:
            cfg["labelMode"] = v
    if "printerName" in data:
        cfg["printerName"] = str(data.get("printerName") or "").strip()

    set_str_if_present("isoPublishDate")
    set_str_if_present("isoFormNo")
    set_str_if_present("isoRevNo")
    set_str_if_present("isoRevDate")

    if not str(cfg.get("testReportsDir") or "").strip():
        return jsonify({"ok": False, "error": "testReportsDir boş olamaz"}), 400
    if not str(cfg.get("kaliteReportsDir") or "").strip():
        return jsonify({"ok": False, "error": "kaliteReportsDir boş olamaz"}), 400

    save_config(cfg)
    return jsonify({"ok": True, "config": cfg})


@app.get("/models")
def models():
    try:
        items = list_models_unique()
        return jsonify({"count": len(items), "items": items})
    except Exception as e:
        return jsonify({"count": 0, "items": [], "error": str(e)}), 500


@app.get("/kontrol-processleri")
def get_kontrol_processleri():
    try:
        items = kontrol_processleri()
        return jsonify({"count": len(items), "items": items})
    except Exception as e:
        return jsonify({"count": 0, "items": [], "error": str(e)}), 500


@app.get("/kontrol-turleri")
def get_kontrol_turleri():
    try:
        items = kontrol_processleri()
        uniq = sorted({str(x.get("kontrolTuru") or "").strip() for x in items if str(x.get("kontrolTuru") or "").strip()})
        if "Diğer" not in uniq:
            uniq.append("Diğer")
        return jsonify({"count": len(uniq), "items": uniq})
    except Exception as e:
        return jsonify({"count": 0, "items": [], "error": str(e)}), 500


@app.get("/hatalar-index")
def hatalar_index():
    try:
        items = get_hatalar_index()
        return jsonify({"count": len(items), "items": items})
    except Exception as e:
        return jsonify({"count": 0, "items": [], "error": str(e)}), 500


@app.post("/upload-photo")
def upload_photo():
    try:
        vin = (request.form.get("vin") or "").strip().upper() or "VIN"
        sira_raw = (request.form.get("siraNo") or "").strip()
        try:
            sira_no = int(sira_raw) if sira_raw else 0
        except Exception:
            sira_no = 0

        if "file" not in request.files:
            return jsonify({"ok": False, "error": "file alanı yok"}), 400

        f = request.files["file"]
        if not f:
            return jsonify({"ok": False, "error": "dosya boş"}), 400

        vin_dir = get_vin_photo_dir(vin)
        out_path = vin_dir / f"{sira_no}.jpg"

        try:
            if out_path.exists():
                out_path.unlink()
        except Exception:
            pass

        f.save(str(out_path))
        return jsonify({"ok": True, "path": str(out_path)})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/submit-report")
def submit_report():

    data = request.get_json(force=True) or {}

    try:

        conn = get_conn()
        cur = conn.cursor()

        vin = data.get("vin")
        operator = data.get("operator")
        kontrolor = data.get("kontrolor")
        sonuc = data.get("sonuc")

        # TEST KAYDI

        print("OPERATOR:", data.get("operator"))
        print("KONTROLOR:", data.get("kontrolor"))

        cur.execute("""
        INSERT INTO tests (
            vin,
            engine_no,
            model,
            operator,
            kontrolor,
            tarih,
            sonuc
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (

            data.get("vin"),
            data.get("motorNo"),
            data.get("model"),
            data.get("operator"),
            data.get("kontrolor"),
            data.get("tarihSaat"),
            data.get("sonuc")

            ))

        test_id = cur.lastrowid

        # NOK VARSA
        if str(sonuc).upper() == "NOK":

            cur.execute("""
            INSERT INTO nok_detaylari (
                test_id,
                vin,
                engine_no,
                marka,
                model,
                kontrol_id,
                parca_id,
                hata_id,
                sonuc
           )
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
           """, (
               test_id,
               data.get("vin"),
               data.get("motorNo"),
               data.get("model"),  # marka-model ayrıysa burayı ayırabiliriz
               data.get("model"),
               data.get("nokSiraNo"),
               None,
               None,
               "NOK"
           ))

        conn.commit()
        conn.close()

        return jsonify({
            "ok": True,
            "pdfPath": "kaydedildi"
        })

    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"ok": False, "error": str(e)}), 500

@app.post("/label-zpl")
def label_zpl():
    payload = request.get_json(force=True) or {}
    payload.setdefault("tarihSaat", datetime.now().strftime("%d.%m.%Y %H:%M"))
    try:
        zpl = build_zpl_label(payload)
        return jsonify({"ok": True, "zpl": zpl})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.post("/print-label")
def print_label():
    payload = request.get_json(force=True) or {}
    payload.setdefault("tarihSaat", datetime.now().strftime("%d.%m.%Y %H:%M"))

    cfg = load_config()
    printer = str(cfg.get("printerName") or "").strip()

    try:
        zpl = build_zpl_label(payload)
        ok, msg = try_print_raw_zpl(printer, zpl)
        code = 200 if ok else 400
        return jsonify({"ok": ok, "message": msg, "printerName": printer}), code
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    
def _col_exists(cur, table, col):
    cur.execute(f"PRAGMA table_info({table})")
    return any(r[1] == col for r in cur.fetchall())

import pandas as pd
import sqlite3

def excel_to_sql():

    print("Excel import başlıyor...")

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("DELETE FROM modeller")

    df = pd.read_excel("veri.xlsx", sheet_name="ŞASE VE PARTİ NO")

    for _, row in df.iterrows():

        model = str(row["Model"]).strip()
        prefix = str(row["Prefix"]).strip()
        seri_bas = int(row["SeriBas"])
        seri_bit = int(row["SeriBit"])
        parti_no = str(row["PartiNo"]).strip()

        cur.execute("""
        INSERT INTO modeller (marka, model, prefix, seri_bas, seri_bit, parti_no)
        VALUES (?, ?, ?, ?, ?, ?)
        """,(
            "SYM",
            model,
            prefix,
            seri_bas,
            seri_bit,
            parti_no
        ))

    conn.commit()
 

    print("Excel → SQL aktarımı tamamlandı.")

    # ---------------------------
    # TESTLER
    # ---------------------------
    cur.execute("""
    CREATE TABLE IF NOT EXISTS tests (
        test_id INTEGER PRIMARY KEY AUTOINCREMENT,
        vin TEXT,
        motor_no TEXT,   -- EKLENDİ
        model TEXT,      -- EKLENDİ
        operator TEXT,
        kontrolor TEXT,
        tarih DATETIME,
        sonuc TEXT
    )
    """)

    # ---------------------------
    # KONTROLLER
    # ---------------------------
    cur.execute("""
    CREATE TABLE IF NOT EXISTS kontroller (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sira_no INTEGER,
        kontrol_adi TEXT
    )
    """)

    # ---------------------------
    # PARÇALAR
    # ---------------------------
    cur.execute("""
    CREATE TABLE IF NOT EXISTS parcalar (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parca_adi TEXT
    )
    """)

    # ---------------------------
    # HATA TANIMLARI
    # ---------------------------
    cur.execute("""
    CREATE TABLE IF NOT EXISTS hata_tanimlari (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parca_id INTEGER,
        hata_aciklama TEXT
    )
    """)

    # ---------------------------
    # NOK DETAYLARI
    # ---------------------------
    cur.execute("""
    CREATE TABLE IF NOT EXISTS nok_detaylari (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        test_id INTEGER,
        kontrol_id INTEGER,
        parca_id INTEGER,
        hata_id INTEGER,
        sonuc TEXT,
        tamir_tarihi TEXT,
        tamir_eden TEXT,
        tamir_suresi INTEGER
    )
    """)

    conn.commit()
    conn.close()

@app.route('/nok-event', methods=['POST'])
def nok_event():
    data = request.json

    report_id = data.get("report_id")
    control_id = data.get("control_id")
    operator = data.get("operator")
    controller = data.get("controller")
    timestamp = data.get("timestamp")

    conn = sqlite3.connect("kalite.db")
    cursor = conn.cursor()

    cursor.execute("""
        INSERT INTO nok_events
        (report_id, control_id, operator, controller, created_at)
        VALUES (?, ?, ?, ?, ?)
    """, (report_id, control_id, operator, controller, timestamp))

    conn.commit()
    conn.close()

    return jsonify({"status": "ok"})

@app.get("/parcalar")
def get_parcalar():

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("SELECT id, parca_adi FROM parcalar ORDER BY parca_adi")

    rows = cur.fetchall()

    conn.close()

    return jsonify([
        {
            "id": r["id"],
            "parca": r["parca_adi"]
        }
        for r in rows
    ])

@app.get("/hatalar/<int:parca_id>")
def get_hatalar(parca_id):

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("""
        SELECT id, hata_aciklama
        FROM hata_tanimlari
        WHERE parca_id = ?
        ORDER BY hata_aciklama
    """, (parca_id,))

    rows = cur.fetchall()

    conn.close()

    return jsonify([
        {
            "id": r["id"],
            "hata": r["hata_aciklama"]
        }
        for r in rows
    ])

# --------------------------------
# SQL TABLOLARI
# --------------------------------

def create_tables():

    print("SQL tabloları oluşturuluyor...")

    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    # TEST TABLOSU
    cur.execute("""
    CREATE TABLE IF NOT EXISTS tests (
        test_id INTEGER PRIMARY KEY AUTOINCREMENT,
        vin TEXT,
        engine_no TEXT,
        model TEXT,
        operator TEXT,
        kontrolor TEXT,
        tarih TEXT,
        sonuc TEXT
    )
    """)

    # MODELLER TABLOSU
    cur.execute("""
    CREATE TABLE IF NOT EXISTS modeller (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        marka TEXT,
        model TEXT,
        prefix TEXT,
        seri_bas INTEGER,
        seri_bit INTEGER,
        parti_no TEXT
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS model_renkleri (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        model TEXT,
        renk TEXT,
        stok_kodu TEXT
    )
    """)

    conn.commit()
    conn.close()


# --------------------------------
# EXCEL → SQL AKTARIM
# --------------------------------


@app.get("/vin-lookup")
def vin_lookup():

    vin = str(request.args.get("vin") or "").strip().upper()

    if not vin:
        return jsonify({"ok": False, "error": "vin parametresi zorunlu"}), 400

    test_path_override = str(request.args.get("testPath") or "").strip()

    try:

        prefix = vin[:12]
        seri = int(vin[-5:])

        conn = get_conn()
        cur = conn.cursor()

        cur.execute("""
        SELECT marka, model, parti_no
        FROM modeller
        WHERE prefix = ?
        AND ? BETWEEN seri_bas AND seri_bit
        """,(prefix,seri))

        row = cur.fetchone()

        if not row:
            conn.close()
            return jsonify({"ok": False, "error": "VIN bulunamadı"}), 404

        # RENKLERİ ÇEK
        cur.execute("""
        SELECT renk, stok_kodu
        FROM model_renkleri
        WHERE model = ?
        """,(row["model"],))

        renk_rows = cur.fetchall()

        renkler = [
            {
                "renk": r["renk"],
                "stokKodu": r["stok_kodu"]
            }
            for r in renk_rows
        ]

        conn.close()

        # TEST RAPORU
        rapor_var = test_raporu_var_mi(vin, override_dir=test_path_override)

        return jsonify({
            "vin": vin,
            "prefix": prefix,
            "seri": seri,
            "marka": row["marka"],
            "model": row["model"],
            "partiNo": row["parti_no"],
            "renkler": renkler,
            "testRaporuVar": rapor_var
        })

    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
@app.route("/modeller")
def modeller_list():

    conn = sqlite3.connect("kalite.db")
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute("SELECT * FROM modeller")

    rows = cur.fetchall()

    conn.close()

    return jsonify([dict(r) for r in rows])

@app.route("/modeller_ekle", methods=["POST"])
def modeller_ekle():

    data = request.json

    conn = sqlite3.connect("kalite.db")
    cur = conn.cursor()

    cur.execute("""
    INSERT INTO modeller
    (marka,model,prefix,seri_bas,seri_bit,parti_no)
    VALUES (?,?,?,?,?,?)
    """,(
        data["marka"],
        data["model"],
        data["prefix"],
        data["seri_bas"],
        data["seri_bit"],
        data["parti_no"]
    ))

    conn.commit()
    conn.close()

    return jsonify({"status":"ok"})

@app.route("/modeller_duzenle/<int:id>", methods=["POST"])
def modeller_duzenle(id):

    data = request.json

    conn = sqlite3.connect("kalite.db")
    cur = conn.cursor()

    cur.execute("""
    UPDATE modeller
    SET marka=?,model=?,prefix=?,seri_bas=?,seri_bit=?,parti_no=?
    WHERE id=?
    """,(
        data["marka"],
        data["model"],
        data["prefix"],
        data["seri_bas"],
        data["seri_bit"],
        data["parti_no"],
        id
    ))

    conn.commit()
    conn.close()

    return jsonify({"status":"ok"})

@app.route("/modeller_sil/<int:id>", methods=["DELETE"])
def modeller_sil(id):

    conn = sqlite3.connect("kalite.db")
    cur = conn.cursor()

    cur.execute("DELETE FROM modeller WHERE id=?", (id,))

    conn.commit()
    conn.close()

    return jsonify({"status":"ok"})

from flask import render_template

@app.route("/admin")
def admin_panel():

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("SELECT * FROM kontroller")
    kontroller = cur.fetchall()

    cur.execute("SELECT * FROM parcalar")
    parcalar = cur.fetchall()

    cur.execute("""
    SELECT
        h.id,
        p.parca_adi as parca,
        h.hata_aciklama,
        h.tur,
        h.seviye
    FROM hata_tanimlari h
    LEFT JOIN parcalar p ON h.parca_id=p.id
    """)
    hatalar = cur.fetchall()

    cur.execute("""
    SELECT id, model, renk, stok_kodu
    FROM model_renkleri
    ORDER BY model
    """)

    renkler = cur.fetchall()

    conn.close()

    return render_template(
        "admin.html",
        kontroller=kontroller,
        parcalar=parcalar,
        hatalar=hatalar,
        renkler=renkler,
    )

@app.post("/nok_ekle")
def nok_ekle():

    data = request.get_json(force=True)

    test_id = data.get("test_id")
    kontrol_id = data.get("kontrol_id")
    parca_id = data.get("parca_id")
    hata_id = data.get("hata_id")

    conn = get_conn()
    cur = conn.cursor()

    # Hatanın detaylarını al
    cur.execute("""
        SELECT tur, seviye, kaynak, istasyon
        FROM hata_tanimlari
        WHERE id = ?
    """, (hata_id,))

    hata = cur.fetchone()

    tur = hata["tur"] if hata else None
    seviye = hata["seviye"] if hata else None
    kaynak = hata["kaynak"] if hata else None
    istasyon = hata["istasyon"] if hata else None

    # NOK kaydı oluştur
    cur.execute("""
        INSERT INTO nok_detaylari
        (
            test_id,
            kontrol_id,
            parca_id,
            hata_id,
            sonuc,
            tur,
            seviye,
            kaynak,
            istasyon
        )
        VALUES (?,?,?,?,?,?,?,?,?)
    """,(
        test_id,
        kontrol_id,
        parca_id,
        hata_id,
        "NOK",
        tur,
        seviye,
        kaynak,
        istasyon
    ))

    conn.commit()
    conn.close()

    return jsonify({
        "ok": True
    })

@app.get("/nok_listesi/<int:test_id>")
def nok_listesi(test_id):

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("""
        SELECT
            n.id,
            p.parca_adi,
            h.hata_aciklama
        FROM nok_detaylari n
        JOIN parcalar p ON p.id = n.parca_id
        JOIN hata_tanimlari h ON h.id = n.hata_id
        WHERE n.test_id = ?
    """,(test_id,))

    rows = cur.fetchall()

    conn.close()

    return jsonify([
        {
            "id": r["id"],
            "parca": r["parca_adi"],
            "hata": r["hata_aciklama"]
        }
        for r in rows
    ])

@app.delete("/nok_sil/<int:id>")
def nok_sil(id):

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("""
        DELETE FROM nok_detaylari
        WHERE id = ?
    """,(id,))

    conn.commit()
    conn.close()

    return jsonify({"ok":True})

@app.post("/excel-import")
def excel_import():

    try:
        excel_to_sql()

        return jsonify({
            "ok": True,
            "message": "Excel verileri SQL'e aktarıldı"
        })

    except Exception as e:

        return jsonify({
            "ok": False,
            "error": str(e)
        }),500

@app.post("/admin/renk-ekle")
def renk_ekle():

    model = request.form.get("model")
    renk = request.form.get("renk")
    stok = request.form.get("stok")

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("""
    INSERT INTO model_renkleri (model, renk, stok_kodu)
    VALUES (?,?,?)
    """,(model,renk,stok))

    conn.commit()
    conn.close()

    return redirect("/admin")

@app.get("/admin/renk-sil/<int:id>")
def renk_sil(id):

    conn = get_conn()
    cur = conn.cursor()

    cur.execute("DELETE FROM model_renkleri WHERE id=?", (id,))

    conn.commit()
    conn.close()

    return redirect("/admin")


# --------------------------------
# PROGRAM BAŞLANGICI
# --------------------------------

if __name__ == "__main__":

    create_tables()

    print("API başlatılıyor...")

    app.run(host="0.0.0.0", port=5000)
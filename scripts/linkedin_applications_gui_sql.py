#!/usr/bin/env python3
"""Desktop GUI for LinkedIn applications with SQL storage and manual status control."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from urllib.error import HTTPError
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

GUI_IMPORT_ERROR: Exception | None = None
GUI_AVAILABLE = False

try:
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QAction
    from PySide6.QtWidgets import (
        QApplication,
        QFormLayout,
        QFrame,
        QHeaderView,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QMainWindow,
        QMessageBox,
        QPushButton,
        QSplitter,
        QTextEdit,
        QToolBar,
        QTreeWidget,
        QTreeWidgetItem,
        QVBoxLayout,
        QWidget,
    )
    GUI_AVAILABLE = True
except Exception as exc:  # pragma: no cover
    GUI_IMPORT_ERROR = exc

from update_linkedin_applications import (
    classify,
    extract_company,
    extract_job_id,
    extract_subject,
    strip_html_to_text,
)


STATUS_ORDER = ["incoming", "applied", "rejected", "interview", "manual_sort", "archive"]
STATUS_TITLE = {
    "incoming": "Входящие",
    "applied": "Applied",
    "interview": "Interview",
    "rejected": "Reject",
    "manual_sort": "Manual Sort",
    "archive": "Archive",
}
DRIVE_FOLDER_ID = "1edFf52mpJVSJcOYuP8ACLKX_T64g21Tn"
DRIVE_REMOTE = os.getenv("LINKEDIN_DRIVE_REMOTE", "gdrive_cv")
TRANSLATE_TO_RU = os.getenv("LINKEDIN_TRANSLATE_TO_RU", "1").strip().lower() not in {"0", "false", "no", "off"}
TRANSLATE_PROVIDER = os.getenv("LINKINJOB_TRANSLATE_PROVIDER", "google_unofficial").strip().lower()
GOOGLE_TRANSLATE_API_KEY = (
    os.getenv("LINKINJOB_GOOGLE_TRANSLATE_API_KEY", "")
    or os.getenv("GOOGLE_TRANSLATE_API_KEY", "")
).strip()
DEFAULT_DB_PATH = Path.home() / "Library" / "Application Support" / "LinkInJob" / "applications.db"


@dataclass
class ApplicationRow:
    id: int
    source_file: str
    file_name: str
    email_date: str
    subject: str
    company: str
    role: str
    location: str
    link_url: str
    auto_status: str
    manual_status: Optional[str]
    current_status: str
    body: str
    about_job_text: str
    about_job_text_en: str
    about_job_text_ru: str


class ApplicationsDB:
    def __init__(self, db_path: str) -> None:
        self.db_path = os.path.abspath(db_path)
        parent = os.path.dirname(self.db_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        self.conn = sqlite3.connect(self.db_path)
        self.job_cache: dict[str, tuple[str, str, str, str]] = {}
        self.translation_cache: dict[str, str] = {}
        self.google_translate_blocked = False
        self.translate_provider = (
            TRANSLATE_PROVIDER
            if TRANSLATE_PROVIDER in {"google_unofficial", "google_api"}
            else "google_unofficial"
        )
        self.google_translate_api_key = GOOGLE_TRANSLATE_API_KEY
        self._init_schema()

    def close(self) -> None:
        self.conn.close()

    def reset_all(self) -> None:
        self.conn.execute("DELETE FROM applications")
        self.conn.commit()

    def _init_schema(self) -> None:
        legacy_rows: list[tuple] = []
        if self._table_exists("applications"):
            cols = self._table_columns("applications")
            if "record_key" not in cols:
                legacy_rows = self.conn.execute(
                    """
                    SELECT
                        source_file, file_name, email_date, subject, company, role,
                        '', COALESCE(link_url, ''), COALESCE(about_job_text, ''), '', '',
                        auto_status, manual_status, current_status, body
                    FROM applications
                    """
                ).fetchall()
                self.conn.execute("DROP TABLE applications")

        self.conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS applications (
                id INTEGER PRIMARY KEY,
                record_key TEXT NOT NULL UNIQUE,
                source_file TEXT NOT NULL,
                file_name TEXT NOT NULL,
                email_date TEXT,
                subject TEXT,
                company TEXT,
                role TEXT,
                location TEXT,
                link_url TEXT,
                about_job_text TEXT,
                about_job_text_en TEXT,
                about_job_text_ru TEXT,
                auto_status TEXT NOT NULL,
                manual_status TEXT,
                current_status TEXT NOT NULL,
                body TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );

            CREATE INDEX IF NOT EXISTS idx_applications_status
                ON applications(current_status, company, email_date);
            CREATE INDEX IF NOT EXISTS idx_applications_source_file
                ON applications(source_file);

            CREATE TABLE IF NOT EXISTS status_pins (
                record_key TEXT PRIMARY KEY,
                pinned_status TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """
        )
        self._ensure_column("applications", "location", "TEXT")
        self._ensure_column("applications", "about_job_text_en", "TEXT")
        self._ensure_column("applications", "about_job_text_ru", "TEXT")

        if legacy_rows:
            cur = self.conn.cursor()
            for row in legacy_rows:
                source_file = str(row[0])
                record_key = f"{source_file}::legacy"
                cur.execute(
                    """
                    INSERT OR IGNORE INTO applications(
                        record_key, source_file, file_name, email_date, subject, company, role, location, link_url, about_job_text,
                        about_job_text_en, about_job_text_ru, auto_status, manual_status, current_status, body
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (record_key, *row),
                )
        self._migrate_description_columns()
        self.conn.commit()

    def _migrate_description_columns(self) -> None:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT id, COALESCE(about_job_text, ''), COALESCE(about_job_text_en, ''), COALESCE(about_job_text_ru, '')
            FROM applications
            """
        )
        for app_id, legacy_text, text_en, text_ru in cur.fetchall():
            legacy = str(legacy_text or "").strip()
            en_val = str(text_en or "").strip()
            ru_val = str(text_ru or "").strip()
            if not legacy:
                continue
            if not en_val and not ru_val:
                if self._looks_russian(legacy):
                    ru_val = legacy
                else:
                    en_val = legacy
            elif not en_val and not self._looks_russian(legacy):
                en_val = legacy
            elif not ru_val and self._looks_russian(legacy):
                ru_val = legacy
            cur.execute(
                """
                UPDATE applications
                SET about_job_text_en = ?, about_job_text_ru = ?
                WHERE id = ?
                """,
                (en_val, ru_val, int(app_id)),
            )

    def _table_exists(self, table: str) -> bool:
        cur = self.conn.cursor()
        cur.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            (table,),
        )
        return cur.fetchone() is not None

    def _table_columns(self, table: str) -> set[str]:
        cur = self.conn.cursor()
        cur.execute(f"PRAGMA table_info({table})")
        return {str(row[1]) for row in cur.fetchall()}

    def _ensure_column(self, table: str, column: str, definition: str) -> None:
        cur = self.conn.cursor()
        cur.execute(f"PRAGMA table_info({table})")
        cols = {row[1] for row in cur.fetchall()}
        if column not in cols:
            cur.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    def get_pinned_status(self, record_key: str) -> Optional[str]:
        cur = self.conn.cursor()
        cur.execute("SELECT pinned_status FROM status_pins WHERE record_key = ?", (record_key,))
        row = cur.fetchone()
        if not row:
            return None
        status = str(row[0] or "")
        if status not in STATUS_ORDER or status == "incoming":
            return None
        return status

    def set_pinned_status(self, record_key: str, status: Optional[str]) -> None:
        cur = self.conn.cursor()
        if status is None or status == "incoming":
            cur.execute("DELETE FROM status_pins WHERE record_key = ?", (record_key,))
            return
        if status not in STATUS_ORDER:
            raise ValueError(f"Invalid status: {status}")
        cur.execute(
            """
            INSERT INTO status_pins(record_key, pinned_status, updated_at)
            VALUES (?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(record_key) DO UPDATE SET
                pinned_status = excluded.pinned_status,
                updated_at = CURRENT_TIMESTAMP
            """,
            (record_key, status),
        )

    def snapshot_non_incoming_statuses(self) -> int:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT record_key, current_status
            FROM applications
            WHERE current_status != 'incoming'
            """
        )
        rows = cur.fetchall()
        changed = 0
        for record_key, current_status in rows:
            if not record_key:
                continue
            status = str(current_status or "")
            if status not in STATUS_ORDER or status == "incoming":
                continue
            self.set_pinned_status(str(record_key), status)
            changed += 1
        self.conn.commit()
        return changed

    @staticmethod
    def extract_job_links(text: str) -> list[str]:
        normalized_text = html.unescape(text or "")
        patterns = [
            r"https?://(?:[a-z]{1,3}\.)?linkedin\.com/jobs/view/\d+[^\s)>\]\"']*",
            r"https?://(?:[a-z]{1,3}\.)?linkedin\.com/comm/jobs/view/\d+[^\s)>\]\"']*",
            r"https?://(?:[a-z]{1,3}\.)?linkedin\.com/(?:comm/)?company/[^/\s)>\]\"']+/jobs[^\s)>\]\"']*",
            r"https?://(?:[a-z]{1,3}\.)?linkedin\.com/(?:comm/)?company/[^/\s)>\]\"']+[^\s)>\]\"']*",
            r"https?://(?:[a-z]{1,3}\.)?linkedin\.com/jobs/search/[^\s)>\]\"']*",
            r"https?://(?:[a-z]{1,3}\.)?linkedin\.com/[^\s)>\]\"']*currentJobId=\d+[^\s)>\]\"']*",
            r"linkedin\.com/(?:comm/)?jobs%2Fview%2F\d+",
        ]
        raw_by_canonical: dict[str, str] = {}
        by_job_id: dict[str, str] = {}
        for pattern in patterns:
            for match in re.finditer(pattern, normalized_text, flags=re.IGNORECASE):
                url = match.group(0).strip().rstrip(".,;)")
                if not url.lower().startswith("http"):
                    url = f"https://www.{url.lstrip('/')}"

                # Accept plain company profile links only when context indicates role openings.
                parsed_candidate = urllib.parse.urlparse(url)
                path_candidate = (parsed_candidate.path or "").lower()
                is_company_profile = bool(re.match(r"^/(comm/)?company/[^/]+/?$", path_candidate))
                if is_company_profile:
                    ctx_start = max(0, match.start() - 180)
                    ctx_end = min(len(normalized_text), match.end() + 80)
                    context = normalized_text[ctx_start:ctx_end].lower()
                    if not re.search(r"view\s+roles|view\s+jobs|ваканси|jobs\s+for\s+your\s+role", context):
                        continue

                canonical = ApplicationsDB.canonicalize_job_url(url)
                if not ApplicationsDB._is_supported_job_link(canonical):
                    continue
                job_id = extract_job_id(canonical) or extract_job_id(url)
                if job_id:
                    by_job_id[job_id] = canonical
                    continue
                raw_by_canonical.setdefault(canonical, url)

        for job_id in re.findall(r"currentJobId=(\d+)", normalized_text, flags=re.IGNORECASE):
            by_job_id[job_id] = f"https://www.linkedin.com/jobs/view/{job_id}/"

        for job_id in re.findall(r"jobs%2[fF]view%2[fF](\d+)", normalized_text, flags=re.IGNORECASE):
            by_job_id[job_id] = f"https://www.linkedin.com/jobs/view/{job_id}/"

        # For job-id links keep canonical form (stable and concise).
        for job_id in sorted(by_job_id.keys()):
            canonical = by_job_id[job_id]
            raw_by_canonical.setdefault(canonical, canonical)

        return list(raw_by_canonical.values())

    @staticmethod
    def canonicalize_job_url(link_url: str) -> str:
        try:
            parsed = urllib.parse.urlparse(link_url)
        except Exception:
            parsed = None

        if parsed and parsed.netloc:
            host = parsed.netloc.lower()
            path = parsed.path or ""
            if "linkedin.com" in host:
                # Canonicalize company jobs pages and drop tracking query params.
                m = re.match(r"^/(comm/)?company/([^/]+)/jobs/?$", path, flags=re.IGNORECASE)
                if m:
                    comm = "comm/" if m.group(1) else ""
                    slug = m.group(2)
                    return f"https://www.linkedin.com/{comm}company/{slug}/jobs"
                m_company = re.match(r"^/(comm/)?company/([^/]+)/?$", path, flags=re.IGNORECASE)
                if m_company:
                    comm = "comm/" if m_company.group(1) else ""
                    slug = m_company.group(2)
                    return f"https://www.linkedin.com/{comm}company/{slug}/jobs"

        job_id = extract_job_id(link_url)
        if not job_id:
            return link_url
        if "/comm/jobs/view/" in link_url:
            return f"https://www.linkedin.com/comm/jobs/view/{job_id}/"
        return f"https://www.linkedin.com/jobs/view/{job_id}/"

    @staticmethod
    def _is_supported_job_link(link_url: str) -> bool:
        if not link_url:
            return False
        lower = link_url.lower()
        if "/jobs/view/" in lower:
            return True
        if re.search(r"/(?:comm/)?company/[^/]+/jobs/?(?:$|\?)", lower):
            return True
        if re.search(r"/(?:comm/)?company/[^/]+/?(?:$|\?)", lower):
            return True
        if "/jobs/search/" in lower:
            return True
        return False

    @staticmethod
    def record_key_for_link(link_url: str) -> str:
        job_id = extract_job_id(link_url)
        if job_id:
            return f"job::{job_id}"
        return f"link::{link_url}"

    @staticmethod
    def _key_part(value: str) -> str:
        cleaned = re.sub(r"\s+", " ", (value or "").strip().lower())
        return re.sub(r"[^0-9a-zа-яё\u0590-\u05ff ./-]+", "", cleaned)

    def record_key_for_offer(self, company: str, role: str, location: str, link_url: str) -> str:
        company_k = self._key_part(company)
        role_k = self._key_part(role)
        location_k = self._key_part(location)
        if company_k and role_k:
            # Date is intentionally excluded from uniqueness.
            return f"offer::{company_k}::{role_k}::{location_k}"
        return self.record_key_for_link(link_url)

    @staticmethod
    def _clean_offer_line(line: str) -> str:
        cleaned = re.sub(r"\s+", " ", line).strip()
        cleaned = cleaned.strip("-–—|•:;,.")
        return cleaned

    @staticmethod
    def _is_noise_line(line: str) -> bool:
        lowered = line.lower()
        if not lowered:
            return True
        markers = [
            "view job",
            "ссылка",
            "см. вакансию",
            "apply now",
            "apply with resume",
            "apply with profile",
            "linkedin",
            "jobs similar",
            "job alert",
            "оповещени",
            "unsubscribe",
            "notifications",
            "this company is actively hiring",
            "эта компания активно нанимает новых сотрудников",
            "эта компания активно нанимает",
            "компания активно нанимает",
            "החברה מגייסת עובדים",
            "actively hiring",
        ]
        return any(marker in lowered for marker in markers) or "http" in lowered

    @staticmethod
    def _looks_like_location(line: str) -> bool:
        text = (line or "").strip()
        if not text:
            return False
        lowered = text.lower()

        # Obvious non-location phrases.
        bad_markers = [
            "engineer",
            "developer",
            "administrator",
            "specialist",
            "manager",
            "support",
            "resume",
            "profile",
            "hiring",
            "нанимает",
            "вакан",
            "позици",
            "должност",
            "компания",
            "this company",
        ]
        if any(m in lowered for m in bad_markers):
            return False

        # Reasonable location line is usually short and noun-like.
        tokens = re.findall(r"\S+", text)
        if len(tokens) > 7:
            return False
        if len(tokens) == 1 and len(tokens[0]) <= 2:
            return False
        return True

    def extract_offers_from_email(self, text: str) -> dict[str, tuple[str, str, str]]:
        offers: dict[str, tuple[str, str, str]] = {}
        lines = text.splitlines()
        view_job_re = re.compile(r"(?i)(?:View job|См\.\s*вакансию)\s*:\s*(https?://\S+)")
        for idx, line in enumerate(lines):
            match = view_job_re.search(line)
            if not match:
                continue
            raw_url = match.group(1).strip().rstrip(".,;)")
            url = self.canonicalize_job_url(raw_url)
            if not url or url in offers:
                continue

            # Strict reverse parsing from link line:
            # location -> company -> role.
            location = ""
            company = ""
            role = ""
            j = idx - 1
            while j >= 0 and (not location or not company or not role):
                candidate = self._clean_offer_line(lines[j])
                j -= 1
                if self._is_noise_line(candidate):
                    continue
                if not candidate:
                    continue

                if not location:
                    if not self._looks_like_location(candidate):
                        continue
                    location = candidate
                    continue
                if not company:
                    company = candidate
                    continue
                if not role:
                    role = candidate
                    break

            if not company:
                company = "Unknown"
            offers[url] = (role, company, location)
        return offers

    def extract_company_role_location_for_link(
        self, text: str, link_url: str, fallback_company: str, raw_link_url: Optional[str] = None
    ) -> tuple[str, str, str]:
        company_jobs_match = re.search(r"/(?:comm/)?company/([^/]+)/jobs/?(?:$|\?)", link_url, flags=re.IGNORECASE)
        if company_jobs_match:
            slug = company_jobs_match.group(1).strip()
            company_from_slug = re.sub(r"[-_]+", " ", slug).strip() or fallback_company
            subject = extract_subject(text) or ""
            subject_role_match = re.match(r"^\s*([^:]{2,120})\s*:", subject)
            role_from_subject = subject_role_match.group(1).strip() if subject_role_match else ""
            location_match = re.search(
                r"(?i)\broles?\s+were\s+hired\s+this\s+week\s+in\s+([^\r\n]+)",
                text,
            )
            location_from_text = self._clean_offer_line(location_match.group(1)) if location_match else ""

            company_from_text = ""
            for candidate in [raw_link_url, link_url]:
                if not candidate:
                    continue
                m = re.search(re.escape(candidate), text)
                if not m:
                    continue
                before = text[:m.start()]
                lines = [self._clean_offer_line(x) for x in before.splitlines()]
                for line in reversed(lines[-12:]):
                    if not line:
                        continue
                    lower = line.lower()
                    if lower in {"view roles", "view", "follow"}:
                        continue
                    if re.search(r"\b(new hire|followers|employees)\b", lower):
                        continue
                    if line.startswith("?") or "=" in line:
                        continue
                    company_from_text = line
                    break
                if company_from_text:
                    break

            company = company_from_text or company_from_slug
            role = role_from_subject or ""
            location = location_from_text or ""
            return role, company, location

        match = None
        matched_link = ""
        for candidate in [raw_link_url, link_url]:
            if not candidate:
                continue
            escaped = re.escape(candidate)
            match = re.search(escaped, text)
            if match:
                matched_link = candidate
                break
        if not match:
            return "", fallback_company, ""

        # Inline pattern: "Jobs similar to <role> at <company> <url>"
        full_line_start = text.rfind("\n", 0, match.start()) + 1
        full_line_end = text.find("\n", match.end())
        if full_line_end == -1:
            full_line_end = len(text)
        full_line = text[full_line_start:full_line_end].strip()
        inline_patterns = [
            r"(?i)^jobs similar to\s+(.+?)\s+at\s+(.+?)\s+https?://",
            r"(?i)^new jobs similar to\s+(.+?)\s+at\s+(.+?)\s+https?://",
            r"(?i)^вакансии, похожие на\s+(.+?)\s+в\s+(.+?)\s+https?://",
        ]
        for pattern in inline_patterns:
            m = re.search(pattern, full_line)
            if m:
                role = self._clean_offer_line(m.group(1))
                company = self._clean_offer_line(m.group(2))
                return role, company, ""

        # Try to parse same line first: "... Company - Role - https://..."
        same_line_text = full_line
        for candidate in [matched_link, raw_link_url, link_url]:
            if candidate:
                same_line_text = same_line_text.replace(candidate, "")
        same_line_text = self._clean_offer_line(same_line_text)
        if same_line_text.startswith("?") or same_line_text.lower().startswith(
            ("lipi=", "midtoken=", "midsig=", "trk=", "trkemail=", "eid=", "otptoken=")
        ):
            same_line_text = ""
        if same_line_text and not self._is_noise_line(same_line_text):
            parts = [self._clean_offer_line(p) for p in re.split(r"\s[-–—|]\s", same_line_text) if self._clean_offer_line(p)]
            if len(parts) >= 2:
                return parts[1], parts[0], ""
            if len(parts) == 1:
                return parts[0], fallback_company, ""

        # Fallback: two non-empty lines before the link line.
        before = text[:match.start()]
        candidates: list[str] = []
        for raw in reversed(before.splitlines()):
            cleaned = self._clean_offer_line(raw)
            if not cleaned or self._is_noise_line(cleaned):
                continue
            candidates.append(cleaned)
            if len(candidates) == 2:
                break

        if len(candidates) >= 3:
            role_line, company_line, location_line = candidates[2], candidates[1], candidates[0]
            return role_line, company_line, location_line
        if len(candidates) == 2:
            role_line, company_line = candidates[1], candidates[0]
            return role_line, company_line, ""
        if len(candidates) == 1:
            return candidates[0], fallback_company, ""
        return "", fallback_company, ""

    @staticmethod
    def infer_status(text: str, links: list[str]) -> str:
        is_application, is_rejection, is_interview = classify(text)
        if is_rejection:
            return "rejected"
        if is_interview:
            return "interview"
        if is_application:
            return "applied"
        if links:
            return "incoming"
        return "manual_sort"

    @staticmethod
    def _normalize_inline(value: str) -> str:
        return re.sub(r"\s+", " ", value or "").strip()

    @staticmethod
    def _looks_russian(text: str) -> bool:
        if not text:
            return False
        letters = re.findall(r"[A-Za-zА-Яа-яЁё]", text)
        if not letters:
            return False
        cyr = re.findall(r"[А-Яа-яЁё]", text)
        return (len(cyr) / max(1, len(letters))) >= 0.2

    def _translate_chunk_google_api(self, chunk: str) -> str:
        if not self.google_translate_api_key:
            raise RuntimeError("Google Cloud Translate API key is missing.")

        payload = urllib.parse.urlencode(
            {
                "q": chunk,
                "target": "ru",
                "format": "text",
                "key": self.google_translate_api_key,
            }
        ).encode("utf-8")
        req = urllib.request.Request(
            "https://translation.googleapis.com/language/translate/v2",
            data=payload,
            headers={
                "User-Agent": "Mozilla/5.0",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                payload_text = response.read().decode("utf-8", errors="ignore")
        except HTTPError as exc:
            details = ""
            try:
                details = exc.read().decode("utf-8", errors="ignore")
            except Exception:
                details = str(exc)
            raise RuntimeError(f"Google API error {exc.code}: {details[:400]}") from exc
        data = json.loads(payload_text)
        translated = (
            data.get("data", {}).get("translations", [{}])[0].get("translatedText", "")
            if isinstance(data, dict) else ""
        )
        translated_text = html.unescape(str(translated)).strip()
        return translated_text or chunk

    @staticmethod
    def _contains_hebrew_or_arabic(text: str) -> bool:
        return bool(re.search(r"[\u0590-\u05FF\u0600-\u06FF]", text or ""))

    def _translation_looks_successful(self, source: str, translated: str) -> bool:
        src = self._normalize_inline(source)
        out = self._normalize_inline(translated)
        if not out:
            return False
        if src == out:
            return False
        if self._looks_russian(out):
            return True
        # For Hebrew/Arabic source, we expect at least some Cyrillic in RU output.
        if self._contains_hebrew_or_arabic(src) and not self._looks_russian(out):
            return False
        return True

    def _translate_chunk_google_unofficial(self, chunk: str) -> str:
        payload = urllib.parse.urlencode(
            {
                "client": "gtx",
                "sl": "auto",
                "tl": "ru",
                "dt": "t",
                "q": chunk,
            }
        ).encode("utf-8")
        last_error: Exception | None = None
        if not self.google_translate_blocked:
            for attempt in range(3):
                try:
                    time.sleep(0.08)
                    req = urllib.request.Request(
                        "https://translate.googleapis.com/translate_a/single",
                        data=payload,
                        headers={
                            "User-Agent": "Mozilla/5.0",
                            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                        },
                        method="POST",
                    )
                    with urllib.request.urlopen(req, timeout=8) as response:
                        payload_text = response.read().decode("utf-8", errors="ignore")
                    data = json.loads(payload_text)
                    chunks_data = data[0] if isinstance(data, list) and data else []
                    translated = "".join(
                        str(chunk_data[0]) for chunk_data in chunks_data if isinstance(chunk_data, list) and chunk_data and chunk_data[0]
                    ).strip()
                    return translated or chunk
                except Exception as exc:
                    last_error = exc
                    if "429" in str(exc):
                        self.google_translate_blocked = True
                        break
                    if attempt < 2:
                        time.sleep(0.25 * (attempt + 1))
                        continue
                    break
        raise last_error if last_error else RuntimeError("Google unofficial translate failed")

    def _translate_fragment_to_russian(self, fragment: str, strict: bool = False) -> str:
        if not fragment or not TRANSLATE_TO_RU:
            return fragment
        fragment_with_lf = fragment.replace("\r\n", "\n").replace("\r", "\n")
        line_break_token = "__LINKINJOB_LB_9F4C__"
        prepared_fragment = (
            fragment_with_lf.replace("\n", f" {line_break_token} ")
            if "\n" in fragment_with_lf
            else fragment_with_lf
        )
        stripped_fragment = prepared_fragment.strip()
        if not stripped_fragment:
            return fragment
        if self._looks_russian(stripped_fragment):
            return fragment
        if "http://" in stripped_fragment.lower() or "https://" in stripped_fragment.lower():
            return fragment

        def split_chunks(text: str, max_len: int = 1100) -> list[str]:
            if len(text) <= max_len:
                return [text]
            chunks: list[str] = []
            start = 0
            while start < len(text):
                end = min(start + max_len, len(text))
                if end < len(text):
                    split_at = max(
                        text.rfind("\n", start, end),
                        text.rfind(". ", start, end),
                        text.rfind("; ", start, end),
                        text.rfind(", ", start, end),
                        text.rfind(" ", start, end),
                    )
                    if split_at <= start + max_len // 3:
                        split_at = end
                else:
                    split_at = end
                chunk = text[start:split_at]
                if chunk:
                    chunks.append(chunk)
                start = split_at
            return chunks or [text]

        def translate_chunk(chunk: str) -> str:
            errors: list[Exception] = []

            # Respect explicitly selected provider. In non-strict mode,
            # allow fallback only between supported Google methods.
            if self.translate_provider == "google_api":
                provider_order = ["google_api"]
            else:
                provider_order = ["google_unofficial"]

            if not strict:
                if self.translate_provider == "google_api":
                    provider_order.append("google_unofficial")
                else:
                    provider_order.append("google_api")

            for provider in provider_order:
                try:
                    if provider == "google_api":
                        if not self.google_translate_api_key:
                            raise RuntimeError("Google Cloud API key is not configured")
                        candidate = self._translate_chunk_google_api(chunk)
                        if self._translation_looks_successful(chunk, candidate):
                            return candidate
                        raise RuntimeError("Google API returned non-RU or unchanged text")
                    if provider == "google_unofficial":
                        candidate = self._translate_chunk_google_unofficial(chunk)
                        if self._translation_looks_successful(chunk, candidate):
                            return candidate
                        raise RuntimeError("Google unofficial returned non-RU or unchanged text")
                except Exception as exc:
                    errors.append(exc)
                    continue

            if errors:
                raise errors[-1]
            raise RuntimeError("Translation failed")

        try:
            translated_parts: list[str] = []
            for chunk in split_chunks(prepared_fragment):
                # Preserve original separators/indentation around translated content.
                leading = re.match(r"^\s*", chunk).group(0)
                trailing = re.search(r"\s*$", chunk).group(0)
                core = chunk[len(leading):len(chunk) - len(trailing) if trailing else len(chunk)]

                if not core.strip():
                    translated_parts.append(chunk)
                    continue

                cached = self.translation_cache.get(core)
                if cached is None:
                    cached = translate_chunk(core)
                    self.translation_cache[core] = cached
                translated_parts.append(f"{leading}{cached}{trailing}")

            result = "".join(translated_parts) or fragment_with_lf
            # Some providers may mutate marker punctuation/underscores.
            # Restore both canonical and deformed marker variants back to newlines.
            result = re.sub(
                rf"\s*{re.escape(line_break_token)}\s*",
                "\n",
                result,
                flags=re.IGNORECASE,
            )
            result = re.sub(
                r"\s*[_\-–—•·]*\s*LINKINJOB[\s_\-]+LB[\s_\-]+9F4C\s*[_\-–—•·]*\s*",
                "\n",
                result,
                flags=re.IGNORECASE,
            )
        except Exception as exc:
            if strict:
                raise RuntimeError(f"Translation failed: {exc}") from exc
            result = fragment

        return result

    def translate_to_russian(self, text: str, strict: bool = False) -> str:
        if not text or not TRANSLATE_TO_RU:
            return text
        normalized = text.strip()
        if not normalized:
            return text
        if self._looks_russian(normalized):
            return text

        # Preserve original paragraph boundaries and empty lines.
        parts = re.split(r"(\n\s*\n+)", text)
        translated_parts: list[str] = []
        for part in parts:
            if not part:
                continue
            if re.fullmatch(r"\n\s*\n+", part):
                translated_parts.append(part)
                continue
            translated_parts.append(self._translate_fragment_to_russian(part, strict=strict))

        result = "".join(translated_parts)
        return result if result.strip() else text

    def parse_from_job_link(
        self, link_url: str, fallback_company: str, fallback_role: str, fallback_location: str
    ) -> tuple[str, str, str, str]:
        if not link_url:
            return fallback_company, fallback_role, fallback_location, "No LinkedIn job link found in this email."
        if link_url in self.job_cache:
            return self.job_cache[link_url]

        job_id = extract_job_id(link_url)
        if not job_id:
            lower = link_url.lower()
            if re.search(r"/(?:comm/)?company/[^/]+/jobs/?(?:$|\?)", lower):
                result = (
                    fallback_company,
                    fallback_role,
                    fallback_location,
                    "Ссылка ведет на страницу вакансий компании в LinkedIn (без конкретного job posting ID).",
                )
            elif "/jobs/search/" in lower:
                result = (
                    fallback_company,
                    fallback_role,
                    fallback_location,
                    "Ссылка ведет на страницу поиска вакансий LinkedIn (без конкретного job posting ID).",
                )
            else:
                result = (fallback_company, fallback_role, fallback_location, "Failed to extract job ID from URL.")
            self.job_cache[link_url] = result
            return result

        api_url = f"https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/{job_id}"
        req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read().decode("utf-8", errors="ignore")
        except Exception as exc:  # pragma: no cover - network dependent
            result = (fallback_company, fallback_role, fallback_location, f"Failed to load About the job: {exc}")
            self.job_cache[link_url] = result
            return result

        role = fallback_role
        company = fallback_company
        location = fallback_location
        about = "About the job section not found."

        about_match = re.search(r'(?is)<div class="show-more-less-html__markup[^>]*>(.*?)</div>', raw)
        if about_match:
            parsed_about = strip_html_to_text(about_match.group(1))
            if parsed_about:
                about = parsed_about

        result = (company, role, location, about)
        self.job_cache[link_url] = result
        return result

    def upsert_from_file(self, path: Path) -> set[str]:
        text = path.read_text(encoding="utf-8", errors="ignore")
        date_match = path.name.split("_", 1)[0]
        email_date = date_match if len(date_match) == 10 and date_match.count("-") == 2 else ""
        subject = extract_subject(text)
        company_fallback = extract_company(text, path.name) or "Unknown"
        links = self.extract_job_links(text)
        offers_from_blocks = self.extract_offers_from_email(text)
        status = self.infer_status(text, links)
        records: list[tuple[str, str]] = []
        if links:
            for link in links:
                canonical_link = self.canonicalize_job_url(link)
                records.append((link, canonical_link))
        else:
            records.append(("", ""))

        touched_keys: set[str] = set()
        cur = self.conn.cursor()
        for raw_link_url, canonical_link in records:
            if canonical_link and canonical_link in offers_from_blocks:
                role_text, company_text, location_text = offers_from_blocks[canonical_link]
            else:
                role_text, company_text, location_text = self.extract_company_role_location_for_link(
                    text, canonical_link, company_fallback, raw_link_url=raw_link_url
                )
            stored_link_url = raw_link_url or canonical_link
            key_link_url = canonical_link or raw_link_url
            if key_link_url:
                record_key = self.record_key_for_offer(company_text, role_text, location_text, key_link_url)
            else:
                record_key = f"{str(path)}::0::no-link"
            cur.execute(
                "SELECT manual_status, about_job_text_en, about_job_text_ru, about_job_text FROM applications WHERE record_key = ?",
                (record_key,),
            )
            row = cur.fetchone()
            if row is not None:
                existing_about_en = str(row[1] or "")
                existing_about_ru = str(row[2] or "")
                legacy_about = str(row[3] or "")
                if not existing_about_en and not existing_about_ru and legacy_about:
                    if self._looks_russian(legacy_about):
                        existing_about_ru = legacy_about
                    else:
                        existing_about_en = legacy_about
                # Existing record: keep the current description/translation as-is.
                # Translation to RU is done only for newly inserted records.
                company, role, location = company_text, role_text, location_text
                about_en = existing_about_en
                about_ru = existing_about_ru
                about_legacy = about_ru or about_en or legacy_about

                # Existing record: refresh data from new source file while preserving manual/pinned status.
                existing_manual_status = str(row[0]) if row[0] else None
                pinned_status = self.get_pinned_status(record_key)
                manual_status = existing_manual_status or pinned_status
                current_status = manual_status or status
                cur.execute(
                    """
                    UPDATE applications
                    SET source_file = ?, file_name = ?, email_date = ?, subject = ?,
                        company = ?, role = ?, location = ?, link_url = ?, about_job_text = ?, about_job_text_en = ?, about_job_text_ru = ?,
                        auto_status = ?, manual_status = ?, current_status = ?, body = ?,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE record_key = ?
                    """,
                    (
                        str(path),
                        path.name,
                        email_date,
                        subject,
                        company,
                        role,
                        location,
                        stored_link_url,
                        about_legacy,
                        about_en,
                        about_ru,
                        status,
                        manual_status,
                        current_status,
                        text,
                        record_key,
                    ),
                )
                touched_keys.add(record_key)
                continue

            company, role, location, about_original = self.parse_from_job_link(
                key_link_url, company_text, role_text, location_text
            )
            about_en = about_original
            about_ru = self.translate_to_russian(about_en) if about_en else ""
            about_legacy = about_ru or about_en
            pinned_status = self.get_pinned_status(record_key)
            manual_status = pinned_status
            current_status = manual_status or status

            cur.execute(
                """
                INSERT INTO applications(
                    record_key, source_file, file_name, email_date, subject, company, role, location, link_url, about_job_text,
                    about_job_text_en, about_job_text_ru,
                    auto_status, manual_status, current_status, body, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(record_key) DO UPDATE SET
                    source_file = excluded.source_file,
                    file_name = excluded.file_name,
                    email_date = excluded.email_date,
                    subject = excluded.subject,
                    company = excluded.company,
                    role = excluded.role,
                    location = excluded.location,
                    link_url = excluded.link_url,
                    about_job_text = excluded.about_job_text,
                    about_job_text_en = excluded.about_job_text_en,
                    about_job_text_ru = excluded.about_job_text_ru,
                    auto_status = excluded.auto_status,
                    current_status = COALESCE(applications.manual_status, excluded.auto_status),
                    body = excluded.body,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (
                    record_key,
                    str(path),
                    path.name,
                    email_date,
                    subject,
                    company,
                    role,
                    location,
                    stored_link_url,
                    about_legacy,
                    about_en,
                    about_ru,
                    status,
                    manual_status,
                    current_status,
                    text,
                ),
            )
            touched_keys.add(record_key)
        return touched_keys

    def translate_existing_about_job_texts(self) -> tuple[int, int]:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT id, COALESCE(about_job_text_en, ''), COALESCE(about_job_text_ru, ''), COALESCE(about_job_text, '')
            FROM applications
            """
        )
        rows = cur.fetchall()
        checked = 0
        updated = 0
        for app_id, about_en_raw, about_ru_raw, legacy_raw in rows:
            about_en = str(about_en_raw or "")
            about_ru = str(about_ru_raw or "")
            legacy = str(legacy_raw or "")
            if not about_en and legacy and not self._looks_russian(legacy):
                about_en = legacy
            if not about_ru and legacy and self._looks_russian(legacy):
                about_ru = legacy
            if not about_en:
                continue
            checked += 1
            if about_ru and self._looks_russian(about_ru):
                continue
            translated = self.translate_to_russian(about_en)
            if translated and translated != about_en:
                cur.execute(
                    """
                    UPDATE applications
                    SET about_job_text_ru = ?, about_job_text = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                    (translated, translated, int(app_id)),
                )
                updated += 1
        self.conn.commit()
        return checked, updated

    def sync_source_dir(self, source_dir: Path) -> tuple[int, int]:
        if not source_dir.exists() or not source_dir.is_dir():
            raise NotADirectoryError(str(source_dir))

        files = sorted(source_dir.glob("*.txt"))

        def file_priority(path: Path) -> tuple[int, str]:
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except Exception:
                return (99, path.name.lower())
            links = self.extract_job_links(text)
            status = self.infer_status(text, links)
            priority_order = {
                "incoming": 0,
                "applied": 1,
                "rejected": 2,
                "interview": 3,
                "manual_sort": 4,
            }
            return (priority_order.get(status, 50), path.name.lower())

        files.sort(key=file_priority)
        fresh_keys: set[str] = set()

        for path in files:
            fresh_keys |= self.upsert_from_file(path.resolve())

        cur = self.conn.cursor()
        cur.execute("SELECT record_key FROM applications")
        known = {str(row[0]) for row in cur.fetchall()}
        to_delete = known - fresh_keys
        if to_delete:
            cur.executemany("DELETE FROM applications WHERE record_key = ?", [(k,) for k in to_delete])

        self.conn.commit()
        return len(files), len(to_delete)

    def get_status_counts(self) -> dict[str, int]:
        counts = {k: 0 for k in STATUS_ORDER}
        cur = self.conn.cursor()
        cur.execute("SELECT current_status, COUNT(*) FROM applications GROUP BY current_status")
        for status, n in cur.fetchall():
            if status in counts:
                counts[status] = int(n)
        return counts

    def get_by_status(self, status: str) -> list[ApplicationRow]:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT id, source_file, file_name, email_date, subject, company, role, link_url,
                   location, auto_status, manual_status, current_status, body,
                   COALESCE(NULLIF(about_job_text_ru, ''), NULLIF(about_job_text, ''), NULLIF(about_job_text_en, '')) AS about_job_text,
                   COALESCE(NULLIF(about_job_text_en, ''), NULLIF(about_job_text, '')) AS about_job_text_en,
                   COALESCE(NULLIF(about_job_text_ru, ''), NULLIF(about_job_text, '')) AS about_job_text_ru
            FROM applications
            WHERE current_status = ?
            ORDER BY company COLLATE NOCASE, email_date DESC, file_name COLLATE NOCASE
            """,
            (status,),
        )
        rows = []
        for r in cur.fetchall():
            rows.append(
                ApplicationRow(
                    id=int(r[0]),
                    source_file=str(r[1]),
                    file_name=str(r[2]),
                    email_date=str(r[3] or ""),
                    subject=str(r[4] or ""),
                    company=str(r[5] or "Unknown"),
                    role=str(r[6] or ""),
                    location=str(r[8] or ""),
                    link_url=str(r[7] or ""),
                    auto_status=str(r[9]),
                    manual_status=str(r[10]) if r[10] else None,
                    current_status=str(r[11]),
                    body=str(r[12]),
                    about_job_text=str(r[13] or ""),
                    about_job_text_en=str(r[14] or ""),
                    about_job_text_ru=str(r[15] or ""),
                )
            )
        return rows

    def get_by_id(self, app_id: int) -> Optional[ApplicationRow]:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT id, source_file, file_name, email_date, subject, company, role, link_url,
                   location, auto_status, manual_status, current_status, body,
                   COALESCE(NULLIF(about_job_text_ru, ''), NULLIF(about_job_text, ''), NULLIF(about_job_text_en, '')) AS about_job_text,
                   COALESCE(NULLIF(about_job_text_en, ''), NULLIF(about_job_text, '')) AS about_job_text_en,
                   COALESCE(NULLIF(about_job_text_ru, ''), NULLIF(about_job_text, '')) AS about_job_text_ru
            FROM applications
            WHERE id = ?
            """,
            (app_id,),
        )
        r = cur.fetchone()
        if not r:
            return None
        return ApplicationRow(
            id=int(r[0]),
            source_file=str(r[1]),
            file_name=str(r[2]),
            email_date=str(r[3] or ""),
            subject=str(r[4] or ""),
            company=str(r[5] or "Unknown"),
            role=str(r[6] or ""),
            location=str(r[8] or ""),
            link_url=str(r[7] or ""),
            auto_status=str(r[9]),
            manual_status=str(r[10]) if r[10] else None,
            current_status=str(r[11]),
            body=str(r[12]),
            about_job_text=str(r[13] or ""),
            about_job_text_en=str(r[14] or ""),
            about_job_text_ru=str(r[15] or ""),
        )

    def ensure_about_job_text(self, app_id: int) -> str:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT link_url, company, role, location,
                   COALESCE(about_job_text_en, ''),
                   COALESCE(about_job_text_ru, ''),
                   COALESCE(about_job_text, '')
            FROM applications WHERE id = ?
            """,
            (app_id,),
        )
        row = cur.fetchone()
        if not row:
            raise ValueError("Application not found")

        link_url = str(row[0] or "")
        company = str(row[1] or "Unknown")
        role = str(row[2] or "")
        location = str(row[3] or "")
        existing_en = str(row[4] or "")
        existing_ru = str(row[5] or "")
        legacy = str(row[6] or "")
        if not existing_en and legacy and not self._looks_russian(legacy):
            existing_en = legacy
        if not existing_ru and legacy and self._looks_russian(legacy):
            existing_ru = legacy

        if existing_en:
            translated = existing_ru or self.translate_to_russian(existing_en)
            if translated and translated != existing_ru:
                cur.execute(
                    """
                    UPDATE applications
                    SET about_job_text_en = ?, about_job_text_ru = ?, about_job_text = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                    (existing_en, translated, translated or existing_en, app_id),
                )
                self.conn.commit()
            return translated or existing_en

        parsed_company, parsed_role, parsed_location, about_en = self.parse_from_job_link(link_url, company, role, location)
        about_ru = self.translate_to_russian(about_en) if about_en else ""
        display_about = about_ru or about_en
        cur.execute(
            """
            UPDATE applications
            SET company = ?, role = ?, location = ?, about_job_text_en = ?, about_job_text_ru = ?, about_job_text = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (parsed_company, parsed_role, parsed_location, about_en, about_ru, display_about, app_id),
        )
        self.conn.commit()
        return display_about

    def set_manual_status(self, app_id: int, status: Optional[str]) -> None:
        cur = self.conn.cursor()
        if status is not None and status not in STATUS_ORDER:
            raise ValueError(f"Invalid status: {status}")

        cur.execute("SELECT record_key, auto_status FROM applications WHERE id = ?", (app_id,))
        row = cur.fetchone()
        if not row:
            raise ValueError("Application not found")

        record_key = str(row[0])
        auto_status = str(row[1])
        current_status = status or auto_status
        cur.execute(
            """
            UPDATE applications
            SET manual_status = ?, current_status = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (status, current_status, app_id),
        )
        self.set_pinned_status(record_key, current_status if current_status != "incoming" else None)
        self.conn.commit()


if GUI_AVAILABLE:
    class MainWindow(QMainWindow):
        def __init__(self, db: ApplicationsDB, source_dir: Path) -> None:
            super().__init__()
            self.db = db
            self.source_dir = source_dir
            self.selected_app_id: Optional[int] = None

            self.setWindowTitle("LinkInJob")
            self.resize(1280, 800)

            self._build_ui()
            self.sync_source()

        def _build_ui(self) -> None:
            toolbar = QToolBar("Main")
            toolbar.setMovable(False)
            self.addToolBar(toolbar)

            self.source_input = QLineEdit(str(self.source_dir))
            self.source_input.setMinimumWidth(520)
            toolbar.addWidget(QLabel("Data source: "))
            toolbar.addWidget(self.source_input)

            sync_btn = QAction("Sync", self)
            sync_btn.triggered.connect(self.sync_source)
            toolbar.addAction(sync_btn)

            sync_drive_btn = QAction("Sync Drive + Sync DB", self)
            sync_drive_btn.triggered.connect(self.sync_drive_and_source)
            toolbar.addAction(sync_drive_btn)

            reload_btn = QAction("Reload", self)
            reload_btn.triggered.connect(self.reload_tree)
            toolbar.addAction(reload_btn)

            main = QWidget()
            root_layout = QVBoxLayout(main)
            root_layout.setContentsMargins(8, 8, 8, 8)

            splitter = QSplitter(Qt.Horizontal)
            root_layout.addWidget(splitter)

            left_frame = QFrame()
            left_layout = QVBoxLayout(left_frame)
            left_layout.setContentsMargins(0, 0, 0, 0)
            self.tree = QTreeWidget()
            self.tree.setHeaderLabels(["Applications"])
            self.tree.header().setStretchLastSection(False)
            self.tree.header().setSectionResizeMode(0, QHeaderView.Interactive)
            self.tree.setColumnWidth(0, 680)
            self.tree.setMinimumWidth(640)
            self.tree.itemSelectionChanged.connect(self.on_tree_selection)
            left_layout.addWidget(self.tree)
            left_frame.setMinimumWidth(640)

            right_frame = QFrame()
            right_layout = QVBoxLayout(right_frame)

            details = QFormLayout()
            self.company_label = QLabel("-")
            self.status_label = QLabel("-")
            self.auto_status_label = QLabel("-")
            self.date_label = QLabel("-")
            self.subject_label = QLabel("-")
            self.file_label = QLabel("-")
            self.role_label = QLabel("-")
            self.location_label = QLabel("-")
            self.link_state_label = QLabel("-")

            details.addRow("Company:", self.company_label)
            details.addRow("Status:", self.status_label)
            details.addRow("Auto status:", self.auto_status_label)
            details.addRow("Date:", self.date_label)
            details.addRow("Subject:", self.subject_label)
            details.addRow("Должность:", self.role_label)
            details.addRow("Локация:", self.location_label)
            details.addRow("File:", self.file_label)
            details.addRow("Job link:", self.link_state_label)
            right_layout.addLayout(details)

            controls_layout = QVBoxLayout()
            controls_row_1 = QHBoxLayout()
            controls_row_2 = QHBoxLayout()

            manual_move_order = ["applied", "interview", "rejected", "manual_sort", "archive"]
            for status in manual_move_order:
                btn = QPushButton(f"Move to {STATUS_TITLE[status]}")
                btn.clicked.connect(lambda _checked=False, s=status: self.set_status(s))
                controls_row_1.addWidget(btn)

            clear_btn = QPushButton("Reset to Auto")
            clear_btn.clicked.connect(lambda: self.set_status(None))
            controls_row_2.addWidget(clear_btn)

            self.open_source_btn = QPushButton("Open Source File")
            self.open_source_btn.clicked.connect(self.open_source_file)
            controls_row_2.addWidget(self.open_source_btn)

            self.open_job_btn = QPushButton("Open Job Link")
            self.open_job_btn.clicked.connect(self.open_job_link)
            self.open_job_btn.setEnabled(False)
            controls_row_2.addWidget(self.open_job_btn)
            controls_row_2.addStretch(1)

            controls_layout.addLayout(controls_row_1)
            controls_layout.addLayout(controls_row_2)
            right_layout.addLayout(controls_layout)

            self.about_job_text = QTextEdit()
            self.about_job_text.setReadOnly(True)
            right_layout.addWidget(self.about_job_text)

            splitter.addWidget(left_frame)
            splitter.addWidget(right_frame)
            splitter.setSizes([700, 860])
            splitter.setStretchFactor(0, 2)
            splitter.setStretchFactor(1, 3)

            self.status_bar_label = QLabel("Ready")
            right_layout.addWidget(self.status_bar_label)

            self.setCentralWidget(main)

        def show_error(self, title: str, message: str) -> None:
            QMessageBox.critical(self, title, message)

        @staticmethod
        def resolve_rclone_bin() -> Optional[str]:
            env_bin = os.getenv("RCLONE_BIN", "").strip()
            candidates = [
                env_bin,
                shutil.which("rclone") or "",
                "/opt/homebrew/bin/rclone",
                "/usr/local/bin/rclone",
                "/usr/bin/rclone",
            ]
            for candidate in candidates:
                if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
            return None

        def sync_source(self) -> None:
            source = Path(self.source_input.text().strip()).expanduser()
            if not source.exists() or not source.is_dir():
                self.show_error("Invalid source", f"Directory not found:\n{source}")
                return

            try:
                self.db.snapshot_non_incoming_statuses()
                scanned, removed = self.db.sync_source_dir(source)
            except Exception as exc:
                self.show_error("Sync failed", str(exc))
                return

            self.source_dir = source
            self.status_bar_label.setText(f"Synced: {scanned} files, removed: {removed}")
            self.reload_tree()

        def sync_drive_and_source(self) -> None:
            source = Path(self.source_input.text().strip()).expanduser()
            source.mkdir(parents=True, exist_ok=True)
            rclone_bin = self.resolve_rclone_bin()
            if not rclone_bin:
                self.show_error(
                    "Drive sync failed",
                    "rclone is not installed or not found. "
                    "Expected one of: /opt/homebrew/bin/rclone, /usr/local/bin/rclone, or PATH.",
                )
                return

            self.status_bar_label.setText("Syncing Google Drive...")
            QApplication.processEvents()
            try:
                result = subprocess.run(
                    [
                        rclone_bin,
                        "copy",
                        f"{DRIVE_REMOTE}:",
                        str(source),
                        "--drive-root-folder-id",
                        DRIVE_FOLDER_ID,
                        "--create-empty-src-dirs",
                        "--transfers",
                        "4",
                        "--checkers",
                        "8",
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            except FileNotFoundError:
                self.show_error("Drive sync failed", f"Cannot execute rclone binary: {rclone_bin}")
                return

            if result.returncode != 0:
                error_text = (result.stderr or result.stdout or "Unknown rclone error").strip()
                self.show_error("Drive sync failed", error_text[-4000:])
                return

            try:
                self.db.snapshot_non_incoming_statuses()
                scanned, removed = self.db.sync_source_dir(source)
            except Exception as exc:
                self.show_error("Sync failed", str(exc))
                return

            self.source_dir = source
            self.status_bar_label.setText(f"Drive + DB synced: {scanned} files, removed: {removed}")
            self.reload_tree()

        def reset_db_and_sync(self) -> None:
            confirm = QMessageBox.question(
                self,
                "Reset database",
                "Delete all records from SQL and reload from source folder?",
            )
            if confirm != QMessageBox.Yes:
                return
            try:
                self.db.snapshot_non_incoming_statuses()
                self.db.reset_all()
            except Exception as exc:
                self.show_error("Reset failed", str(exc))
                return
            self.status_bar_label.setText("Database reset. Running full sync...")
            self.sync_source()

        def reload_tree(self) -> None:
            previous_id = self.selected_app_id
            self.tree.clear()
            counts = self.db.get_status_counts()

            for status in STATUS_ORDER:
                section = QTreeWidgetItem([f"{STATUS_TITLE[status]} ({counts[status]})"])
                section.setData(0, Qt.UserRole, ("group", status))
                self.tree.addTopLevelItem(section)

                items = self.db.get_by_status(status)
                for app in items:
                    caption = f"{app.company}"
                    if app.role:
                        caption = f"{caption} | {app.role}"
                    if app.location:
                        caption = f"{caption} | {app.location}"
                    child = QTreeWidgetItem([caption])
                    child.setToolTip(0, app.subject or app.file_name)
                    child.setData(0, Qt.UserRole, ("app", app.id))
                    section.addChild(child)

                section.setExpanded(True)

            if previous_id is not None:
                self.select_app(previous_id)

        def select_app(self, app_id: int) -> None:
            root = self.tree.invisibleRootItem()
            for i in range(root.childCount()):
                group = root.child(i)
                for j in range(group.childCount()):
                    child = group.child(j)
                    data = child.data(0, Qt.UserRole)
                    if data and data[0] == "app" and data[1] == app_id:
                        self.tree.setCurrentItem(child)
                        return

        @staticmethod
        def format_date(date_raw: str) -> str:
            try:
                return datetime.strptime(date_raw, "%Y-%m-%d").strftime("%d.%m.%Y")
            except Exception:
                return date_raw

        def on_tree_selection(self) -> None:
            item = self.tree.currentItem()
            if not item:
                return

            data = item.data(0, Qt.UserRole)
            if not data or data[0] != "app":
                self.selected_app_id = None
                self.company_label.setText("-")
                self.status_label.setText("-")
                self.auto_status_label.setText("-")
                self.date_label.setText("-")
                self.subject_label.setText("-")
                self.role_label.setText("-")
                self.location_label.setText("-")
                self.file_label.setText("-")
                self.link_state_label.setText("-")
                self.open_job_btn.setEnabled(False)
                self.about_job_text.setPlainText("")
                return

            app_id = int(data[1])
            app = self.db.get_by_id(app_id)
            if not app:
                return

            self.selected_app_id = app_id
            status_title = STATUS_TITLE.get(app.current_status, app.current_status)
            auto_title = STATUS_TITLE.get(app.auto_status, app.auto_status)

            self.company_label.setText(app.company)
            self.status_label.setText(status_title)
            self.auto_status_label.setText(auto_title)
            self.date_label.setText(self.format_date(app.email_date))
            self.subject_label.setText(app.subject or "-")
            self.role_label.setText(app.role or "-")
            self.location_label.setText(app.location or "-")
            self.file_label.setText(app.file_name)
            self.link_state_label.setText("Available" if app.link_url else "Not found")
            self.open_job_btn.setEnabled(bool(app.link_url))
            self.about_job_text.setPlainText("Loading About the job...")
            QApplication.processEvents()

            about_text = app.about_job_text
            if not about_text:
                try:
                    about_text = self.db.ensure_about_job_text(app.id)
                except Exception as exc:
                    about_text = f"Failed to load About the job: {exc}"
            self.about_job_text.setPlainText(about_text)

            mode = "manual" if app.manual_status else "auto"
            self.status_bar_label.setText(f"Selected #{app.id} ({mode})")

        def set_status(self, status: Optional[str]) -> None:
            if self.selected_app_id is None:
                self.show_error("No selection", "Select an application first.")
                return
            try:
                self.db.set_manual_status(self.selected_app_id, status)
            except Exception as exc:
                self.show_error("Update failed", str(exc))
                return

            self.reload_tree()
            if self.selected_app_id is not None:
                self.select_app(self.selected_app_id)

        def open_source_file(self) -> None:
            if self.selected_app_id is None:
                self.show_error("No selection", "Select an application first.")
                return
            app = self.db.get_by_id(self.selected_app_id)
            if not app:
                self.show_error("Missing application", "Record no longer exists.")
                return

            path = app.source_file
            if not os.path.exists(path):
                self.show_error("File not found", path)
                return

            if sys.platform == "darwin":
                subprocess.run(["open", path], check=False)
            elif os.name == "nt":
                os.startfile(path)  # type: ignore[attr-defined]
            else:
                subprocess.run(["xdg-open", path], check=False)

        def open_job_link(self) -> None:
            if self.selected_app_id is None:
                self.show_error("No selection", "Select an application first.")
                return
            app = self.db.get_by_id(self.selected_app_id)
            if not app:
                self.show_error("Missing application", "Record no longer exists.")
                return
            if not app.link_url:
                self.show_error("No link", "No LinkedIn job link found in selected email.")
                return

            if sys.platform == "darwin":
                subprocess.run(["open", app.link_url], check=False)
            elif os.name == "nt":
                os.startfile(app.link_url)  # type: ignore[attr-defined]
            else:
                subprocess.run(["xdg-open", app.link_url], check=False)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GUI app for LinkedIn applications with SQL status management.")
    parser.add_argument(
        "--source-dir",
        default=str(Path.home() / "Library" / "Application Support" / "DriveCVSync" / "LinkedIn Archive"),
        help="Directory with LinkedIn *.txt emails.",
    )
    parser.add_argument(
        "--db",
        default=str(DEFAULT_DB_PATH),
        help="SQLite database file path.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_dir = Path(args.source_dir).expanduser().resolve()
    if not GUI_AVAILABLE:
        print("PySide6 is required for GUI mode.")
        print("Install with: python3 -m pip install PySide6")
        if GUI_IMPORT_ERROR is not None:
            print(f"Import error: {GUI_IMPORT_ERROR}")
        raise SystemExit(1)

    app = QApplication(sys.argv)
    db = ApplicationsDB(args.db)

    window = MainWindow(db=db, source_dir=source_dir)
    window.show()

    exit_code = app.exec()
    db.close()
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()

"""Schlanker Client für die REST-API von NV-AI (FastAPI, Standard: http://127.0.0.1:8100)."""
from __future__ import annotations

import io
import time
from typing import Any

import httpx
from PIL import Image

from . import i18n
from .i18n import t


# Vertragsversion der NV-AI-API, die diese Brücke spricht (GET /api/version → "api"). Sie steigt
# nur bei brechenden Änderungen; der Vertrag liegt in contract/nvai-openapi.json.
API_VERSION = 1


class NVAIError(RuntimeError):
    """NV-AI hat eine Anfrage abgelehnt oder ein Auftrag ist gescheitert."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status  # HTTP-Status, wenn die Ablehnung von NV-AI selbst kam


class NVAIUnavailable(NVAIError):
    """NV-AI ist nicht erreichbar."""


class NVAIIncompatible(NVAIError):
    """NV-AI ist erreichbar, aber nicht nutzbar: andere Vertragsversion oder Zugriff verweigert."""


class NVAI:
    def __init__(self, base_url: str, token: str | None = None,
                 transport: httpx.BaseTransport | None = None) -> None:
        self.base_url = base_url
        headers = {"X-NVAI-Token": token} if token else {}
        self._http = httpx.Client(
            base_url=base_url, headers=headers, timeout=httpx.Timeout(30.0, connect=2.0),
            transport=transport,  # nur für Tests (Vertragsprüfung ohne laufendes NV-AI)
        )
        self._mask_support: tuple[float, bool] | None = None
        self._version: tuple[float, dict[str, Any] | None] | None = None

    def set_token(self, token: str | None) -> None:
        """Token tauschen, etwa nachdem er in settings.json eingetragen wurde."""
        if token:
            self._http.headers["X-NVAI-Token"] = token
        else:
            self._http.headers.pop("X-NVAI-Token", None)
        self.forget()

    def forget(self) -> None:
        """Gemerkte Versions- und Maskenangaben verwerfen (nach Neustart oder Tokenwechsel)."""
        self._version = None
        self._mask_support = None

    def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        # NV-AI liefert Modelltexte und Fehlermeldungen in dieser Sprache (ohne Angabe Englisch).
        kwargs["headers"] = {"Accept-Language": i18n.lang(), **kwargs.get("headers", {})}
        try:
            r = self._http.request(method, path, **kwargs)
        except httpx.TransportError as exc:
            raise NVAIUnavailable(t(f"NV-AI ist nicht erreichbar ({self.base_url}).",
                                    f"NV-AI is not reachable ({self.base_url}).")) from exc
        if r.status_code >= 400:
            try:
                detail = r.json().get("detail", r.text)
            except ValueError:
                detail = r.text
            raise NVAIError(t(f"NV-AI meldet {r.status_code}: {detail}", f"NV-AI reports {r.status_code}: {detail}"),
                            status=r.status_code)
        if r.headers.get("content-type", "").startswith("application/json"):
            return r.json()
        return r.content

    # ------------------------------------------------------------- Abfragen

    def health(self) -> dict[str, Any]:
        return self._request("GET", "/api/health", timeout=4.0)

    def image_models(self) -> list[dict[str, Any]]:
        return self._request("GET", "/api/models", params={"kind": "image"})

    def version(self) -> dict[str, Any] | None:
        """``GET /api/version`` (ohne Token abrufbar, 30 s gemerkt); ``None`` bei Servern vor 0.2.0.

        ``api`` ist die Vertragsversion, ``features`` nennt die bekannten Anfragefelder (``mask``,
        ``references``, ``upsampler`` …), ``authorized`` sagt, ob Anfragen von hier durchkämen.
        """
        now = time.monotonic()
        if self._version and now - self._version[0] < 30:
            return self._version[1]
        try:
            info = self._request("GET", "/api/version", timeout=4.0)
        except NVAIError as exc:
            if exc.status != 404:
                raise
            info = None
        self._version = (now, info if isinstance(info, dict) else None)
        return self._version[1]

    def check_compatible(self) -> dict[str, Any] | None:
        """Vertragsversion und Zugriff prüfen; wirft ``NVAIIncompatible`` mit Klartext."""
        info = self.version()
        if info is None:
            return None  # älter als 0.2.0 – ohne Versionsangabe, wie bisher nutzbar
        if info.get("api") != API_VERSION:
            raise NVAIIncompatible(t(
                f"NV-AI {info.get('version', '?')} spricht API-Version {info.get('api')}, diese Brücke "
                f"Version {API_VERSION}. Bitte Brücke oder NV-AI aktualisieren.",
                f"NV-AI {info.get('version', '?')} speaks API version {info.get('api')}, this bridge "
                f"version {API_VERSION}. Please update the bridge or NV-AI.",
            ))
        if not info.get("authorized", True):
            if info.get("auth") == "local":
                # Ohne Token bedient NV-AI nur den eigenen Rechner (Antwort 403).
                raise NVAIIncompatible(t(
                    "NV-AI nimmt nur Anfragen vom eigenen Rechner an. Für den Zugriff von hier NV-AI "
                    "dort mit „scripts\\start.ps1 -Lan“ starten und dessen Token (data\\api_token) "
                    "in settings.json als „nvai_token“ eintragen.",
                    "NV-AI only accepts requests from its own computer. To use it from here, start NV-AI "
                    "there with \"scripts\\start.ps1 -Lan\" and put its token (data\\api_token) into "
                    "settings.json as \"nvai_token\".",
                ))
            raise NVAIIncompatible(t(
                "NV-AI lehnt den Zugriff ab: Token fehlt oder ist falsch. Den Token von NV-AI "
                "(NVAI_TOKEN bzw. data\\api_token) in settings.json als „nvai_token“ eintragen.",
                "NV-AI refuses access: the token is missing or wrong. Put the NV-AI token "
                "(NVAI_TOKEN or data\\api_token) into settings.json as \"nvai_token\".",
            ))
        return info

    def supports_masks(self) -> bool:
        """Kennt die laufende NV-AI-Version ``mask_asset_id``?

        Ältere Server würden das Feld stillschweigend ignorieren und den ganzen Ausschnitt neu
        rechnen. Ab NV-AI 0.2.0 steht es in ``/api/version`` unter ``features``; davor wird in
        ``/openapi.json`` nachgesehen (Ergebnis 60 s gemerkt).
        """
        info = self.version()
        if info is not None:
            return "mask" in (info.get("features") or [])
        now = time.monotonic()
        if self._mask_support and now - self._mask_support[0] < 60:
            return self._mask_support[1]
        spec = self._request("GET", "/openapi.json", timeout=4.0)
        props = (
            spec.get("components", {}).get("schemas", {})
            .get("GenerateImageRequest", {}).get("properties", {})
        )
        ok = "mask_asset_id" in props
        self._mask_support = (now, ok)
        return ok

    def supports_outpaint(self) -> bool:
        """Kennt NV-AI ``outpaint`` (ab 0.5.4)? Dann legt der Server Rand und Maske selbst an."""
        info = self.version()
        return info is not None and "outpaint" in (info.get("features") or [])

    def supports_expand(self) -> bool:
        """Kennt die laufende NV-AI ``POST /api/prompt/expand`` („Prompt ausbauen“)?"""
        info = self.version()
        return info is not None and "expand_prompt" in (info.get("features") or [])

    def supports_cancel_job(self) -> bool:
        """Kennt NV-AI ``POST /api/jobs/{id}/cancel`` (ab 0.5.2: Downloads brechen sofort ab)?"""
        info = self.version()
        return info is not None and "cancel_job" in (info.get("features") or [])

    def downloads(self) -> list[dict[str, Any]]:
        """Laufende und wartende Modell-Downloads von NV-AI (Windows und Mac)."""
        out = []
        for j in self._request("GET", "/api/jobs", params={"limit": 50}, timeout=4.0):
            if j.get("kind") != "download" or j.get("status") not in ("queued", "running"):
                continue
            p = j.get("params") or {}
            name = p.get("name") or (p.get("entry") or {}).get("name") or p.get("model_id") or j["id"]
            out.append({"job": j["id"], "name": name, "status": j["status"],
                        "progress": j.get("progress") or 0.0, "stage": j.get("stage") or ""})
        return out

    def cancel_download(self, job_id: str) -> None:
        """Einen Download abbrechen. Ältere NV-AI kennen nur „alle Downloads abbrechen“."""
        if self.supports_cancel_job():
            self._request("POST", f"/api/jobs/{job_id}/cancel")
        else:
            self._request("POST", "/api/downloads/cancel")

    def assets(self, kind: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"limit": limit}
        if kind:
            params["kind"] = kind
        return self._request("GET", "/api/assets", params=params)

    def job(self, job_id: str) -> dict[str, Any]:
        return self._request("GET", f"/api/jobs/{job_id}")

    def asset(self, asset_id: str) -> dict[str, Any]:
        return self._request("GET", f"/api/assets/{asset_id}")

    def fetch_image(self, asset: dict[str, Any]) -> Image.Image:
        data = self._request("GET", asset["url"], timeout=60.0)
        img = Image.open(io.BytesIO(data))
        img.load()
        return img

    # ------------------------------------------------------------ Aufträge

    def upload(self, img: Image.Image, name: str) -> dict[str, Any]:
        buf = io.BytesIO()
        img.save(buf, "PNG", compress_level=3)
        return self._request(
            "POST", "/api/upload", files={"file": (name, buf.getvalue(), "image/png")}, timeout=60.0
        )

    def generate_image(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self._request("POST", "/api/generate/image", json=payload)

    def expand_prompt(self, prompt: str, width: int = 1024, height: int = 1024) -> dict[str, Any]:
        """Knappen Prompt zur vollen Bildbeschreibung ausbauen (FLUX-3-Upsampler, für jedes
        Bildmodell). Blockiert, bis NV-AI fertig ist; wartet hinter einem laufenden Bild."""
        return self._request("POST", "/api/prompt/expand", timeout=960.0,
                             json={"prompt": prompt, "width": width, "height": height})

    def cancel(self, job_id: str) -> None:
        """Nur den eigenen Auftrag stoppen – NV-AI wird womöglich gerade auch anderweitig benutzt."""
        job = self.job(job_id)
        if job["status"] == "queued":
            # Wartende Aufträge überspringt der Worker, sobald ihr Eintrag fehlt.
            self._request("DELETE", f"/api/jobs/{job_id}")
        elif job["status"] == "running" and self.health().get("current_job") == job_id:
            self._request("POST", "/api/jobs/current/cancel")

    def delete_asset(self, asset_id: str) -> None:
        self._request("DELETE", f"/api/assets/{asset_id}")

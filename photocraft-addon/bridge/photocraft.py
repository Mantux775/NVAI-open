"""Client für den Steuerkanal einer laufenden PhotoCraft-Instanz.

PhotoCraft lauscht nur, wenn es mit ``--control <port>`` gestartet wurde (siehe
``launcher.py``). Die Einstellung „Agentensteuerung erlauben“ bewirkt in PhotoCraft 0.10
noch nichts. Protokoll: eine JSON-Zeile pro Anfrage, eine pro Antwort; die erste Zeile jeder
Verbindung meldet sich mit dem Token an (docs/control-protocol.md im PhotoCraft-Repository).
"""
from __future__ import annotations

import json
import socket
import threading
import time
from pathlib import Path
from typing import Any

from .i18n import t


class PhotoCraftError(RuntimeError):
    """PhotoCraft hat eine Anfrage abgelehnt oder die Verbindung ist abgerissen."""


class NotConnected(PhotoCraftError):
    """Kein PhotoCraft mit Steuerkanal erreichbar – es wurde nichts gesendet."""


class PhotoCraft:
    # PhotoCraft schließt Verbindungen nach 30 s Leerlauf. Wer länger still war, baut vor dem
    # nächsten Befehl neu auf, statt in eine womöglich schon tote Verbindung zu schreiben.
    IDLE_RECONNECT = 20.0
    # Der Server antwortet spätestens nach 60 s (dann mit "timeout: …").
    REPLY_TIMEOUT = 65.0

    def __init__(self, port: int, token_file: Path) -> None:
        self.port = port
        self.token_file = token_file
        self._sock: socket.socket | None = None
        self._io: Any = None
        self._last_used = 0.0
        self._next_id = 0
        self._lock = threading.RLock()

    # ------------------------------------------------------------ Verbindung

    def _token(self) -> str:
        try:
            token = self.token_file.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            raise NotConnected(t(
                "PhotoCraft wurde noch nicht mit NVAI-open-Anbindung gestartet.",
                "PhotoCraft has not been started with the NVAI-open connection yet.",
            )) from None
        if len(token) != 64:
            raise NotConnected(t(f"Die Token-Datei {self.token_file} ist ungültig.",
                                 f"The token file {self.token_file} is invalid."))
        return token

    def _connect(self) -> None:
        token = self._token()
        try:
            sock = socket.create_connection(("127.0.0.1", self.port), timeout=2.0)
        except OSError:
            raise NotConnected(t("PhotoCraft mit NVAI-open-Anbindung läuft nicht.",
                                 "PhotoCraft with the NVAI-open connection is not running.")) from None
        sock.settimeout(self.REPLY_TIMEOUT)
        self._sock, self._io = sock, sock.makefile("rwb")
        try:
            self._send("auth", {"token": token}, "auth")
            reply = self._receive("auth")
        except (OSError, ValueError, ConnectionError) as exc:
            self.close()
            raise NotConnected(t(f"Anmeldung bei PhotoCraft gescheitert ({exc}).",
                                 f"Sign-in to PhotoCraft failed ({exc}).")) from exc
        if not reply.get("ok"):
            self.close()
            raise NotConnected(t(f"PhotoCraft lehnt die Anmeldung ab: {reply.get('error')}",
                                 f"PhotoCraft refuses the sign-in: {reply.get('error')}"))

    def close(self) -> None:
        for obj in (self._io, self._sock):
            try:
                if obj is not None:
                    obj.close()
            except OSError:
                pass
        self._io = self._sock = None

    def _send(self, method: str, params: dict[str, Any], rid: Any) -> None:
        line = json.dumps({"id": rid, "method": method, "params": params}, ensure_ascii=False)
        self._io.write(line.encode("utf-8") + b"\n")
        self._io.flush()

    def _receive(self, rid: Any) -> dict[str, Any]:
        while True:
            raw = self._io.readline()
            if not raw:
                raise ConnectionError(t("PhotoCraft hat die Verbindung geschlossen", "PhotoCraft closed the connection"))
            reply = json.loads(raw)
            # Antworten mit fremder id (etwa auf eine abgebrochene Anfrage) überspringen.
            if reply.get("id") == rid:
                return reply

    # --------------------------------------------------------------- Aufrufe

    def call(self, method: str, params: dict[str, Any] | None = None, *, read: bool = False) -> Any:
        """Eine Anfrage senden und ihr ``result`` zurückgeben.

        ``read=True`` kennzeichnet reine Lesezugriffe: Die werden nach einem Verbindungsfehler
        einmal wiederholt. Bearbeitungen werden nie erneut gesendet, sobald sie einmal
        abgeschickt waren – PhotoCraft könnte sie bereits ausgeführt haben.
        """
        with self._lock:
            for attempt in (1, 2):
                if self._sock is not None and time.monotonic() - self._last_used > self.IDLE_RECONNECT:
                    self.close()
                if self._sock is None:
                    self._connect()
                self._next_id += 1
                rid = self._next_id
                try:
                    self._send(method, params or {}, rid)
                except OSError as exc:
                    # Nichts ist angekommen – ein zweiter Versuch ist gefahrlos.
                    self.close()
                    if attempt == 1:
                        continue
                    raise NotConnected(t(f"PhotoCraft ist nicht erreichbar ({exc}).",
                                         f"PhotoCraft is not reachable ({exc}).")) from exc
                try:
                    reply = self._receive(rid)
                except (OSError, ValueError, ConnectionError) as exc:
                    self.close()
                    if read and attempt == 1:
                        continue
                    raise PhotoCraftError(t(
                        f"Die Verbindung zu PhotoCraft ist während „{method}“ abgerissen ({exc}). "
                        "Der Befehl wurde eventuell trotzdem ausgeführt.",
                        f"The connection to PhotoCraft broke during \"{method}\" ({exc}). "
                        "The command may have been carried out anyway.",
                    )) from exc
                finally:
                    self._last_used = time.monotonic()
                if not reply.get("ok"):
                    raise PhotoCraftError(str(reply.get("error") or t("unbekannter Fehler", "unknown error")))
                return reply.get("result")
        raise AssertionError("unerreichbar")

    def execute(self, command: str, params: dict[str, Any] | None = None, *, read: bool = False) -> Any:
        """Einen Engine-Befehl ausführen (wie ``photocraft-cli commands`` sie auflistet)."""
        return self.call("engine.execute", {"command": command, "params": params or {}}, read=read)

    def inspect(self) -> dict[str, Any]:
        """UI-Zustand samt Sitzung (offene Dokumente, aktives Dokument) und aktivem Dokument."""
        return self.call("ui.inspect", read=True)

    def document(self) -> dict[str, Any]:
        return self.execute("document.inspect", read=True)

    def activate(self, index: int) -> None:
        """Dokument ``index`` (Reihenfolge der Tabs) nach vorn holen."""
        self.call("ui.menu.invoke", {"id": f"window.document.{index}"})

    def connected(self) -> bool:
        try:
            self.call("ui.inspect", read=True)
            return True
        except PhotoCraftError:
            return False

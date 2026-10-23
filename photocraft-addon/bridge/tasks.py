"""Aufträge: Kontext aus PhotoCraft holen, in NV-AI rechnen lassen, Ergebnis zurücklegen.

Ablauf eines Auftrags:

1. **Erfassen** – Vom aktiven Dokument entsteht eine reduzierte Arbeitskopie
   (``image.duplicate`` mit ``mergedOnly``). Sie übernimmt die Auswahl. Dort wird die Auswahl
   als Kanal gesichert, auf den Ausschnitt beschnitten und als ``context.png`` /
   ``mask.png`` in den Austauschordner gespeichert. Das Dokument des Nutzers und sein
   Protokoll bleiben dabei unberührt.
2. **Rechnen** – ``planning.plan`` legt Modell, Technik, Arbeitsgröße und Request fest.
   Ausschnitt und Maske gehen in Arbeitsgröße zu NV-AI, gerechnet wird ein Auftrag mit 1–4
   Varianten.
3. **Einfügen** – Die gewählte Variante wird aus dem Austauschordner geöffnet, per
   ``layer.copyToDocument`` an die richtige Stelle des Zieldokuments kopiert und bekommt die
   Auswahl als Ebenenmaske. Der Eintrag unter „Zuletzt geöffnet“ wird wieder entfernt.

PhotoCraft erlaubt der Fernsteuerung keine Dateizugriffe außerhalb des Austauschordners –
daher der Umweg über Öffnen und Kopieren statt „Platzieren“. Die Befehlsfolgen samt Fallen
stehen in docs/mac-port.md.
"""
from __future__ import annotations

import json
import logging
import shutil
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path
from typing import Any

from PIL import Image

from . import config, imaging, planning
from .imaging import Rect
from .nvai import NVAI, NVAIError, NVAIUnavailable
from .i18n import t as _t
from .photocraft import PhotoCraft, PhotoCraftError

log = logging.getLogger(__name__)

# Namen der Arbeitskopie und des Kanals, unter dem die Auswahl darin gesichert wird. Absichtlich
# in jeder Sprache gleich: Die Abläufe finden sie über den Namen.
WORKING_COPY = "NV-AI working copy"
MASK_CHANNEL = "NV-AI selection"
HISTORY_LIMIT = 30


class TaskCancelled(Exception):
    pass


class BusyError(RuntimeError):
    pass


@dataclass
class Variant:
    index: int
    file: str  # relativ zum Austauschordner, z. B. "jobs/<id>/result-1.png"
    thumb: str
    seed: int | None = None
    asset_id: str | None = None
    # FLUX 3: die Bildbeschreibung, die der Prompt-Upsampler aus dem Prompt gemacht hat.
    caption: str | None = None


@dataclass
class Task:
    id: str
    mode: str
    prompt: str
    params: dict[str, Any]
    created: float = field(default_factory=time.time)
    status: str = "running"  # running | done | error | cancelled
    stage: str = field(default_factory=lambda: _t("startet", "starting"))
    progress: float = 0.0
    error: str | None = None
    warning: str | None = None
    doc_name: str = ""
    doc_index: int = -1
    doc_size: list[int] = field(default_factory=lambda: [0, 0])
    region: list[int] | None = None  # Ausschnitt im Dokument [x, y, w, h]
    selection: list[int] | None = None  # Auswahlgrenzen beim Start
    has_mask: bool = False
    alpha_mask: bool = False  # Maske stammt aus Transparenz statt aus einer Auswahl
    working: list[int] | None = None  # Arbeitsgröße im Modell [w, h]
    model_name: str = ""
    technique: str = ""  # txt2img | img2img | inpaint | reference
    variants: list[Variant] = field(default_factory=list)
    placed_layer: int | None = None
    placed_variant: int | None = None
    nv_job: str | None = None
    finished: float | None = None
    cancel_event: threading.Event = field(default_factory=threading.Event, repr=False, compare=False)

    def public(self) -> dict[str, Any]:
        # Nicht asdict(self): das würde auch das Event kopieren wollen (nicht kopierbar).
        d = {f.name: getattr(self, f.name) for f in fields(self) if f.name != "cancel_event"}
        d["params"] = dict(self.params)
        d["variants"] = [{**asdict(v), "url": f"/{v.file}", "thumb_url": f"/{v.thumb}"} for v in self.variants]
        d["mode_label"] = planning.mode_label(self.mode)
        return d


class TaskManager:
    def __init__(self, pc: PhotoCraft, nv: NVAI) -> None:
        self.pc = pc
        self.nv = nv
        self._tasks: dict[str, Task] = {}
        self._order: list[str] = []
        self._lock = threading.Lock()
        # Serialisiert alle mehrschrittigen Abläufe in PhotoCraft (Erfassen, Einfügen).
        self._pc_lock = threading.RLock()
        # Während eines solchen Ablaufs zeigt PhotoCraft kurz Hilfsdokumente an – die
        # Statusabfrage des Panels soll die nicht für das Dokument des Nutzers halten.
        self.pc_busy = False
        self.current: Task | None = None

    # ----------------------------------------------------------- Verwaltung

    def get(self, task_id: str) -> Task | None:
        return self._tasks.get(task_id)

    def history(self) -> list[Task]:
        return [self._tasks[i] for i in self._order if i in self._tasks]

    def start(self, params: dict[str, Any]) -> Task:
        mode = params.get("mode")
        if mode not in planning.MODES:
            raise ValueError(_t(f"Unbekannter Modus: {mode}", f"Unknown mode: {mode}"))
        prompt = (params.get("prompt") or "").strip()
        if mode == "generate" and not prompt:
            raise ValueError(_t("Zum Generieren bitte beschreiben, was entstehen soll.",
                                "To generate, please describe what should be created."))
        if mode == "extend" and not planning.extend_steps(params.get("extend")):
            raise ValueError(_t("Zum Erweitern bitte angeben, wie viele Pixel links, oben, rechts oder unten dazukommen.",
                                "To extend, please enter how many pixels to add on the left, top, right or bottom."))
        with self._lock:
            if self.current and self.current.status == "running":
                raise BusyError(_t("Es läuft bereits ein Auftrag. Bitte abwarten oder abbrechen.",
                                   "A job is already running. Please wait or cancel it."))
            task = Task(id=time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6],
                        mode=mode, prompt=prompt, params=dict(params))
            self._tasks[task.id] = task
            self._order.insert(0, task.id)
            for old in self._order[HISTORY_LIMIT:]:
                self._tasks.pop(old, None)
            del self._order[HISTORY_LIMIT:]
            self.current = task
        threading.Thread(target=self._run, args=(task,), name=f"task-{task.id}", daemon=True).start()
        return task

    def cancel(self, task_id: str) -> bool:
        task = self._tasks.get(task_id)
        if not task or task.status != "running":
            return False
        task.cancel_event.set()
        task.stage = "wird abgebrochen"
        return True

    def load_history(self) -> None:
        """Abgeschlossene Aufträge der letzten Tage wieder in den Verlauf holen."""
        found: list[Task] = []
        for meta in config.JOBS_DIR.glob("*/task.json"):
            try:
                d = json.loads(meta.read_text(encoding="utf-8"))
                # task.json ist die öffentliche Form (mit url/thumb_url) – nur die Felder übernehmen.
                d["variants"] = [Variant(**{k: v[k] for k in Variant.__dataclass_fields__ if k in v})
                                 for v in d.get("variants", [])]
                task = Task(**{k: v for k, v in d.items() if k in Task.__dataclass_fields__ and k != "cancel_event"})
            except (OSError, ValueError, TypeError) as exc:
                log.warning("Verlauf %s nicht lesbar: %s", meta, exc)
                continue
            if task.status == "done" and task.variants:
                found.append(task)
        found.sort(key=lambda t: t.created, reverse=True)
        with self._lock:
            for task in found[:HISTORY_LIMIT]:
                if task.id not in self._tasks:
                    self._tasks[task.id] = task
                    self._order.append(task.id)

    def cleanup_uploads(self, min_age_s: float = 3600) -> int:
        """Ausschnitte und Masken, die ein abgebrochener Auftrag in NV-AI liegen ließ, löschen.

        Normalerweise löscht jeder Auftrag seine Uploads selbst – nicht aber, wenn NV-AI
        währenddessen neu gestartet wurde oder die Brücke abstürzte.
        """
        try:
            uploads = self.nv.assets(kind="upload")
        except NVAIError:
            return 0
        limit = time.time() - min_age_s
        removed = 0
        for asset in uploads:
            name = (asset.get("meta") or {}).get("original_name") or ""
            if name.startswith("photocraft-") and float(asset.get("created_at") or 0) < limit:
                try:
                    self.nv.delete_asset(asset["id"])
                    removed += 1
                except NVAIError:
                    pass
        if removed:
            log.info("%d verwaiste Uploads in NV-AI gelöscht", removed)
        return removed

    @staticmethod
    def cleanup(max_age_days: float = config.KEEP_JOBS_DAYS) -> int:
        """Auftragsordner löschen, die älter als ``max_age_days`` sind."""
        limit = time.time() - max_age_days * 86400
        removed = 0
        for d in config.JOBS_DIR.iterdir() if config.JOBS_DIR.exists() else []:
            try:
                if d.is_dir() and d.stat().st_mtime < limit:
                    shutil.rmtree(d)
                    removed += 1
            except OSError as exc:
                log.warning("Konnte %s nicht löschen: %s", d, exc)
        return removed

    # -------------------------------------------------------------- Ablauf

    def _run(self, t: Task) -> None:
        try:
            self._execute(t)
            t.status, t.stage, t.progress = "done", _t("fertig", "done"), 1.0
        except TaskCancelled:
            t.status, t.stage = "cancelled", _t("abgebrochen", "cancelled")
        except (PhotoCraftError, NVAIError, ValueError) as exc:
            t.status, t.error = "error", str(exc)
            log.warning("Auftrag %s gescheitert: %s", t.id, exc)
        except Exception as exc:  # noqa: BLE001 – der Fehler gehört in den Auftrag
            log.exception("Auftrag %s: unerwarteter Fehler", t.id)
            t.status, t.error = "error", _t(f"Unerwarteter Fehler: {exc}", f"Unexpected error: {exc}")
        finally:
            t.finished = time.time()
            self._save_meta(t)

    def _stage(self, t: Task, progress: float, stage: str) -> None:
        t.progress, t.stage = progress, stage
        if t.cancel_event.is_set():
            raise TaskCancelled()

    def _execute(self, t: Task) -> None:
        p = t.params
        job_dir = config.JOBS_DIR / t.id
        job_dir.mkdir(parents=True, exist_ok=True)
        rel = f"jobs/{t.id}"

        self.nv.check_compatible()
        masks = self.nv.supports_masks()
        mode = planning.base_mode(t.mode)
        if mode == "fill" and not masks and not (t.mode == "extend" and self.nv.supports_outpaint()):
            raise NVAIError(_t(
                "Die laufende NV-AI-Version kennt noch keine Masken. NV-AI bitte neu starten, "
                "damit die Inpainting-Erweiterung aktiv wird.",
                "The running NV-AI version does not know masks yet. Please restart NV-AI so the "
                "inpainting extension becomes active.",
            ))

        self._stage(t, 0.02, _t("liest das Dokument", "reading the document"))
        context, mask = self._capture(t, rel, job_dir)
        region = Rect.from_list(t.region or [0, 0, *t.doc_size])

        active = (self.nv.health().get("active_models") or {}).get("image")
        # Erweitern über NV-AIs outpaint (ab 0.5.4); ältere Server füllen per Maske wie bisher.
        outpaint = bool(t.alpha_mask and planning.extend_steps(p.get("extend"))
                        and self.nv.supports_outpaint())
        model, warning = planning.choose_model(mode, p.get("model_id") or None, active,
                                               self.nv.image_models(), masks, extend=outpaint)
        plan = planning.plan(mode, t.prompt, p, model, (region.w, region.h), t.has_mask,
                             t.alpha_mask, masks, outpaint=outpaint)
        t.model_name, t.technique, t.working = plan.model_name, plan.technique, list(plan.working)
        warnings = ([warning] if warning else []) + plan.warnings
        t.warning = " ".join(w.message for w in warnings) or None
        payload = dict(plan.payload)
        gw, gh = plan.working

        uploads: list[str] = []
        try:
            edges = (planning.outpaint_edges(context, (gw, gh))
                     if plan.technique == "outpaint" and context is not None else None)
            if plan.technique == "outpaint" and edges is None:
                raise ValueError(_t("Kein durchsichtiger Rand zum Füllen gefunden.",
                                    "No transparent border found to fill."))
            if edges is not None:
                # Arbeitsfläche erweitert und NV-AI kann Outpainting (ab 0.5.4): nur den deckenden
                # Teil schicken, Rand und weiche Maske legt der Server an. Der eigene Maskenweg
                # liess an der alten Bildkante eine harte Naht (gemessen 23.10.2026).
                self._stage(t, 0.06, _t("lädt den Ausschnitt zu NV-AI", "uploading the area to NV-AI"))
                box, size, border = edges
                src = imaging.flatten_for_model(context.crop(box)).resize(size, Image.Resampling.LANCZOS)
                asset = self.nv.upload(src, f"photocraft-{t.id}-context.png")
                uploads.append(asset["id"])
                payload["image_asset_id"] = asset["id"]
                payload["outpaint"] = border
            elif plan.send_image and context is not None:
                self._stage(t, 0.06, _t("lädt den Ausschnitt zu NV-AI", "uploading the area to NV-AI"))
                src = imaging.flatten_for_model(context).resize((gw, gh), Image.Resampling.LANCZOS)
                asset = self.nv.upload(src, f"photocraft-{t.id}-context.png")
                uploads.append(asset["id"])
                if plan.technique == "reference":
                    # FLUX 3 bearbeitet über ein Referenzbild statt über ein angerauschtes
                    # Startbild; der Prompt sagt, was sich ändert (BILDMODELLE.md, Abschnitt 5).
                    payload["reference_asset_ids"] = [asset["id"]]
                else:
                    payload["image_asset_id"] = asset["id"]
                if plan.send_mask and mask is not None:
                    m = imaging.prepare_model_mask(mask, (gw, gh), plan.mask_grow, plan.mask_blur)
                    masset = self.nv.upload(m.convert("RGB"), f"photocraft-{t.id}-mask.png")
                    uploads.append(masset["id"])
                    payload["mask_asset_id"] = masset["id"]

            self._stage(t, 0.08, _t("übergibt an NV-AI", "handing over to NV-AI"))
            job = self.nv.generate_image(payload)
            t.nv_job = job["id"]
            job = self._wait(t, job["id"])

            self._stage(t, 0.92, _t("holt die Ergebnisse", "fetching the results"))
            for k, asset_id in enumerate(job.get("asset_ids") or [], start=1):
                asset = self.nv.asset(asset_id)
                img = self.nv.fetch_image(asset)
                if t.mode == "generate":
                    out = imaging.fit_cover(img, region.w, region.h)
                else:
                    out = imaging.fit_exact(img, region.w, region.h)
                out.save(job_dir / f"result-{k}.png", "PNG", compress_level=1)
                thumb = f"thumb-{k}.png" if mask is not None else f"thumb-{k}.jpg"
                imaging.save_thumbnail(out, job_dir / thumb, mask=mask)
                meta = asset.get("meta") or {}
                t.model_name = meta.get("model_name") or t.model_name
                t.variants.append(Variant(index=k - 1, file=f"{rel}/result-{k}.png",
                                          thumb=f"{rel}/{thumb}", seed=meta.get("seed"),
                                          asset_id=asset_id, caption=meta.get("caption")))
        finally:
            for asset_id in uploads:
                try:
                    self.nv.delete_asset(asset_id)
                except NVAIError:
                    pass

        if not t.variants:
            raise NVAIError(_t("NV-AI hat kein Bild zurückgegeben.", "NV-AI did not return an image."))
        if p.get("auto_place", True):
            self._stage(t, 0.97, _t("legt das Ergebnis in PhotoCraft ab", "placing the result in PhotoCraft"))
            self.place(t, 0, replace=False)

    def _wait(self, t: Task, job_id: str) -> dict[str, Any]:
        unreachable_since: float | None = None
        while True:
            if t.cancel_event.is_set():
                try:
                    self.nv.cancel(job_id)
                except NVAIError as exc:
                    log.warning("Abbruch bei NV-AI gescheitert: %s", exc)
                raise TaskCancelled()
            try:
                job = self.nv.job(job_id)
                unreachable_since = None
            except NVAIUnavailable:
                # Ein Neustart von NV-AI dauert einige Sekunden – so lange weiter fragen.
                unreachable_since = unreachable_since or time.monotonic()
                if time.monotonic() - unreachable_since > 45:
                    raise
                t.stage = _t("NV-AI antwortet nicht – warte", "NV-AI does not answer – waiting")
                time.sleep(1.0)
                continue
            status = job.get("status")
            if status == "queued":
                t.progress, t.stage = 0.09, _t("wartet auf die GPU (dort läuft gerade etwas anderes)",
                                               "waiting for the GPU (something else is running there)")
            elif status == "running":
                t.progress = 0.1 + 0.8 * float(job.get("progress") or 0.0)
                t.stage = job.get("stage") or _t("generiert", "generating")
            elif status == "done":
                return job
            elif status == "error":
                raise NVAIError(job.get("error") or _t("NV-AI meldet einen Fehler.", "NV-AI reports an error."))
            elif status == "cancelled":
                if t.cancel_event.is_set():
                    raise TaskCancelled()
                # Nicht von uns abgebrochen: etwa ein Neustart von NV-AI oder ein Stopp in
                # dessen Oberfläche.
                reason = job.get("stage") or _t("ohne Angabe", "no reason given")
                raise NVAIError(_t(f"NV-AI hat den Auftrag abgebrochen ({reason}). Bitte erneut versuchen.",
                                   f"NV-AI cancelled the job ({reason}). Please try again."))
            time.sleep(0.5)

    # ------------------------------------------------------------ Erfassen

    def _capture(self, t: Task, rel: str, job_dir: Path) -> tuple[Image.Image | None, Image.Image | None]:
        with self._pc_lock:
            ui = self.pc.inspect()
            doc = ui.get("document")
            if not doc:
                raise PhotoCraftError(_t("In PhotoCraft ist kein Dokument geöffnet.", "No document is open in PhotoCraft."))
            # „Erweitern“; Füllen mit `extend` nehmen ältere Panels (0.4.2) weiter an.
            steps = planning.extend_steps(t.params.get("extend")) if t.mode in ("fill", "extend") else []
            if steps:
                # Outpainting: Arbeitsfläche transparent erweitern, danach füllt der übliche
                # Weg ohne Auswahl die leeren Ränder. Jeder Schritt lässt sich in PhotoCraft
                # einzeln zurücknehmen.
                if doc.get("hasSelection"):
                    raise ValueError(_t(
                        "Zum Erweitern bitte erst die Auswahl aufheben (Auswahl › Aufheben).",
                        "To extend, please deselect first (Select › Deselect).",
                    ))
                for step in steps:
                    self.pc.execute("image.canvasSize", step)
                ui = self.pc.inspect()
                doc = ui.get("document") or doc
            session = ui.get("session") or {}
            width, height = int(doc["width"]), int(doc["height"])
            t.doc_name, t.doc_index, t.doc_size = doc.get("name") or "", int(session.get("active", 0)), [width, height]
            canvas = Rect(0, 0, width, height)
            sel = Rect.from_list(doc["selectionBounds"]) if doc.get("hasSelection") and doc.get("selectionBounds") else None
            t.selection = sel.as_list() if sel else None
            margin = float(t.params.get("margin", 0.35))
            mode = planning.base_mode(t.mode)
            region = planning.region_for(mode, sel, width, height, margin)

            need_context = mode in ("fill", "refine")
            need_mask = sel is not None
            if need_context or need_mask:
                self._export(t.doc_index, rel, region, canvas, need_context, need_mask)

        context = mask = None
        if need_context:
            context = Image.open(job_dir / "context.png")
            context.load()
        if need_mask:
            mask = Image.open(job_dir / "mask.png").convert("L")
            mask.load()

        if planning.base_mode(t.mode) == "fill" and mask is None:
            # Ohne Auswahl füllt „Füllen“ die durchsichtigen Stellen (Arbeitsfläche erweitert).
            mask = imaging.mask_from_alpha(context) if context is not None else None
            box = imaging.mask_bbox(mask) if mask is not None else None
            if box is None:
                raise ValueError(_t(
                    "Für „Füllen“ bitte zuerst eine Auswahl treffen – oder die Arbeitsfläche "
                    "transparent erweitern, dann werden die leeren Ränder gefüllt.",
                    "For \"Fill\", please make a selection first – or extend the canvas with "
                    "transparency, then the empty edges get filled.",
                ))
            sub = planning.outpaint_region(box, width, height, margin)
            crop = (sub.x, sub.y, sub.x1, sub.y1)
            context, mask, region = context.crop(crop), mask.crop(crop), sub
            t.alpha_mask = True

        t.region = region.as_list()
        t.has_mask = mask is not None
        return context, mask

    def _export(self, index: int, rel: str, region: Rect, canvas: Rect, context: bool, mask: bool) -> None:
        """Ausschnitt und Auswahlmaske über eine reduzierte Arbeitskopie exportieren."""
        pc = self.pc
        self.pc_busy = True
        try:
            dup = pc.execute("image.duplicate", {"name": WORKING_COPY, "mergedOnly": True})
            try:
                if mask:
                    pc.execute("select.saveSelection", {"name": MASK_CHANNEL})
                if region != canvas:
                    pc.execute("image.crop", {"x": region.x, "y": region.y,
                                              "width": region.w, "height": region.h})
                if context:
                    pc.call("app.save", {"path": f"{rel}/context.png"})
                if mask:
                    channel_doc = pc.execute("channel.duplicate", {"channel": MASK_CHANNEL, "document": "new"})
                    try:
                        pc.call("app.save", {"path": f"{rel}/mask.png"})
                    finally:
                        pc.execute("file.close", {"document": channel_doc["document"]})
            finally:
                # engine.execute schließt ohne Rückfrage – nur für unsere eigenen Hilfsdokumente.
                pc.execute("file.close", {"document": dup["document"]})
                self._activate(index)
        finally:
            self.pc_busy = False

    def _activate(self, index: int) -> None:
        session = self.pc.inspect().get("session") or {}
        if session.get("active") != index:
            try:
                self.pc.activate(index)
            except PhotoCraftError as exc:
                raise PhotoCraftError(_t(
                    f"Konnte das Dokument nicht wieder nach vorn holen ({exc}). "
                    "Ist in PhotoCraft ein Dialog offen?",
                    f"Could not bring the document back to the front ({exc}). "
                    "Is a dialog open in PhotoCraft?",
                )) from exc

    # ------------------------------------------------------------ Einfügen

    def _find_target(self, t: Task, session: dict[str, Any]) -> int:
        docs = session.get("documents") or []

        def same(d: dict[str, Any]) -> bool:
            return d.get("name") == t.doc_name and [d.get("width"), d.get("height")] == list(t.doc_size)

        if 0 <= t.doc_index < len(docs) and same(docs[t.doc_index]):
            return t.doc_index
        for d in docs:
            if same(d):
                return int(d["index"])
        # Nach „Speichern unter“ heißt das Dokument anders: eindeutige Größe genügt dann.
        sized = [d for d in docs if [d.get("width"), d.get("height")] == list(t.doc_size)]
        if len(sized) == 1:
            return int(sized[0]["index"])
        raise PhotoCraftError(_t(f"Das Zieldokument „{t.doc_name}“ ist in PhotoCraft nicht mehr geöffnet.",
                                 f"The target document \"{t.doc_name}\" is no longer open in PhotoCraft."))

    def place(self, t: Task, k: int, replace: bool = True) -> int:
        """Variante ``k`` als Ebene ins Zieldokument legen; mit ``replace`` die zuvor
        eingefügte Variante dieses Auftrags ersetzen. Gibt die neue Ebenen-ID zurück."""
        if not 0 <= k < len(t.variants):
            raise ValueError(_t(f"Variante {k + 1} gibt es nicht.", f"There is no variant {k + 1}."))
        variant = t.variants[k]
        region = Rect.from_list(t.region or [0, 0, *t.doc_size])
        pc = self.pc
        with self._pc_lock:
            self.pc_busy = True
            try:
                ui = pc.inspect()
                index = self._find_target(t, ui.get("session") or {})
                self._activate(index)
                doc = pc.document()
                layers = _layers_by_id(doc.get("layers") or [])
                old = t.placed_layer if replace and t.placed_layer in layers else None

                # Maske: am liebsten die echte Auswahl als bearbeitbare Ebenenmaske.
                selection_now = doc.get("selectionBounds") if doc.get("hasSelection") else None
                use_selection = t.has_mask and not t.alpha_mask and selection_now == t.selection
                if t.has_mask and not use_selection and old is not None and layers[old].get("hasMask"):
                    pc.execute("select.loadSelection", {"channel": "mask", "layer": old})
                    use_selection = True
                source = variant.file
                if t.has_mask and not use_selection:
                    # Auswahl inzwischen verändert (oder Transparenz-Füllung): Maske einbacken.
                    source = self._baked(t, variant)

                if old is not None:
                    # Die Kopie landet über der aktiven Ebene – also direkt über der alten Variante.
                    pc.execute("layer.select", {"layer": old})
                opened = pc.call("app.open", {"path": source}) or {}
                temp = self._wait_for_document(opened.get("name") or Path(source).name)
                try:
                    temp_doc = pc.document()
                    layer_id = temp_doc["layers"][0]["id"]
                    copied = pc.execute("layer.copyToDocument", {
                        "document": index, "source": temp, "layers": [layer_id],
                        "offset": [region.x, region.y],
                        "name": planning.layer_name(t.mode, t.prompt, k, len(t.variants)),
                    })
                    new_id = int(copied["layers"][0])
                finally:
                    if temp != index:
                        pc.execute("file.close", {"document": temp})
                    self._forget_recent()
                self._activate(index)
                if use_selection:
                    pc.execute("layer.layerMask.revealSelection", {"layer": new_id})
                    # Die Auswahl wieder aktivieren, damit gleich noch einmal generiert werden kann.
                    pc.execute("select.loadSelection", {"channel": "mask", "layer": new_id})
                if old is not None:
                    pc.execute("layer.delete", {"layer": old})
            finally:
                self.pc_busy = False
        if replace or t.placed_layer is None:
            t.placed_layer, t.placed_variant = new_id, k
        self._save_meta(t)
        return new_id

    def _wait_for_document(self, name: str, timeout: float = 15.0) -> int:
        """Index des gerade geöffneten Dokuments ``name``.

        Kleine Dateien öffnet PhotoCraft sofort; große kann es als Hintergrundauftrag laden –
        dann erscheint das Dokument erst etwas später in der Sitzung.
        """
        deadline = time.monotonic() + timeout
        while True:
            session = self.pc.inspect().get("session") or {}
            docs = session.get("documents") or []
            active = session.get("active")
            if active is not None and 0 <= active < len(docs) and docs[active].get("name") == name:
                return int(active)
            if time.monotonic() > deadline:
                raise PhotoCraftError(_t(f"PhotoCraft hat „{name}“ nicht geöffnet.", f"PhotoCraft did not open \"{name}\"."))
            time.sleep(0.2)

    def _baked(self, t: Task, variant: Variant) -> str:
        """Variante mit eingebackener Maske (Alphakanal) für den Fall ohne passende Auswahl."""
        job_dir = config.JOBS_DIR / t.id
        out = job_dir / f"result-{variant.index + 1}-alpha.png"
        if not out.exists():
            img = Image.open(config.EXCHANGE_DIR / variant.file)
            if t.alpha_mask:
                context = Image.open(job_dir / "context.png")
                full = imaging.mask_from_alpha(context)
                region = Rect.from_list(t.region or [0, 0, *t.doc_size])
                if full is not None and full.size != (region.w, region.h):
                    # context.png umfasst die ganze Arbeitsfläche, der Ausschnitt nur einen Teil.
                    full = full.crop((region.x, region.y, region.x1, region.y1))
                # Deckt die leere Fläche voll ab und blendet über rund 12–20 px in den Bestand
                # über – dort hat das Modell den Übergang mitgerechnet (OUTPAINT_GROW/BLUR).
                mask = imaging.prepare_model_mask(full, img.size, grow=12, blur=8.0) if full else None
            else:
                mask = Image.open(job_dir / "mask.png").convert("L")
            out_img = imaging.bake_alpha(img, mask) if mask is not None else img
            out_img.save(out, "PNG", compress_level=1)
        return f"jobs/{t.id}/{out.name}"

    def _forget_recent(self) -> None:
        """``app.open`` setzt die Datei auf „Zuletzt geöffnet“ – unsere Hilfsdateien wieder austragen."""
        try:
            recent = self.pc.execute("prefs.get", {"path": "fileHandling.recentFiles"}, read=True) or []
            kept = [r for r in recent if not str(r).replace("\\", "/").startswith("jobs/")]
            if kept != recent:
                self.pc.execute("prefs.set", {"path": "fileHandling.recentFiles", "value": kept})
        except PhotoCraftError as exc:
            log.warning("Konnte „Zuletzt geöffnet“ nicht bereinigen: %s", exc)

    def _save_meta(self, t: Task) -> None:
        path = config.JOBS_DIR / t.id / "task.json"
        try:
            if path.parent.exists():
                path.write_text(json.dumps(t.public(), ensure_ascii=False, indent=1), encoding="utf-8")
        except OSError as exc:
            log.warning("Konnte %s nicht schreiben: %s", path, exc)


def _layers_by_id(layers: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    """Alle Ebenen einschließlich Gruppeninhalten nach ID."""
    out: dict[int, dict[str, Any]] = {}
    stack = list(layers)
    while stack:
        layer = stack.pop()
        out[int(layer["id"])] = layer
        stack.extend(layer.get("children") or [])
    return out

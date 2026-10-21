"use strict";

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

// ---------------------------------------------------------------- Sprache

// Englisch ist Standard, Deutsch die Option. Die Wahl liegt bei der Brücke (settings.json); bis
// ihr erster Status da ist, gilt die Sprache des Browsers.
let lang = (navigator.language || "en").toLowerCase().startsWith("de") ? "de" : "en";
const t = (de, en) => (lang === "de" ? de : en);

/** Texte je Modus – als Funktion, damit sie der gewählten Sprache folgen. */
function modeTexts(mode) {
  return {
    fill: {
      go: t("Auswahl füllen", "Fill selection"),
      hint: t("Füllt die Auswahl passend zur Umgebung. Ohne Prompt wird die Umgebung fortgesetzt, ohne Auswahl werden transparente Ränder gefüllt.",
        "Fills the selection to match its surroundings. Without a prompt the surroundings continue; without a selection, transparent edges get filled."),
      placeholder: t("Was soll in der Auswahl entstehen? Leer lassen = Umgebung fortsetzen",
        "What should appear in the selection? Leave empty = continue the surroundings"),
    },
    generate: {
      go: t("Bild generieren", "Generate image"),
      hint: t("Erzeugt ein neues Bild in der Auswahl – oder auf der ganzen Arbeitsfläche, wenn nichts ausgewählt ist.",
        "Creates a new image in the selection – or on the whole canvas if nothing is selected."),
      placeholder: t("Beschreibe das Bild, z. B. „a red vintage car at sunset, cinematic photo“",
        "Describe the image, e.g. \"a red vintage car at sunset, cinematic photo\""),
    },
    refine: {
      go: t("Überarbeiten", "Refine"),
      hint: t("Rechnet die Auswahl oder das ganze Bild neu. Die Stärke bestimmt, wie viel sich ändert.",
        "Re-renders the selection or the whole image. The strength sets how much changes."),
      placeholder: t("Wie soll sich der Bereich verändern? z. B. „as an oil painting with visible brush strokes“",
        "How should the area change? e.g. \"as an oil painting with visible brush strokes\""),
      // Modelle wie FLUX 3 bearbeiten mit dem Ausschnitt als Referenzbild statt per Bild-zu-Bild.
      editHint: t("Bearbeitet die Auswahl oder das ganze Bild mit dem Ausschnitt als Referenz: Beschreibe, was sich ändert – und was gleich bleibt.",
        "Edits the selection or the whole image using the area as a reference: describe what changes – and what stays the same."),
      editPlaceholder: t("z. B. „Replace the rope handles with forged iron handles; keep everything else unchanged.“",
        "e.g. \"Replace the rope handles with forged iron handles; keep everything else unchanged.\""),
    },
  }[mode];
}

/** Statische Texte aus index.html: Englisch steht im HTML, Deutsch in data-de bzw. data-de-<attr>. */
function translateStatic() {
  document.documentElement.lang = lang;
  document.title = t("NV-AI für PhotoCraft", "NV-AI for PhotoCraft");
  for (const node of $$("[data-de]")) {
    if (node.dataset.en === undefined) node.dataset.en = node.textContent;
    node.textContent = t(node.dataset.de, node.dataset.en);
  }
  for (const [attr, key] of [["title", "Title"], ["placeholder", "Placeholder"], ["aria-label", "AriaLabel"]]) {
    for (const node of $$(`[data-de-${attr}]`)) {
      if (node.dataset[`en${key}`] === undefined) node.dataset[`en${key}`] = node.getAttribute(attr) || "";
      node.setAttribute(attr, t(node.dataset[`de${key}`], node.dataset[`en${key}`]));
    }
  }
}

const DEFAULTS = {
  mode: "fill", prompt: "", models: { fill: "", generate: "", refine: "" }, variants: 2, strength: 0.5,
  negative: "", steps: "", cfg: "", seed: "", margin: 0.35, hires: false, native: false, autoPlace: true,
  advanced: false,
};
// Was ein Modell für den jeweiligen Modus können muss (Generieren können alle).
const MODE_NEEDS = { fill: "mask", refine: "refine", generate: null };
const defaultTip = () => t("Englische Prompts treffen meist genauer.", "Detailed English prompts work best.");
const STORE_KEY = "nvai-photocraft-panel";

function loadSettings() {
  let stored = {};
  try {
    stored = JSON.parse(localStorage.getItem(STORE_KEY) || "{}") || {};
  } catch {
    /* unlesbar oder gesperrt – mit Standardwerten weiter */
  }
  return { ...DEFAULTS, ...stored, models: { ...DEFAULTS.models, ...(stored.models || {}) } };
}

function saveSettings() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(settings));
  } catch {
    /* privater Modus o. Ä. – Einstellungen gelten dann nur für diese Sitzung */
  }
}

const settings = loadSettings();
let state = null; // letzte Antwort von /api/state
let shownTask = null; // Auftrag im Ergebnisbereich
let history = [];
let models = [];
let currentModel = null; // Modell, mit dem der nächste Auftrag gerechnet würde
let modelsLoaded = false; // Laden angestoßen
let modelsFetched = false; // Liste liegt vor (darf leer sein)
let modelsAskedAt = 0;
let lastStatus = null;
let pollTimer = 0;
let placing = null; // { taskId, k } während des Einfügens
let expanding = false; // „Prompt ausbauen“ läuft
let promptBefore = null; // eigener Prompt vor dem Ausbauen, zum Zurücknehmen
let expandNote = "";
let starting = ""; // "photocraft" | "nvai" während eines Starts, "check" während „Erneut prüfen“
let errorText = "";

// ------------------------------------------------------------------ Helfer

async function api(path, options = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
  let data = null;
  try {
    data = await res.json();
  } catch {
    /* kein JSON */
  }
  if (!res.ok) {
    const detail = data && data.detail;
    if (typeof detail === "string") throw new Error(detail);
    if (Array.isArray(detail)) throw new Error(detail.map((d) => d.msg).join("; "));
    throw new Error(`HTTP ${res.status}`);
  }
  return data;
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value == null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children) if (child != null) node.append(child);
  return node;
}

const num = (v) => (v === "" || v == null || Number.isNaN(Number(v)) ? null : Number(v));
const clock = (ts) => new Date(ts * 1000).toLocaleTimeString(lang === "de" ? "de-DE" : "en-US", { hour: "2-digit", minute: "2-digit" });
const capitalize = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : "");
const colorMode = (mode) => ({ Rgb: "RGB", Cmyk: "CMYK", Gray: t("Graustufen", "Grayscale"),
  Grayscale: t("Graustufen", "Grayscale"), Lab: "Lab" })[mode] || mode;

// ------------------------------------------------------------------ Status

function renderStatus() {
  const pc = state?.photocraft;
  const nv = state?.nvai;
  const pcPill = $("#pc-pill");
  const nvPill = $("#nv-pill");
  if (!state) {
    pcPill.className = nvPill.className = "pill off";
    pcPill.title = nvPill.title = t("Die Brücke antwortet nicht.", "The bridge does not respond.");
    return;
  }
  pcPill.className = `pill ${pc.connected ? "ok" : "off"}`;
  pcPill.title = pc.connected
    ? t(`PhotoCraft verbunden · ${pc.documents} Dokument${pc.documents === 1 ? "" : "e"} offen. Klick holt PhotoCraft nach vorn.`,
      `PhotoCraft connected · ${pc.documents} document${pc.documents === 1 ? "" : "s"} open. Click to bring PhotoCraft to the front.`)
    : pc.error || t("PhotoCraft nicht verbunden", "PhotoCraft not connected");
  const busy = nv.connected && (nv.busy || state.task?.status === "running");
  nvPill.className = `pill ${!nv.connected || nv.problem ? "off" : busy ? "busy" : "ok"}`;
  if (nv.connected && nv.problem) {
    nvPill.title = nv.problem;
  } else if (nv.connected) {
    const gpu = nv.gpu ? `${nv.gpu.name?.replace(/^cuda:\d+\s*/, "").replace(/\s*:.*$/, "")}` : "";
    const loaded = nv.loaded?.length ? t(`Geladen: ${nv.loaded.join(", ")}`, `Loaded: ${nv.loaded.join(", ")}`)
      : t("Kein Modell im VRAM", "No model in VRAM");
    nvPill.title = [busy ? t("NV-AI rechnet gerade", "NV-AI is busy") : t("NV-AI bereit", "NV-AI ready"),
      nv.version ? `Version ${nv.version}` : "", loaded, gpu, nv.masks ? "" : t("ohne Masken-Unterstützung", "without mask support")]
      .filter(Boolean).join(" · ");
  } else {
    nvPill.title = nv.error || t("NV-AI nicht erreichbar", "NV-AI not reachable");
  }
}

function noticeBlock(text, buttons = [], detail = "") {
  const block = el("div", {}, el("p", { text }));
  if (detail) block.append(el("p", { class: "detail", text: detail }));
  if (buttons.length) block.append(el("div", { class: "buttons" }, ...buttons));
  return block;
}

function downloadButton(main = false) {
  return noticeButton(t("PhotoCraft herunterladen", "Download PhotoCraft"), openPhotoCraftDownload, main);
}

function noticeButton(label, onclick, main = false) {
  return el("button", { class: `secondary${main ? " main" : ""}`, type: "button", text: label, onclick });
}

function renderNotice() {
  const box = $("#notice");
  const pc = state?.photocraft;
  const nv = state?.nvai;
  const blocks = [];
  let key = `${lang}|`;  // Sprachwechsel baut die Hinweise neu auf
  if (!state) {
    key += "bridge";
    blocks.push(noticeBlock(t("Die Brücke antwortet nicht. Bitte das Panel über seine Verknüpfung neu starten.",
      "The bridge does not respond. Please restart the panel from its shortcut.")));
  } else {
    if (!pc.connected && pc.installed === false && !pc.uncontrolled_running) {
      key += "pc-missing|";
      blocks.push(noticeBlock(
        t(`PhotoCraft ist nicht installiert. NV-AI für PhotoCraft braucht PhotoCraft ${pc.tested_version} oder neuer.`,
          `PhotoCraft is not installed. NV-AI for PhotoCraft needs PhotoCraft ${pc.tested_version} or newer.`),
        [downloadButton(true)],
        t("Auf der Download-Seite unter „Assets“ die Datei …-windows-x64.msi laden und installieren. Danach geht es hier von selbst weiter.",
          "On the download page, get the file …-windows-x64.msi under \"Assets\" and install it. Everything continues here by itself afterwards."),
      ));
    } else if (!pc.connected) {
      key += pc.uncontrolled_running ? "pc-other|" : "pc-off|";
      const label = starting === "photocraft" ? t("Startet …", "Starting …") : t("PhotoCraft mit NV-AI starten", "Start PhotoCraft with NV-AI");
      if (pc.uncontrolled_running) {
        blocks.push(noticeBlock(
          t("PhotoCraft läuft ohne NV-AI-Anbindung. Bitte dort speichern und schließen – dann hier neu starten.",
            "PhotoCraft is running without the NV-AI connection. Please save and close it there – then start it again here."),
          [noticeButton(label, () => startPhotoCraft(false), true),
            noticeButton(t("Zusätzlich starten", "Start another one"), () => startPhotoCraft(true))],
        ));
      } else {
        blocks.push(noticeBlock(t("PhotoCraft ist nicht mit NV-AI verbunden.", "PhotoCraft is not connected to NV-AI."),
          [noticeButton(label, () => startPhotoCraft(false), true)]));
      }
      key += starting;
    }
    if (pc.installed && pc.outdated) {
      key += "pc-old|";
      blocks.push(noticeBlock(
        t(`PhotoCraft ${pc.version} ist älter als ${pc.tested_version}. Mit dieser Version ist NV-AI für PhotoCraft nicht getestet – bitte aktualisieren.`,
          `PhotoCraft ${pc.version} is older than ${pc.tested_version}. NV-AI for PhotoCraft is not tested with this version – please update.`),
        [downloadButton()],
      ));
    }
    if (!nv.connected && nv.local === false) {
      // Entferntes NV-AI (etwa über Tailscale): starten lässt es sich nur dort.
      key += "nv-remote-off|";
      blocks.push(noticeBlock(t(`NV-AI unter ${nv.url} ist nicht erreichbar. Bitte dort starten oder die Verbindung prüfen.`,
        `NV-AI at ${nv.url} is not reachable. Please start it there or check the connection.`)));
    } else if (!nv.connected && nv.starting) {
      key += "nv-starting|";
      blocks.push(noticeBlock(t("NV-AI startet … Beim ersten Start kann das etwas dauern.", "NV-AI is starting … The first start can take a while.")));
    } else if (!nv.connected && nv.startable === false) {
      key += "nv-missing|";
      blocks.push(noticeBlock(t("NV-AI ist auf diesem PC nicht installiert. Bitte zuerst das NV-AI-Setup ausführen.",
        "NV-AI is not installed on this PC. Please run the NV-AI setup first.")));
    } else if (!nv.connected) {
      key += `nv-off|${starting}`;
      blocks.push(noticeBlock(t("NV-AI läuft nicht.", "NV-AI is not running."),
        [noticeButton(starting === "nvai" ? t("Startet …", "Starting …") : t("NV-AI starten", "Start NV-AI"), startNvai, true)]));
    } else if (nv.problem) {
      // Falsche Vertragsversion oder fehlender Token – nach dem Beheben ohne Neustart prüfbar.
      key += `nv-problem|${nv.problem}|${starting}`;
      const block = noticeBlock(nv.problem, [noticeButton(starting === "check" ? t("Prüft …", "Checking …") : t("Erneut prüfen", "Check again"), checkNvai, true)]);
      if (nv.authorized === false) block.firstChild.after(el("p", { text: t(`Einstellungen: ${nv.settings_file}`, `Settings: ${nv.settings_file}`) }));
      blocks.push(block);
    } else if (noModels()) {
      key += "nv-nomodels|";
      blocks.push(noticeBlock(t("In NV-AI ist noch kein Bildmodell installiert. Bitte dort eines laden – danach geht es hier von selbst weiter.",
        "No image model is installed in NV-AI yet. Please load one there – everything continues here by itself afterwards."),
        [noticeButton(t("NV-AI öffnen", "Open NV-AI"), openNvai, true)]));
    } else if (!nv.masks && settings.mode === "fill") {
      key += "nv-nomask|";
      blocks.push(noticeBlock(t("Die laufende NV-AI-Version kennt noch keine Masken. Für „Füllen“ NV-AI bitte neu starten, damit die Erweiterung geladen wird.",
        "The running NV-AI version does not know masks yet. For \"Fill\", please restart NV-AI so the extension gets loaded.")));
    }
    if (pc.connected && pc.dialog_open) {
      key += "dialog|";
      blocks.push(noticeBlock(t("In PhotoCraft ist ein Dialog offen. Bitte erst schließen.", "A dialog is open in PhotoCraft. Please close it first.")));
    }
  }
  // Nur bei Änderung neu aufbauen, sonst flackern die Knöpfe unter dem Mauszeiger.
  if (box.dataset.key === key) return;
  box.dataset.key = key;
  box.replaceChildren(...blocks);
  box.hidden = !blocks.length;
}

function renderDoc() {
  const pc = state?.photocraft;
  const doc = pc?.document;
  $("#doc-name").textContent = doc ? doc.name : pc?.connected ? t("Kein Dokument geöffnet", "No document open")
    : t("PhotoCraft nicht verbunden", "PhotoCraft not connected");
  const meta = $("#doc-meta");
  meta.replaceChildren();
  if (!doc) {
    meta.textContent = "–";
    return;
  }
  meta.append(`${doc.width} × ${doc.height} px · ${colorMode(doc.mode)} ${doc.depth} ${t("Bit", "bit")} · `);
  if (doc.hasSelection && doc.selectionBounds) {
    const [, , w, h] = doc.selectionBounds;
    meta.append(el("span", { class: "sel", text: t(`Auswahl ${w} × ${h}`, `Selection ${w} × ${h}`) }));
  } else {
    meta.append(t("keine Auswahl", "no selection"));
  }
}

// ------------------------------------------------------------- Eingaben

function renderMode() {
  for (const b of $$(".modes button")) b.setAttribute("aria-selected", String(b.dataset.mode === settings.mode));
  const mode = modeTexts(settings.mode);
  $("#mode-hint").textContent = mode.hint;
  $("#prompt").placeholder = mode.placeholder;
  $("#strength-field").hidden = settings.mode !== "refine";
  $("#margin-field").hidden = settings.mode !== "fill";
  renderModels();
  renderGo();
}

function suitable(m) {
  const need = MODE_NEEDS[settings.mode];
  return !need || Boolean(m[need]);
}

function renderModels() {
  const select = $("#model");
  const list = models.filter(suitable);
  const active = list.find((m) => m.active);
  // Ohne Wahl nimmt die Brücke das aktive Modell – oder, wenn es nicht passt, das beste passende.
  const fallback = active || [...list].sort((a, b) => a.weak_prompt - b.weak_prompt)[0];
  const waitingForMasks = MODE_NEEDS[settings.mode] === "mask" && state?.nvai?.connected && !state.nvai.masks;
  const first = !models.length ? (modelsFetched ? t("Kein Bildmodell installiert", "No image model installed") : t("Aktives Modell", "Active model"))
    : !fallback ? (waitingForMasks ? t("Füllen braucht Masken-Unterstützung in NV-AI", "Fill needs mask support in NV-AI")
      : t("Kein passendes Modell installiert", "No suitable model installed"))
    : active ? t(`Aktives Modell (${active.name})`, `Active model (${active.name})`)
    : t(`Automatisch (${fallback.name})`, `Automatic (${fallback.name})`);
  select.replaceChildren(el("option", { value: "", text: first }));
  for (const m of list) {
    select.append(el("option", {
      value: m.id,
      text: m.name + (m.commercial_ok === false ? t(" – nicht kommerziell", " – non-commercial") : ""),
      title: [m.best_for, m.warning].filter(Boolean).join(" – "),
    }));
  }
  const saved = settings.models[settings.mode] || "";
  select.value = list.some((m) => m.id === saved) ? saved : "";
  currentModel = list.find((m) => m.id === select.value) || fallback || null;
  renderModelHints();
}

/** Bedienung nach dem Modell ausrichten, mit dem gerechnet würde (features aus NV-AI). */
function renderModelHints() {
  const m = currentModel;
  const mode = modeTexts(settings.mode);
  const edit = settings.mode === "refine" && Boolean(m?.reference_edit);
  $("#mode-hint").textContent = edit ? mode.editHint : mode.hint;
  $("#prompt").placeholder = edit ? mode.editPlaceholder
    : settings.mode === "generate" && m?.placeholder ? m.placeholder : mode.placeholder;
  $("#prompt-tip").textContent = m?.prompt_hint || defaultTip();
  $("#prompt-tip").title = m?.prompt_hint || "";
  // Die Stärke gilt nur für Bild-zu-Bild; FLUX 3 bearbeitet per Referenz.
  $("#strength-field").hidden = settings.mode !== "refine" || edit;

  const negative = $("#negative");
  const negativeWorks = !m || m.negative_prompt;
  negative.disabled = !negativeWorks;
  negative.placeholder = negativeWorks ? t("Was vermieden werden soll – leer = Standard des Modells",
    "What to avoid – empty = the model's default")
    : t("Wirkt bei diesem Modell nicht – Ausschlüsse positiv im Prompt formulieren",
      "Has no effect with this model – phrase exclusions positively in the prompt");
  const hires = $("#hires");
  hires.disabled = Boolean(m) && !m.hires;
  hires.parentElement.title = hires.disabled ? t("Bei diesem Modell gibt es keinen zweiten Durchgang – stattdessen „Native Auflösung“",
    "This model has no second pass – use \"Native model resolution\" instead") : "";

  const hints = [];
  if (settings.mode === "fill" && m?.weak_prompt) {
    hints.push(t("Schnelle Modelle setzen beim Füllen meist nur die Umgebung fort – für neue Objekte das volle Modell wählen.",
      "Fast models mostly just continue the surroundings when filling – choose the full model for new objects."));
  }
  if (m?.warning) hints.push(m.warning);
  $("#model-hint").hidden = !hints.length;
  $("#model-hint").textContent = hints.join("\n");
  renderGo();
}

function renderVariants() {
  for (const b of $$("#variants button")) b.setAttribute("aria-checked", String(Number(b.dataset.n) === settings.variants));
}

function renderSliders() {
  $("#strength-out").textContent = Number(settings.strength).toFixed(2);
  const percent = Math.round(settings.margin * 100);
  $("#margin-out").textContent = t(`${percent} %`, `${percent}%`);
}

function renderCount() {
  const words = settings.prompt.trim() ? settings.prompt.trim().split(/\s+/).length : 0;
  $("#prompt-count").textContent = !words ? "" : words === 1 ? t("1 Wort", "1 word") : t(`${words} Wörter`, `${words} words`);
}

function blocker() {
  if (!state) return t("Brücke nicht erreichbar", "Bridge not reachable");
  const { photocraft: pc, nvai: nv, task } = state;
  if (task?.status === "running") return t("Es läuft bereits ein Auftrag", "A job is already running");
  if (!pc.connected) {
    return pc.installed === false ? t("PhotoCraft ist nicht installiert", "PhotoCraft is not installed")
      : t("PhotoCraft ist nicht verbunden", "PhotoCraft is not connected");
  }
  if (!pc.document) return t("In PhotoCraft ist kein Dokument geöffnet", "No document is open in PhotoCraft");
  if (!nv.connected) return t("NV-AI läuft nicht", "NV-AI is not running");
  if (nv.problem) {
    return nv.authorized === false ? t("NV-AI verlangt einen gültigen Token", "NV-AI requires a valid token")
      : t("NV-AI-Version passt nicht zur Brücke", "NV-AI version does not match the bridge");
  }
  if (noModels()) return t("In NV-AI ist kein Bildmodell installiert", "No image model is installed in NV-AI");
  if (settings.mode === "fill" && !nv.masks) return t("NV-AI kennt noch keine Masken", "NV-AI does not know masks yet");
  if (settings.mode === "generate" && !settings.prompt.trim()) return t("Bitte beschreiben, was entstehen soll", "Please describe what should be created");
  if (settings.mode === "refine" && currentModel?.reference_edit && !settings.prompt.trim()) {
    return t("Bitte beschreiben, was sich ändern soll", "Please describe what should change");
  }
  return null;
}

function renderGo() {
  const why = blocker();
  const go = $("#go");
  go.disabled = Boolean(why);
  go.title = why || "";
  $("#go-label").textContent = state?.task?.status === "running" ? t("Läuft …", "Running …") : modeTexts(settings.mode).go;
  renderExpand();
}

// ------------------------------------------------------------ Prompt ausbauen

function expandBlocker() {
  const nv = state?.nvai;
  if (!nv?.connected || nv.problem) return t("NV-AI läuft nicht", "NV-AI is not running");
  if (!nv.expand) return t("Diese NV-AI-Version kann Prompts noch nicht ausbauen", "This NV-AI version cannot expand prompts yet");
  if (state?.task?.status === "running") return t("Es läuft bereits ein Auftrag", "A job is already running");
  if (!settings.prompt.trim()) return t("Erst ein paar Worte eingeben", "Type a few words first");
  return null;
}

function renderExpand() {
  const why = expanding ? null : expandBlocker();
  const button = $("#expand");
  button.disabled = expanding || Boolean(why);
  button.textContent = expanding ? t("Baut aus …", "Expanding …") : t("✨ Prompt ausbauen", "✨ Expand prompt");
  if (why) button.title = why;
  else button.title = t("Macht aus wenigen Worten eine volle Bildbeschreibung, für jedes Modell (meist 10–40 s)",
    "Turns a few words into a full image description, for every model (usually 10–40 s)");
  $("#expand-undo").hidden = expanding || promptBefore === null;
  $("#expand-note").textContent = expanding ? t("meist 10–40 s", "usually 10–40 s") : expandNote;
}

function setPrompt(text) {
  $("#prompt").value = text;
  settings.prompt = text;
  saveSettings();
  renderCount();
  renderGo();
}

async function expandPrompt() {
  if (expanding || expandBlocker()) return;
  expanding = true;
  expandNote = "";
  renderExpand();
  try {
    const before = settings.prompt;
    const r = await api("/api/expand", { method: "POST", body: JSON.stringify({ prompt: before }) });
    promptBefore = before;
    expandNote = t(`ausgebaut in ${Math.round(r.seconds)} s – lesen und streichen, was nicht stimmt`,
      `expanded in ${Math.round(r.seconds)} s – read it and remove what is wrong`);
    setPrompt(r.expanded);
  } catch (e) {
    errorText = e.message;
    renderNotice();
  } finally {
    expanding = false;
    renderExpand();
  }
}

function undoExpand() {
  if (promptBefore === null) return;
  const before = promptBefore;
  promptBefore = null;
  expandNote = "";
  setPrompt(before);
}

// ------------------------------------------------------------ Ergebnisse

const technique = (name) => ({ img2img: t("Bild→Bild", "image→image"), inpaint: t("mit Maske", "with mask"),
  reference: t("per Referenz", "by reference") })[name];

function resultMeta(task) {
  const parts = [task.mode_label + (technique(task.technique) ? ` ${technique(task.technique)}` : "")];
  if (task.region) parts.push(`${task.region[2]} × ${task.region[3]} px`);
  if (task.model_name) parts.push(task.model_name);
  if (task.finished && task.status === "done") parts.push(`${Math.round(task.finished - task.created)} s`);
  return parts.join(" · ");
}

function variantCard(task, v) {
  const placed = task.placed_variant === v.index;
  const working = placing && placing.taskId === task.id && placing.k === v.index;
  const choose = () => place(task, v.index, true);
  return el(
    "div",
    {
      class: `variant${placed ? " placed" : ""}${working ? " working" : ""}`,
      role: "button",
      tabindex: "0",
      title: t(`Variante ${v.index + 1}${v.seed != null ? ` · Seed ${v.seed}` : ""} – Klick tauscht sie in PhotoCraft ein`,
        `Variant ${v.index + 1}${v.seed != null ? ` · seed ${v.seed}` : ""} – click to swap it into PhotoCraft`),
      onclick: choose,
      onkeydown: (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          choose();
        }
      },
    },
    el("img", { src: v.thumb_url, alt: t(`Variante ${v.index + 1}`, `Variant ${v.index + 1}`) }),
    placed ? el("span", { class: "badge", text: "in PhotoCraft" }) : null,
    el("button", {
      class: "add",
      type: "button",
      title: t("Zusätzlich als neue Ebene einfügen", "Also add as a new layer"),
      "aria-label": t(`Variante ${v.index + 1} als neue Ebene einfügen`, `Add variant ${v.index + 1} as a new layer`),
      text: "+",
      onclick: (e) => {
        e.stopPropagation();
        place(task, v.index, false);
      },
    }),
    el("span", { class: "num", text: String(v.index + 1) }),
  );
}

function renderTask() {
  const running = state?.task?.status === "running" ? state.task : null;
  $("#progress").hidden = !running;
  if (running) {
    $("#bar").style.width = `${Math.round((running.progress || 0) * 100)}%`;
    $("#stage").textContent = capitalize(running.stage);
  }

  const task = shownTask;
  const err = errorText || (task && task.status === "error" ? task.error : "");
  $("#error").hidden = !err;
  $("#error").textContent = err || "";

  const box = $("#results");
  if (!task || (task.status === "error" && !task.variants.length) || task.status === "cancelled") {
    box.hidden = true;
    return;
  }
  box.hidden = false;
  $("#results-title").textContent = task.status === "running" ? t("Wird erzeugt …", "Creating …") : t("Ergebnis", "Result");
  $("#results-meta").textContent = resultMeta(task);
  $("#results-hint").hidden = !task.variants.length;
  $("#task-warning").hidden = !task.warning;
  $("#task-warning").textContent = task.warning || "";
  // FLUX 3: Was der Upsampler aus dem Prompt gemacht hat – erste Anlaufstelle, wenn das Bild
  // nicht passt (BILDMODELLE.md).
  const shown = task.variants.find((v) => v.index === task.placed_variant) || task.variants[0];
  $("#caption").hidden = !shown?.caption;
  $("#caption-text").textContent = shown?.caption || "";

  const grid = $("#variant-grid");
  const key = JSON.stringify([lang, task.id, task.status, task.variants.length, task.placed_variant, placing?.taskId, placing?.k]);
  if (grid.dataset.key === key) return;
  grid.dataset.key = key;
  const ratio = task.region ? task.region[2] / task.region[3] : 1;
  grid.style.setProperty("--ratio", String(Math.max(0.5, Math.min(2.2, ratio))));
  const cards = task.variants.map((v) => variantCard(task, v));
  if (task.status === "running" && !cards.length) {
    for (let i = 0; i < (task.params?.variants || 1); i++) cards.push(el("div", { class: "variant skeleton" }));
  }
  grid.replaceChildren(...cards);
}

function renderHistory() {
  const list = $("#history-list");
  const items = history.filter((task) => task.status !== "running");
  $("#history").hidden = !items.length;
  const key = JSON.stringify([lang, items.map((task) => [task.id, task.status, task.placed_variant]), shownTask?.id]);
  if (list.dataset.key === key) return;
  list.dataset.key = key;
  list.replaceChildren(
    ...items.map((task) => {
      const title = task.prompt || (task.mode === "fill" ? t("Umgebung fortgesetzt", "Surroundings continued") : t("ohne Prompt", "no prompt"));
      const failed = task.status === "error" || task.status === "cancelled";
      const meta = task.status === "error" ? t(`Fehler: ${task.error}`, `Error: ${task.error}`) : task.status === "cancelled"
        ? t("abgebrochen", "cancelled") : `${task.mode_label} · ${clock(task.created)} · ${task.doc_name}`;
      return el(
        "li",
        {},
        el(
          "button",
          {
            type: "button",
            "aria-current": String(shownTask?.id === task.id),
            onclick: () => {
              shownTask = task;
              errorText = "";
              renderTask();
              renderHistory();
            },
          },
          task.variants[0] ? el("img", { src: task.variants[0].thumb_url, alt: "" }) : el("span", { class: "ph" }),
          el("span", {}, el("div", { class: "h-title", text: title }), el("div", { class: `h-meta${failed ? " h-err" : ""}`, text: meta })),
        ),
      );
    }),
  );
}

// Laufende Modell-Downloads von NV-AI, je mit Abbrechen (fertige Teile bleiben zum Fortsetzen).
function renderDownloads() {
  const box = $("#nv-downloads");
  const list = (state?.nvai?.connected && state.nvai.downloads) || [];
  box.hidden = list.length === 0;
  box.replaceChildren(...list.map((d) => {
    const pct = Math.round((d.progress || 0) * 100);
    const label = d.status === "queued" ? t("wartet", "queued") : `${pct} %`;
    const cancelBtn = el("button", {
      class: "dl-cancel", type: "button", text: "✕",
      title: t("Download abbrechen (fertige Teile bleiben zum Fortsetzen)", "Cancel download (finished parts stay to resume)"),
    });
    cancelBtn.addEventListener("click", async () => {
      cancelBtn.disabled = true;
      try {
        await api(`/api/nvai/downloads/${encodeURIComponent(d.job)}/cancel`, { method: "POST" });
      } catch (e) {
        errorText = e.message;
      }
      poll(300);
    });
    return el("div", { class: "dl-item", title: d.stage || "" },
      el("span", { class: "dl-name", text: t(`NV-AI lädt ${d.name}`, `NV-AI downloading ${d.name}`) }),
      el("span", { class: "dl-track" }, el("span", { class: "dl-fill", style: `width:${d.status === "queued" ? 0 : pct}%` })),
      el("span", { class: "dl-pct", text: label }),
      cancelBtn);
  }));
}

function renderAll() {
  renderStatus();
  renderDownloads();
  renderNotice();
  renderDoc();
  renderGo();
  renderTask();
  renderHistory();
}

// ---------------------------------------------------------------- Aktionen

async function generate() {
  if (blocker()) return;
  errorText = "";
  const body = {
    mode: settings.mode,
    prompt: settings.prompt,
    negative_prompt: settings.negative,
    model_id: settings.models[settings.mode] || null,
    variants: settings.variants,
    strength: Number(settings.strength),
    steps: num(settings.steps),
    cfg: num(settings.cfg),
    seed: num(settings.seed),
    margin: Number(settings.margin),
    hires: settings.hires,
    native: settings.native,
    auto_place: settings.autoPlace,
  };
  try {
    const task = await api("/api/generate", { method: "POST", body: JSON.stringify(body) });
    shownTask = task;
    if (state) state.task = task;
    lastStatus = "running";
    renderAll();
    poll(250);
  } catch (e) {
    errorText = e.message;
    renderTask();
  }
}

async function cancel() {
  const task = state?.task;
  if (task?.status !== "running") return;
  try {
    await api(`/api/tasks/${task.id}/cancel`, { method: "POST" });
  } catch {
    /* der nächste Statusabruf zeigt, was passiert ist */
  }
  poll(200);
}

async function place(task, k, replace) {
  if (placing || task.status !== "done") return;
  placing = { taskId: task.id, k };
  errorText = "";
  renderTask();
  try {
    const r = await api(`/api/tasks/${task.id}/place`, { method: "POST", body: JSON.stringify({ variant: k, replace }) });
    shownTask = r.task;
    history = history.map((h) => (h.id === r.task.id ? r.task : h));
  } catch (e) {
    errorText = e.message;
  } finally {
    placing = null;
    renderTask();
    renderHistory();
  }
}

async function startPhotoCraft(force) {
  if (starting) return;
  starting = "photocraft";
  errorText = "";
  renderNotice();
  try {
    await api(`/api/photocraft/start${force ? "?force=true" : ""}`, { method: "POST" });
  } catch (e) {
    errorText = e.message;
  } finally {
    starting = "";
    poll(100);
  }
}

async function startNvai() {
  if (starting) return;
  starting = "nvai";
  errorText = "";
  renderNotice();
  try {
    // Bis NV-AI antwortet, meldet die Brücke „starting“ – der Hinweis wechselt dann von selbst.
    await api("/api/nvai/start", { method: "POST" });
  } catch (e) {
    errorText = e.message;
  }
  starting = "";
  renderTask();
  poll(100);
}

async function openPhotoCraftDownload() {
  try {
    await api("/api/open/photocraft-download", { method: "POST" });
  } catch (e) {
    errorText = e.message;
    renderTask();
  }
}

async function checkNvai() {
  if (starting) return;
  starting = "check";
  renderNotice();
  try {
    const nv = await api("/api/nvai/check", { method: "POST" });
    if (state) state.nvai = nv;
    modelsLoaded = false;
  } catch (e) {
    errorText = e.message;
  } finally {
    starting = "";
    poll(100);
  }
}

async function loadModels() {
  modelsLoaded = true;
  modelsAskedAt = Date.now();
  try {
    models = await api("/api/models");
    modelsFetched = true;
    renderModels();
  } catch {
    modelsLoaded = false;
  }
}

// Frisch installiertes NV-AI ohne Bildmodell: Der Hinweis schickt den Nutzer dorthin.
const noModels = () => modelsFetched && !models.length;

function openNvai() {
  api("/api/open/nvai", { method: "POST" }).catch(() => {});
}

async function loadHistory() {
  try {
    history = await api("/api/tasks");
    if (shownTask) shownTask = history.find((task) => task.id === shownTask.id) || shownTask;
    renderHistory();
    renderTask();
  } catch {
    /* beim nächsten Mal */
  }
}

// ------------------------------------------------------------------- Takt

async function tick() {
  try {
    state = await api("/api/state");
  } catch {
    state = null;
  }
  const task = state?.task;
  if (task) {
    if (!shownTask || shownTask.id === task.id) shownTask = task;
    if (lastStatus === "running" && task.status !== "running") loadHistory();
    lastStatus = task.status;
  }
  if (state && state.lang && state.lang !== lang) {
    lang = state.lang;
    applyLanguage();
  }
  if (state && $("#language").value !== state.language) $("#language").value = state.language;
  const usable = state?.nvai?.connected && !state.nvai.problem;
  // Ohne Bildmodell alle 5 s nachsehen, ob inzwischen eins installiert ist.
  if (usable && (!modelsLoaded || (noModels() && Date.now() - modelsAskedAt > 5000))) loadModels();
  if (state && !usable) modelsLoaded = modelsFetched = false;
  if (state) {
    const label = [t(`Brücke ${state.bridge.version}`, `Bridge ${state.bridge.version}`),
      state.nvai.version && `NV-AI ${state.nvai.version}`].filter(Boolean).join(" · ");
    if ($("#version").textContent !== label) $("#version").textContent = label;
  }
  renderAll();
  const fast = task?.status === "running" || placing;
  poll(document.visibilityState === "hidden" ? 4000 : fast ? 500 : 1500);
}

/** Nach einem Sprachwechsel alles neu beschriften; NV-AI liefert seine Modelltexte neu. */
function applyLanguage() {
  translateStatic();
  modelsLoaded = false;
  renderMode();
  renderSliders();
  renderCount();
  renderAll();
  renderPin();
}

async function chooseLanguage(language) {
  try {
    state = await api("/api/language", { method: "POST", body: JSON.stringify({ language }) });
    if (state.lang !== lang) {
      lang = state.lang;
      applyLanguage();
    }
  } catch (e) {
    errorText = e.message;
    renderTask();
  }
}

function poll(ms) {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(tick, ms);
}

// ------------------------------------------------------------------ Start

function bind() {
  for (const b of $$(".modes button")) {
    b.addEventListener("click", () => {
      settings.mode = b.dataset.mode;
      saveSettings();
      renderMode();
      renderNotice();
    });
  }

  const prompt = $("#prompt");
  prompt.value = settings.prompt;
  prompt.addEventListener("input", () => {
    settings.prompt = prompt.value;
    saveSettings();
    renderGo();
    renderCount();
  });
  $("#expand").addEventListener("click", expandPrompt);
  $("#expand-undo").addEventListener("click", undoExpand);

  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      generate();
    } else if (e.key === "Escape" && state?.task?.status === "running") {
      cancel();
    }
  });

  for (const b of $$("#variants button")) {
    b.addEventListener("click", () => {
      settings.variants = Number(b.dataset.n);
      saveSettings();
      renderVariants();
    });
  }

  const bindValue = (id, key, parse = (v) => v) => {
    const input = $(id);
    input.value = settings[key];
    input.addEventListener("input", () => {
      settings[key] = parse(input.value);
      saveSettings();
      renderSliders();
    });
  };
  bindValue("#strength", "strength", Number);
  bindValue("#margin", "margin", Number);
  bindValue("#negative", "negative");
  bindValue("#steps", "steps");
  bindValue("#cfg", "cfg");
  bindValue("#seed", "seed");

  const bindCheck = (id, key) => {
    const input = $(id);
    input.checked = Boolean(settings[key]);
    input.addEventListener("change", () => {
      settings[key] = input.checked;
      saveSettings();
    });
  };
  bindCheck("#hires", "hires");
  bindCheck("#native", "native");
  bindCheck("#auto-place", "autoPlace");

  const advanced = $("#advanced");
  advanced.open = Boolean(settings.advanced);
  advanced.addEventListener("toggle", () => {
    settings.advanced = advanced.open;
    saveSettings();
  });

  $("#model").addEventListener("change", (e) => {
    settings.models[settings.mode] = e.target.value;
    saveSettings();
    renderModels();
  });

  $("#go").addEventListener("click", generate);
  $("#cancel").addEventListener("click", cancel);
  $("#pc-pill").addEventListener("click", () => api("/api/photocraft/focus", { method: "POST" }).catch(() => {}));
  $("#nv-pill").addEventListener("click", openNvai);
  $("#open-nvai").addEventListener("click", openNvai);
  $("#language").addEventListener("change", (e) => chooseLanguage(e.target.value));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") poll(50);
  });
}

let onTop = null; // nur im Panel-Fenster (pywebview) bekannt

function renderPin() {
  const pin = $("#pin");
  if (onTop === null) return;
  pin.hidden = false;
  pin.setAttribute("aria-pressed", String(onTop));
  pin.title = onTop ? t("Fenster bleibt im Vordergrund (Klick zum Lösen)", "Window stays on top (click to release)")
    : t("Fenster im Vordergrund halten", "Keep window on top");
}

window.addEventListener("pywebviewready", async () => {
  onTop = await window.pywebview.api.get_on_top();
  renderPin();
  $("#pin").addEventListener("click", async () => {
    onTop = await window.pywebview.api.set_on_top(!onTop);
    renderPin();
  });
});

translateStatic();
bind();
renderMode();
renderVariants();
renderSliders();
renderCount();
loadHistory();
tick();

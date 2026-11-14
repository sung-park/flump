const $ = (selector) => document.querySelector(selector);

const LABELS = {
  queued: "Waiting",
  extracting: "Looking",
  downloading: "Saving",
  processing: "Merging",
  review: "Playlist",
  error: "Failed",
  cancelled: "Cancelled",
  done: "Done",
};

const ui = {
  checks: new Map(),
  historyKey: "",
  timer: 0,
};

const urlField = $("#url");

function toast(message) {
  const node = document.createElement("div");
  node.className = "toast";
  node.textContent = message;
  $("#toasts").append(node);
  setTimeout(() => node.remove(), 4200);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = data.detail || data.error || "The request failed.";
    throw new Error(typeof detail === "string" ? detail : "The request failed.");
  }
  return data;
}

function apply(data) {
  ui.data = data;
  const notes = [];
  if (!data.ffmpeg) {
    notes.push("ffmpeg is missing. Run brew install ffmpeg to merge video and audio, or to save audio only.");
  }
  if (!data.js_runtime) {
    notes.push("YouTube needs Node. Install it from https://nodejs.org.");
  }
  const banner = $("#ffmpeg");
  banner.hidden = notes.length === 0;
  banner.textContent = notes.join(" ");
  syncJobs(data.jobs || []);
  const historyKey = (data.history || []).map((item) => item.id).join("|");
  if (historyKey !== ui.historyKey) {
    ui.historyKey = historyKey;
    renderHistory(data.history || []);
  }
  const hasJobs = (data.jobs || []).length > 0;
  const hasHistory = (data.history || []).length > 0;
  $("#empty").hidden = hasJobs || hasHistory;
  const active = (data.jobs || []).some((job) =>
    ["queued", "extracting", "downloading", "processing"].includes(job.status));
  schedule(active ? 400 : 2000);
}

function schedule(delay) {
  clearTimeout(ui.timer);
  ui.timer = setTimeout(refresh, delay);
}

async function refresh() {
  try {
    apply(await api("/api/state"));
  } catch (error) {
    schedule(2000);
  }
}

async function act(path, body, method = "POST") {
  try {
    const data = await api(path, { method, body: JSON.stringify(body ?? {}) });
    if (data.jobs) apply(data);
  } catch (error) {
    toast(error.message);
  }
}

function resize() {
  urlField.style.height = "auto";
  urlField.style.height = Math.min(urlField.scrollHeight, 140) + "px";
}

async function submit(text) {
  const value = (text ?? urlField.value).trim();
  if (!value) return;
  try {
    apply(await api("/api/submit", { method: "POST", body: JSON.stringify({ text: value }) }));
    if (text == null) {
      urlField.value = "";
      resize();
    }
  } catch (error) {
    toast(error.message);
  }
}

function safeImage(url) {
  if (!url) return "";
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "https:" || parsed.protocol === "http:") return url;
  } catch (error) {
    return "";
  }
  return "";
}

function button(label, className, onClick) {
  const node = document.createElement("button");
  node.type = "button";
  node.textContent = label;
  if (className) node.className = className;
  node.addEventListener("click", onClick);
  return node;
}

function syncJobs(jobs) {
  const list = $("#jobs");
  const seen = new Set();
  jobs.forEach((job) => {
    seen.add(job.id);
    let card = list.querySelector(`[data-id="${CSS.escape(job.id)}"]`);
    if (!card) {
      card = createCard();
      card.dataset.id = job.id;
      list.append(card);
    }
    updateCard(card, job);
  });
  [...list.children].forEach((child) => {
    if (!seen.has(child.dataset.id)) {
      ui.checks.delete(child.dataset.id);
      child.remove();
    }
  });
  jobs.forEach((job) => list.append(list.querySelector(`[data-id="${CSS.escape(job.id)}"]`)));
  $("#jobs-wrap").hidden = jobs.length === 0;
}

function createCard() {
  const card = document.createElement("article");
  card.className = "card";
  card.innerHTML = `
    <div class="thumb"></div>
    <div class="body">
      <div class="title-row"><h3 class="title"></h3><span class="badge"></span></div>
      <p class="meta"></p>
      <div class="progress" hidden><span></span></div>
      <p class="stats"></p>
      <p class="message"></p>
      <p class="warning"></p>
      <div class="actions"></div>
      <div class="entries"></div>
    </div>`;
  return card;
}

function updateCard(card, job) {
  const title = card.querySelector(".title");
  if (title.textContent !== job.title) title.textContent = job.title;
  title.title = job.title;

  const badge = card.querySelector(".badge");
  badge.textContent = LABELS[job.status] || job.status;
  badge.classList.toggle("bad", job.status === "error");
  badge.classList.toggle("good", job.status === "done");

  card.querySelector(".meta").textContent = [job.extractor, job.duration].filter(Boolean).join(" · ");

  const thumb = card.querySelector(".thumb");
  const imageUrl = safeImage(job.thumbnail);
  const current = thumb.querySelector("img");
  if (imageUrl) {
    if (!current) {
      thumb.replaceChildren(Object.assign(document.createElement("img"), { alt: "" }));
    }
    const image = thumb.querySelector("img");
    if (image.getAttribute("src") !== imageUrl) image.src = imageUrl;
  } else if (!thumb.querySelector("span")) {
    const mark = document.createElement("span");
    mark.textContent = "Video";
    thumb.replaceChildren(mark);
  }

  const bar = card.querySelector(".progress");
  const moving = job.status === "downloading" || job.status === "processing";
  bar.hidden = !moving;
  if (moving) {
    const known = job.percent != null;
    bar.classList.toggle("indeterminate", !known);
    bar.querySelector("span").style.width = known ? `${Math.max(0, Math.min(100, job.percent))}%` : "35%";
  }

  const parts = [];
  if (moving && job.percent != null) parts.push(`${Math.round(job.percent)}%`);
  if (moving && job.speed) parts.push(job.speed);
  if (moving && job.eta) parts.push(`time left ${job.eta}`);
  if (moving && job.size) parts.push(job.size);
  card.querySelector(".stats").textContent = parts.join(" · ");

  const message = card.querySelector(".message");
  message.textContent = job.error || "";
  if (job.error && job.error_detail && job.error_detail !== job.error) {
    message.title = job.error_detail;
  } else {
    message.removeAttribute("title");
  }
  card.querySelector(".warning").textContent = job.warning || "";

  const actionKey = job.kind === "playlist" && job.status === "review" ? "review" : job.status;
  if (card.dataset.actions !== actionKey) {
    card.dataset.actions = actionKey;
    fillActions(card, job);
    fillEntries(card, job);
  }
}

function fillActions(card, job) {
  const box = card.querySelector(".actions");
  box.replaceChildren();
  const id = card.dataset.id;
  if (["queued", "extracting", "downloading", "processing"].includes(job.status)) {
    box.append(button("Cancel", "danger", () => act(`/api/jobs/${id}/cancel`)));
  }
  if (job.status === "review") {
    box.append(button("Save selected", "", () => {
      const picked = [...(ui.checks.get(id) || [])];
      act(`/api/jobs/${id}/entries`, { indexes: picked });
    }));
    box.append(button("Save all", "", () => act(`/api/jobs/${id}/entries`, {})));
    box.append(button("Remove", "danger", () => act(`/api/jobs/${id}/dismiss`)));
  }
  if (job.status === "error") {
    box.append(button("Try again", "", () => act(`/api/jobs/${id}/retry`)));
    box.append(button("Remove", "danger", () => act(`/api/jobs/${id}/dismiss`)));
  }
  if (job.status === "cancelled") {
    box.append(button("Try again", "", () => act(`/api/jobs/${id}/retry`)));
    box.append(button("Remove", "danger", () => act(`/api/jobs/${id}/dismiss`)));
  }
}

function fillEntries(card, job) {
  const box = card.querySelector(".entries");
  box.replaceChildren();
  if (job.status !== "review") return;
  const id = card.dataset.id;
  if (!ui.checks.has(id)) ui.checks.set(id, new Set(job.entries.map((entry) => entry.index)));
  const selected = ui.checks.get(id);

  if (job.truncated) {
    const note = document.createElement("p");
    note.className = "note";
    note.textContent = "Showing the first 100.";
    box.append(note);
  }

  const tools = document.createElement("label");
  tools.className = "entry-tools";
  const all = document.createElement("input");
  all.type = "checkbox";
  all.checked = job.entries.length > 0 && job.entries.every((entry) => selected.has(entry.index));
  all.addEventListener("change", () => {
    selected.clear();
    if (all.checked) job.entries.forEach((entry) => selected.add(entry.index));
    box.querySelectorAll(".entry input").forEach((input) => {
      input.checked = all.checked;
    });
  });
  tools.append(all, document.createTextNode("All"));
  box.append(tools);

  job.entries.forEach((entry) => {
    const row = document.createElement("label");
    row.className = "entry";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = selected.has(entry.index);
    input.addEventListener("change", () => {
      if (input.checked) selected.add(entry.index);
      else selected.delete(entry.index);
      all.checked = job.entries.every((item) => selected.has(item.index));
    });
    const name = document.createElement("span");
    name.className = "entry-title";
    name.textContent = entry.title;
    const time = document.createElement("span");
    time.className = "entry-time";
    time.textContent = entry.duration || "";
    row.append(input, name, time);
    box.append(row);
  });
}

function renderHistory(items) {
  const list = $("#history");
  list.replaceChildren();
  items.forEach((item) => {
    const card = createCard();
    card.dataset.id = item.id;
    list.append(card);
    card.querySelector(".title").textContent = item.title;
    card.querySelector(".badge").textContent = ago(item.created_at);
    card.querySelector(".badge").classList.add("good");
    const file = item.filepath ? item.filepath.split(/[/\\]/).pop() : "";
    card.querySelector(".meta").textContent = [item.extractor, item.duration, file].filter(Boolean).join(" · ");
    const imageUrl = safeImage(item.thumbnail);
    if (imageUrl) {
      const image = document.createElement("img");
      image.alt = "";
      image.src = imageUrl;
      card.querySelector(".thumb").replaceChildren(image);
    }
    const actions = card.querySelector(".actions");
    actions.append(button("Play", "", () => act(`/api/jobs/${item.id}/open`)));
    actions.append(button("Show in Finder", "", () => act(`/api/jobs/${item.id}/reveal`)));
    actions.append(button("Try again", "", () => act(`/api/jobs/${item.id}/retry`)));
    actions.append(button("Remove from list", "danger", () => act(`/api/history/${item.id}`, {}, "DELETE")));
  });
  $("#history-wrap").hidden = items.length === 0;
}

function ago(timestamp) {
  if (!timestamp) return "";
  const seconds = Math.max(0, Date.now() / 1000 - timestamp);
  if (seconds < 10) return "Just now";
  if (seconds < 60) return `${Math.floor(seconds)}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

function fillSettings(settings, presets) {
  $("#download-dir").value = settings.download_dir;
  const preset = $("#preset");
  const current = preset.value;
  preset.replaceChildren();
  (presets || []).forEach((item) => {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = item.label;
    preset.append(option);
  });
  preset.value = settings.preset || current;
  $("#subtitles").checked = settings.subtitles;
  $("#clipboard").checked = settings.clipboard_watch;
  $("#cookies").value = settings.cookies_browser || "";
  document.querySelectorAll('input[name="concurrent"]').forEach((input) => {
    input.checked = Number(input.value) === Number(settings.concurrent);
  });
}

async function saveSettings(partial) {
  try {
    const data = await api("/api/settings", { method: "PUT", body: JSON.stringify(partial) });
    apply(data);
    if ($("#settings").open) fillSettings(data.settings, data.presets);
  } catch (error) {
    toast(error.message);
    if (ui.data) fillSettings(ui.data.settings, ui.data.presets);
  }
}

$("#composer").addEventListener("submit", (event) => {
  event.preventDefault();
  submit();
});

urlField.addEventListener("input", resize);
urlField.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    submit();
  }
});

$("#open-folder").addEventListener("click", () => act("/api/settings/open-folder"));
$("#open-settings").addEventListener("click", () => {
  if (!ui.data) return;
  fillSettings(ui.data.settings, ui.data.presets);
  $("#settings").showModal();
});
$("#pick-folder").addEventListener("click", async () => {
  try {
    const data = await api("/api/settings/pick-folder", { method: "POST", body: "{}" });
    apply(data);
    fillSettings(data.settings, data.presets);
  } catch (error) {
    if (!error.message.includes("Cancel")) toast(error.message);
  }
});
$("#settings-open-folder").addEventListener("click", () => act("/api/settings/open-folder"));
$("#download-dir").addEventListener("change", () => saveSettings({ download_dir: $("#download-dir").value }));
$("#preset").addEventListener("change", () => saveSettings({ preset: $("#preset").value }));
$("#subtitles").addEventListener("change", () => saveSettings({ subtitles: $("#subtitles").checked }));
$("#clipboard").addEventListener("change", () => saveSettings({ clipboard_watch: $("#clipboard").checked }));
$("#cookies").addEventListener("change", () => saveSettings({ cookies_browser: $("#cookies").value }));
document.querySelectorAll('input[name="concurrent"]').forEach((input) => {
  input.addEventListener("change", () => {
    if (input.checked) saveSettings({ concurrent: Number(input.value) });
  });
});
$("#clear-history").addEventListener("click", () => {
  if (confirm("Clear the saved-file list? The video files stay in the folder.")) {
    act("/api/history", {}, "DELETE");
  }
});

let dragDepth = 0;
window.addEventListener("dragenter", (event) => {
  if (!event.dataTransfer) return;
  dragDepth += 1;
  document.body.classList.add("dragging");
});
window.addEventListener("dragover", (event) => {
  if (!event.dataTransfer) return;
  event.preventDefault();
});
window.addEventListener("dragleave", () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) document.body.classList.remove("dragging");
});
window.addEventListener("drop", (event) => {
  event.preventDefault();
  dragDepth = 0;
  document.body.classList.remove("dragging");
  const text = event.dataTransfer.getData("text/uri-list") || event.dataTransfer.getData("text/plain");
  if (text) submit(text);
});

refresh();

(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let app_js =
  {js|"use strict";
// Mentat web frontend — progressive enhancement over the no-JS HTML forms.
// Every command still works as a plain form POST; this script layers a live
// event stream, scroll anchoring, and composer keys on top.
(() => {
  const main = document.getElementById("main");
  const scroller = document.scrollingElement || document.documentElement;

  const nearBottom = () =>
    scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
  const pinToBottom = () => { scroller.scrollTop = scroller.scrollHeight; };

  // Parse one streamed frame (one or more sibling elements) into DOM nodes.
  const parseNodes = (html) => {
    const tpl = document.createElement("template");
    tpl.innerHTML = html;
    return Array.from(tpl.content.children);
  };

  // Stage-3 morph: reconcile attributes, then replace children wholesale.
  // Idiomorph is the named upgrade that preserves focus/scroll/<details> state.
  const morph = (from, to) => {
    for (const a of Array.from(from.attributes))
      if (!to.hasAttribute(a.name)) from.removeAttribute(a.name);
    for (const a of Array.from(to.attributes))
      if (from.getAttribute(a.name) !== a.value) from.setAttribute(a.name, a.value);
    from.replaceChildren(...Array.from(to.childNodes));
  };

  // Apply one streamed node by its own data-swap contract.
  const applyNode = (node) => {
    const swap = node.dataset.swap;
    if (swap === "append") {
      const target = document.getElementById(node.dataset.target || "transcript");
      if (target) target.appendChild(node);
    } else if (swap === "morph") {
      const existing = node.id ? document.getElementById(node.id) : null;
      if (existing) morph(existing, node);
      else if (main) main.appendChild(node);
    }
  };

  // Live event stream. Native EventSource resends Last-Event-ID on reconnect.
  if (main && main.dataset.session) {
    const session = encodeURIComponent(main.dataset.session);
    const resume = main.dataset.resume;
    const from = resume ? encodeURIComponent(resume) : "beginning";
    const source = new EventSource(`/session/${session}/feed?from=${from}`);
    source.addEventListener("message", (event) => {
      const pinned = nearBottom();
      for (const node of parseNodes(event.data)) applyNode(node);
      if (pinned) pinToBottom();
    });
  }

  // Load earlier: fetch a backward page and prepend it, preserving the offset.
  const loadEarlier = async (button) => {
    const src = button.dataset.src;
    if (!src) return;
    button.disabled = true;
    let html;
    try {
      const response = await fetch(src, { headers: { "Accept": "text/html" } });
      if (!response.ok) { button.disabled = false; return; }
      html = await response.text();
    } catch (_e) { button.disabled = false; return; }
    const transcript = document.getElementById("transcript");
    const earlier = document.getElementById("earlier");
    const before = scroller.scrollHeight;
    let replacement = null;
    for (const node of parseNodes(html)) {
      if (node.id === "earlier") { replacement = node; continue; }
      if (transcript) transcript.insertBefore(node, transcript.firstChild);
    }
    if (earlier && replacement) earlier.replaceWith(replacement);
    else if (earlier) earlier.replaceChildren();
    scroller.scrollTop += scroller.scrollHeight - before;
  };

  document.addEventListener("click", (event) => {
    const button = event.target.closest && event.target.closest(".load-earlier");
    if (button) { event.preventDefault(); loadEarlier(button); }
  });

  // Composer: fetch-submit so a send does not reload; SSE delivers the turn.
  const composer = document.getElementById("composer");
  if (composer) {
    const textarea = composer.querySelector("textarea[name=prompt]");
    const autosize = () => {
      if (!textarea) return;
      textarea.style.height = "auto";
      textarea.style.height = textarea.scrollHeight + "px";
    };
    if (textarea) {
      textarea.addEventListener("input", autosize);
      textarea.addEventListener("keydown", (event) => {
        if (event.key === "Enter" && !event.shiftKey) {
          event.preventDefault();
          if (textarea.value.trim() !== "") composer.requestSubmit();
        }
      });
    }
    composer.addEventListener("submit", (event) => {
      event.preventDefault();
      const submitter = event.submitter;
      const action =
        (submitter && submitter.getAttribute("formaction")) || composer.action;
      const body = new URLSearchParams(new FormData(composer));
      fetch(action, { method: "POST", body }).then(() => {
        if (textarea) { textarea.value = ""; autosize(); }
      });
    });
  }

  // Escape posts a cooperative interrupt for the open session.
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !main || !main.dataset.session) return;
    fetch(`/session/${encodeURIComponent(main.dataset.session)}/interrupt`, {
      method: "POST",
    });
  });

  // Elapsed ticker: running tool rows carry data-started (epoch seconds).
  setInterval(() => {
    const now = Date.now() / 1000;
    for (const el of document.querySelectorAll(".tool.running[data-started]")) {
      const started = parseFloat(el.dataset.started);
      if (!Number.isFinite(started)) continue;
      const time = el.querySelector("time");
      if (time) time.textContent = Math.max(0, Math.floor(now - started)) + "s";
    }
  }, 1000);
})();
|js}

let app_css =
  {css|:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --fg: #1c1c1e;
  --muted: #6b6b70;
  --line: #e2e2e6;
  --panel: #f6f6f8;
  --accent: #2f6feb;
  --danger: #c8352b;
  --user: #eef3ff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #17171a;
    --fg: #ececee;
    --muted: #9a9aa2;
    --line: #2c2c31;
    --panel: #202024;
    --accent: #6ea1ff;
    --danger: #ff6b60;
    --user: #1e2740;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
  background: var(--bg);
  color: var(--fg);
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
h1 { font-size: 1.2rem; margin: 0; }
button {
  font: inherit;
  padding: 0.35em 0.9em;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--panel);
  color: var(--fg);
  cursor: pointer;
}
button:hover { border-color: var(--accent); }
button.primary { background: var(--accent); color: #fff; border-color: transparent; }
button.delete, button.interrupt { color: var(--danger); }
textarea {
  font: inherit;
  width: 100%;
  padding: 0.6em;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg);
  color: var(--fg);
  resize: vertical;
}
header.top {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 0.8rem 1.2rem;
  border-bottom: 1px solid var(--line);
  position: sticky;
  top: 0;
  background: var(--bg);
}
header.top .session-title { flex: 1; font-size: 1rem; font-weight: 600; }
header.top .controls { display: flex; gap: 0.5rem; }
nav#sessions { max-width: 60rem; margin: 0 auto; padding: 1rem 1.2rem; }
ul.sessions { list-style: none; margin: 0; padding: 0; }
.session-row {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 0.7rem 0;
  border-bottom: 1px solid var(--line);
}
.session-link { flex: 1; display: flex; align-items: baseline; gap: 0.7rem; color: var(--fg); }
.session-link .title { font-weight: 600; }
.session-link:hover { text-decoration: none; }
.session-link:hover .title { text-decoration: underline; }
.phase { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
.phase.working { color: var(--accent); }
.phase.waiting { color: var(--danger); }
.turns, .preview { color: var(--muted); font-size: 0.85rem; }
.preview { flex-basis: 100%; margin: 0.2rem 0 0; }
.actions, .composer-actions { display: flex; gap: 0.5rem; }
.actions .action { margin: 0; }
.new-session { margin-left: auto; }
.empty, .notice { color: var(--muted); }
main#main { max-width: 60rem; margin: 0 auto; padding: 1rem 1.2rem 8rem; }
#transcript { display: flex; flex-direction: column; gap: 1rem; }
#earlier { text-align: center; margin-bottom: 1rem; }
.turn { display: flex; flex-direction: column; gap: 0.7rem; }
.msg { padding: 0.7rem 1rem; border-radius: 10px; overflow-wrap: anywhere; }
.msg.user { background: var(--user); align-self: flex-end; max-width: 85%; }
.msg.assistant { background: var(--panel); }
.msg.assistant.interrupted { opacity: 0.75; font-style: italic; }
.msg.user.pending { opacity: 0.6; }
.msg p:first-child { margin-top: 0; }
.msg p:last-child { margin-bottom: 0; }
.prewrap { white-space: pre-wrap; margin: 0; }
pre {
  background: rgba(127, 127, 127, 0.12);
  padding: 0.7rem 0.9rem;
  border-radius: 8px;
  overflow-x: auto;
}
code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
details.reasoning { color: var(--muted); font-size: 0.9rem; }
.notice { padding: 0.5rem 0.8rem; border-radius: 8px; background: var(--panel); font-size: 0.9rem; }
.notice.failure { color: var(--danger); }
.seam { border: none; border-top: 1px dashed var(--line); margin: 1.5rem 0; position: relative; }
ul.tools { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0.3rem; }
.tool { display: flex; align-items: center; gap: 0.6rem; padding: 0.3rem 0.6rem; border-radius: 6px; background: var(--panel); font-size: 0.9rem; }
.tool .verb { font-weight: 600; }
.tool .summary, .tool .facts, .tool time { color: var(--muted); }
.tool.done { opacity: 0.8; }
.tool.failed { color: var(--danger); }
.spinner {
  width: 0.6em; height: 0.6em; border-radius: 50%;
  border: 2px solid var(--muted); border-top-color: transparent;
  display: inline-block; animation: spin 0.8s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
.board ul { list-style: none; margin: 0; padding: 0; }
.task { padding: 0.2rem 0; }
.task.done { text-decoration: line-through; color: var(--muted); }
.task.in_progress { font-weight: 600; }
.queue { color: var(--muted); font-size: 0.85rem; padding: 0.3rem 0; }
.delegation a { font-size: 0.9rem; }
section.decision { border: 1px solid var(--accent); border-radius: 10px; padding: 0.9rem 1rem; margin: 0.5rem 0; }
section.decision form { display: flex; flex-direction: column; gap: 0.6rem; }
section.decision .plan { white-space: pre-wrap; }
.working { display: flex; align-items: center; gap: 0.5rem; color: var(--muted); padding: 0.4rem 0; }
.download { display: flex; align-items: center; gap: 0.6rem; }
#composer {
  position: fixed; bottom: 0; left: 0; right: 0;
  max-width: 60rem; margin: 0 auto; padding: 0.8rem 1.2rem;
  background: var(--bg); border-top: 1px solid var(--line);
  display: flex; flex-direction: column; gap: 0.5rem;
}
#composer .composer-actions { justify-content: flex-end; }
|css}

let get = function
  | "app.js" -> Some ("application/javascript; charset=utf-8", app_js)
  | "app.css" -> Some ("text/css; charset=utf-8", app_css)
  | _ -> None

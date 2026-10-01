/* AI front desk chat widget. Include with
 *   <script src="/widget.js" data-endpoint="/webhook/widget/<channel account id>" data-title="Clinic"></script>
 * (or set window.GREETER = { widget: "<endpoint>" } before loading). Talks to in.widget: session -> send -> poll. */
(function () {
  const script = document.currentScript;
  const endpoint = (script && script.dataset.endpoint) || (window.GREETER && window.GREETER.widget);
  if (!endpoint) return console.warn('greeter widget: no endpoint');
  const title = (script && script.dataset.title) || 'Chat with us';
  const key = 'greeter:' + endpoint;
  const load = () => { try { return JSON.parse(localStorage.getItem(key)) || {}; } catch (e) { return {}; } };
  const state = Object.assign({ token: null, after: 0, log: [] }, load());
  const save = () => { try { localStorage.setItem(key, JSON.stringify(state)); } catch (e) { /* private mode */ } };
  const post = (action, body) => fetch(endpoint + '/' + action, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}),
  }).then((r) => { if (!r.ok) throw new Error(action + ' ' + r.status); return r.json(); });

  const css = `
  .gw-btn{position:fixed;right:20px;bottom:20px;z-index:2147483000;border:0;border-radius:28px;padding:14px 20px;
    background:var(--gw-accent,#0f766e);color:#fff;font:600 15px/1 system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.2);cursor:pointer}
  .gw-panel{position:fixed;right:20px;bottom:80px;z-index:2147483000;width:min(380px,calc(100vw - 32px));height:min(560px,calc(100vh - 110px));
    display:flex;flex-direction:column;background:var(--gw-bg,#fff);color:var(--gw-fg,#111);border-radius:16px;
    box-shadow:0 12px 40px rgba(0,0,0,.25);font:15px/1.4 system-ui,sans-serif;overflow:hidden}
  .gw-panel[hidden]{display:none}
  .gw-head{padding:14px 16px;background:var(--gw-accent,#0f766e);color:#fff;font-weight:600;display:flex;justify-content:space-between;align-items:center}
  .gw-head button{background:none;border:0;color:#fff;font-size:22px;line-height:1;cursor:pointer}
  .gw-log{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px}
  .gw-msg{max-width:85%;padding:9px 12px;border-radius:14px;white-space:pre-wrap;overflow-wrap:anywhere}
  .gw-in{align-self:flex-end;background:var(--gw-accent,#0f766e);color:#fff;border-bottom-right-radius:4px}
  .gw-out{align-self:flex-start;background:var(--gw-bubble,#f1f5f9);border-bottom-left-radius:4px}
  .gw-keys{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
  .gw-keys button{border:1px solid var(--gw-accent,#0f766e);background:transparent;color:inherit;border-radius:10px;padding:6px 10px;cursor:pointer;font:inherit}
  .gw-form{display:flex;gap:8px;padding:10px;border-top:1px solid rgba(127,127,127,.25)}
  .gw-form input{flex:1;min-width:0;padding:10px 12px;border-radius:10px;border:1px solid rgba(127,127,127,.4);background:transparent;color:inherit;font:inherit}
  .gw-form button{border:0;border-radius:10px;padding:0 14px;background:var(--gw-accent,#0f766e);color:#fff;font:600 14px system-ui,sans-serif;cursor:pointer}
  .gw-typing{align-self:flex-start;opacity:.6;font-size:13px}
  @media (prefers-color-scheme: dark){.gw-panel{--gw-bg:#0f172a;--gw-fg:#e2e8f0;--gw-bubble:#1e293b}}`;
  document.head.appendChild(Object.assign(document.createElement('style'), { textContent: css }));

  const btn = Object.assign(document.createElement('button'), { className: 'gw-btn', textContent: '💬 ' + title });
  btn.setAttribute('aria-expanded', 'false');
  const panel = document.createElement('section');
  panel.className = 'gw-panel';
  panel.hidden = true;
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-label', title);
  panel.innerHTML = `<div class="gw-head"><span></span><button type="button" aria-label="Close">×</button></div>
    <div class="gw-log" aria-live="polite"></div>
    <form class="gw-form"><input name="text" autocomplete="off" aria-label="Your message" placeholder="Type a message…" maxlength="2000">
    <button type="submit">Send</button></form>`;
  panel.querySelector('.gw-head span').textContent = title;
  document.body.append(btn, panel);
  const logEl = panel.querySelector('.gw-log');
  const form = panel.querySelector('form');
  const typing = Object.assign(document.createElement('div'), { className: 'gw-typing', textContent: 'typing…' });

  function render() {
    logEl.replaceChildren(...state.log.map((m) => {
      const el = Object.assign(document.createElement('div'), { className: 'gw-msg ' + (m.in ? 'gw-in' : 'gw-out'), textContent: m.text });
      const keys = (m.buttons || []).flat();
      if (keys.length && m === state.log[state.log.length - 1]) {
        const row = Object.assign(document.createElement('div'), { className: 'gw-keys' });
        keys.forEach((b) => row.appendChild(Object.assign(document.createElement('button'), {
          type: 'button', textContent: b.text, onclick: () => send(b.text, b.data) })));
        el.appendChild(row);
      }
      return el;
    }));
    if (waiting) logEl.appendChild(typing);
    logEl.scrollTop = logEl.scrollHeight;
  }

  let waiting = false;
  let timer = null;
  async function session() {
    if (state.token) return;
    const s = await post('session');
    state.token = s.token;
    state.log.push({ text: s.greeting });
    save();
  }
  async function poll() {
    if (!state.token) return;
    try {
      const r = await post('poll', { token: state.token, after: state.after });
      for (const m of r.messages) {
        state.after = Math.max(state.after, m.id);
        if (m.text) { state.log.push({ text: m.text, buttons: m.buttons }); waiting = false; }
      }
      if (r.messages.length) { save(); render(); }
    } catch (e) {
      if (/401/.test(e.message)) { state.token = null; save(); await session(); }
    }
  }
  function schedule(ms) {
    clearTimeout(timer);
    if (!panel.hidden || waiting) timer = setTimeout(async () => { await poll(); schedule(waiting ? 1000 : 3000); }, ms);
  }
  async function send(text, callback) {
    text = String(text || '').trim();
    if (!text) return;
    await session();
    state.log.push({ text, in: true });
    waiting = true;
    save(); render();
    const id = (crypto.randomUUID && crypto.randomUUID()) || String(Date.now()) + Math.random();
    try {
      await post('send', Object.assign({ token: state.token, id, text }, callback ? { callback } : {}));
    } catch (e) {
      waiting = false;
      state.log.push({ text: 'Could not send the message, please try again.' });
      render();
    }
    schedule(800);
  }

  btn.onclick = async () => {
    panel.hidden = !panel.hidden;
    btn.setAttribute('aria-expanded', String(!panel.hidden));
    if (!panel.hidden) {
      await session().catch(() => state.log.push({ text: 'The chat is not available right now.' }));
      render();
      form.text.focus();
      poll();
      schedule(3000);
    }
  };
  panel.querySelector('.gw-head button').onclick = () => btn.onclick();
  form.onsubmit = (e) => { e.preventDefault(); const t = form.text.value; form.text.value = ''; send(t); };
})();

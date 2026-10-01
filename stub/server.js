// Fakes for local work and load tests: Telegram Bot API, OpenAI-compatible LLM + embeddings,
// Google OAuth token + Calendar, WhatsApp Cloud API. Every call is recorded: GET /_calls?service=&since=
// Failure switches: Telegram token containing "fail500"/"fail403", model name containing "fail",
// Authorization "Bearer bad", calendar id containing "revoked".
const http = require('node:http');
const crypto = require('node:crypto');

const [delayMin, delayMax] = (process.env.STUB_LLM_DELAY_MS || '1000-3000').split('-').map(Number);
const calls = [];
let seq = 0;
let nextId = Math.floor(Date.now() / 1000) % 1e8; // ids stay unique across stub restarts
const events = new Map(); // calendar events: `${calendar}/${id}` -> body

const record = (service, method, body) => {
  calls.push({ seq: ++seq, at: new Date().toISOString(), service, method, body });
  if (calls.length > 20000) calls.splice(0, 5000);
};
const send = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readBody = async (req) => {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  if (!raw) return {};
  if ((req.headers['content-type'] || '').includes('application/x-www-form-urlencoded')) {
    return Object.fromEntries(new URLSearchParams(raw));
  }
  try { return JSON.parse(raw); } catch { return { raw }; }
};

// ---------------------------------------------------------------- Telegram
function telegram(token, method, body, res) {
  record('telegram', method, { token: token.slice(-6), ...body });
  if (token.includes('fail500')) return send(res, 500, { ok: false, error_code: 500, description: 'Internal Server Error' });
  if (token.includes('fail403')) return send(res, 403, { ok: false, error_code: 403, description: 'Forbidden: bot was blocked by the user' });
  const now = Math.floor(Date.now() / 1000);
  switch (method) {
    case 'sendMessage':
      return send(res, 200, { ok: true, result: { message_id: ++nextId, date: now, chat: { id: Number(body.chat_id) || body.chat_id }, text: body.text, message_thread_id: body.message_thread_id } });
    case 'createForumTopic':
      return send(res, 200, { ok: true, result: { message_thread_id: ++nextId, name: body.name, icon_color: 7322096 } });
    case 'getMe':
      return send(res, 200, { ok: true, result: { id: Number(token.split(':')[0]) || 1, is_bot: true, first_name: 'Stub Bot', username: 'stub_bot' } });
    case 'getChatMember':
      return send(res, 200, { ok: true, result: { status: 'administrator', can_manage_topics: true, user: { id: 1, is_bot: true } } });
    case 'getWebhookInfo':
      return send(res, 200, { ok: true, result: { url: '', pending_update_count: 0 } });
    default: // setWebhook, answerCallbackQuery, editMessageReplyMarkup, deleteWebhook, ...
      return send(res, 200, { ok: true, result: true });
  }
}

// ---------------------------------------------------------------- LLM (OpenAI-compatible)
// The last user message may carry directives "/tool name {json}" to make the stub call tools,
// so the whole agent plumbing can be exercised without a real model.
function chat(body) {
  const msgs = body.messages || [];
  const last = msgs[msgs.length - 1] || {};
  const lastUser = [...msgs].reverse().find((m) => m.role === 'user') || {};
  const userText = typeof lastUser.content === 'string' ? lastUser.content
    : (lastUser.content || []).map((p) => p.text || '').join(' ');
  const toolNames = (body.tools || []).map((t) => t.function && t.function.name);
  const tokensIn = Math.ceil(JSON.stringify(msgs).length / 4);
  const usage = (out) => ({ prompt_tokens: tokensIn, completion_tokens: out, total_tokens: tokensIn + out });
  const message = (m, out, finish) => ({
    id: 'chatcmpl-' + crypto.randomUUID(), object: 'chat.completion', created: Math.floor(Date.now() / 1000),
    model: body.model, choices: [{ index: 0, message: m, finish_reason: finish }], usage: usage(out),
  });
  const toolCall = (name, args) => ({ id: 'call_' + crypto.randomUUID().slice(0, 12), type: 'function', function: { name, arguments: JSON.stringify(args) } });

  // directives in the newest client message, executed once (before any tool result)
  const newest = userText.split(/\n/).filter((l) => l.trim()).slice(-20).join('\n');
  const directives = [...newest.matchAll(/\/tool\s+([a-z_]+)\s*(\{.*?\})?(?=\s*(\/tool|$))/gms)]
    .map((m) => ({ name: m[1], args: m[2] ? JSON.parse(m[2]) : {} }))
    .filter((d) => toolNames.includes(d.name));
  if (last.role === 'user' && directives.length) {
    return message({ role: 'assistant', content: null, tool_calls: directives.map((d) => toolCall(d.name, d.args)) }, 20, 'tool_calls');
  }

  const toolResults = msgs.filter((m) => m.role === 'tool').map((m) => String(m.content).slice(0, 300));
  const clientLine = newest.split('\n').filter((l) => !l.startsWith('/tool')).pop() || '';
  const reply = toolResults.length && last.role === 'tool'
    ? `Stub: ${toolResults[toolResults.length - 1]}`
    : `Stub reply to: ${clientLine.slice(0, 200)}`;
  const final = { reply, understood: !/\?\?/.test(newest) };
  const format = (body.tools || []).find((t) => t.function && t.function.name === 'format_final_json_response');
  if (format) {  // n8n wraps the parser schema as { output: ... }
    const args = format.function.parameters?.properties?.output ? { output: final } : final;
    return message({ role: 'assistant', content: null, tool_calls: [toolCall('format_final_json_response', args)] }, 30, 'tool_calls');
  }
  return message({ role: 'assistant', content: reply }, 30, 'stop');
}

// Hashed bag of words: cosine similarity tracks word overlap, enough for RAG plumbing.
function embed(text, dims) {
  const v = new Float64Array(dims);
  for (const w of String(text).toLowerCase().match(/[\p{L}\p{N}]+/gu) || []) {
    const h = crypto.createHash('md5').update(w).digest();
    v[h.readUInt32LE(0) % dims] += 1;
  }
  const norm = Math.hypot(...v) || 1;
  return Array.from(v, (x) => x / norm);
}

// ---------------------------------------------------------------- router
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://stub');
  const p = url.pathname;
  const body = await readBody(req);
  try {
    if (p === '/health') return send(res, 200, { ok: true });
    if (p === '/_calls') {
      const since = Number(url.searchParams.get('since') || 0);
      const service = url.searchParams.get('service');
      return send(res, 200, { seq, calls: calls.filter((c) => c.seq > since && (!service || c.service === service)) });
    }
    if (p === '/_reset') { calls.length = 0; events.clear(); return send(res, 200, { ok: true }); }

    let m = p.match(/^\/telegram\/bot([^/]+)\/(\w+)$/);
    if (m) return telegram(decodeURIComponent(m[1]), m[2], body, res);

    if (p === '/v1/chat/completions') {
      record('llm', 'chat', { model: body.model, tools: (body.tools || []).map((t) => t.function.name), last: (body.messages || []).slice(-1) });
      if ((req.headers.authorization || '') === 'Bearer bad') return send(res, 401, { error: { message: 'Incorrect API key provided', type: 'invalid_request_error' } });
      if (String(body.model).includes('fail')) return send(res, 503, { error: { message: 'The model is overloaded', type: 'server_error' } });
      await sleep(delayMin + Math.random() * (delayMax - delayMin));
      return send(res, 200, chat(body));
    }
    if (p === '/v1/embeddings') {
      const input = Array.isArray(body.input) ? body.input : [body.input];
      record('llm', 'embeddings', { model: body.model, n: input.length });
      const dims = Number(body.dimensions) || 768;
      return send(res, 200, { object: 'list', model: body.model, data: input.map((t, i) => ({ object: 'embedding', index: i, embedding: embed(t, dims) })), usage: { prompt_tokens: 0, total_tokens: 0 } });
    }
    if (p === '/v1/models') return send(res, 200, { object: 'list', data: [{ id: 'stub-model', object: 'model' }] });

    if (p === '/google/token') {
      record('google', 'token', {});
      return send(res, 200, { access_token: 'stub-access-token', expires_in: 3600, token_type: 'Bearer' });
    }
    m = p.match(/^\/google\/calendar\/v3\/calendars\/([^/]+)\/events(?:\/([^/]+))?$/);
    if (m) {
      const cal = decodeURIComponent(m[1]);
      const id = m[2] || body.id;
      const key = `${cal}/${id}`;
      record('google', `${req.method} event`, { calendar: cal, id, summary: body.summary, start: body.start });
      if (cal.includes('revoked')) return send(res, 403, { error: { code: 403, message: 'Forbidden: calendar is not shared with the service account' } });
      if (req.method === 'POST') {
        if (events.has(key)) return send(res, 409, { error: { code: 409, message: 'The requested identifier already exists.' } });
        events.set(key, { ...body, status: 'confirmed' });
        return send(res, 200, { id, status: 'confirmed', htmlLink: `https://calendar.stub/${key}` });
      }
      if (req.method === 'PUT' || req.method === 'PATCH') {
        if (!events.has(key)) return send(res, 404, { error: { code: 404, message: 'Not Found' } });
        events.set(key, { ...events.get(key), ...body, status: 'confirmed' });
        return send(res, 200, { id, status: 'confirmed' });
      }
      if (req.method === 'DELETE') {
        if (!events.has(key) || events.get(key).status === 'cancelled') return send(res, 410, { error: { code: 410, message: 'Resource has been deleted' } });
        events.get(key).status = 'cancelled';
        res.writeHead(204); return res.end();
      }
      if (req.method === 'GET') return send(res, events.has(key) ? 200 : 404, events.get(key) || { error: { code: 404 } });
    }

    m = p.match(/^\/whatsapp\/([^/]+)\/messages$/);
    if (m) {
      record('whatsapp', 'messages', { phone_number_id: m[1], ...body });
      if ((req.headers.authorization || '').includes('fail')) return send(res, 401, { error: { message: 'Invalid OAuth access token', code: 190 } });
      return send(res, 200, { messaging_product: 'whatsapp', contacts: [{ input: body.to, wa_id: body.to }], messages: [{ id: 'wamid.' + crypto.randomUUID() }] });
    }

    return send(res, 404, { error: 'no stub for ' + req.method + ' ' + p });
  } catch (e) {
    return send(res, 500, { error: String(e) });
  }
}).listen(3000, () => console.log('stub listening on :3000'));

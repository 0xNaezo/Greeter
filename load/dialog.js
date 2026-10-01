// AC9: VUS concurrent clients, 5 messages each, through the real Telegram webhook of the loadtest
// tenant (stub LLM with 1-3 s latency, stub Telegram API). Run it with scripts/load.sh.
import http from 'k6/http';
import { check, sleep } from 'k6';

const URL = `${__ENV.TARGET || 'http://caddy:80'}/webhook/tg/${__ENV.ACCOUNT}`;
const RUN = Number(__ENV.RUN || Date.now() % 100000);
const MESSAGES = [
  'Hi! What services do you offer?',
  'How much is a consultation?',
  'Do you have free time tomorrow morning?',
  'Great, what about the day after?',
  'Thank you, bye!',
];

export const options = {
  scenarios: { dialogs: { executor: 'per-vu-iterations', vus: Number(__ENV.VUS || 100), iterations: 1, maxDuration: '10m' } },
  thresholds: { http_req_failed: ['rate==0'], checks: ['rate==1'] },
};

export default function () {
  const user = 900000000 + RUN * 1000 + __VU; // a new Telegram user per VU and run
  for (let i = 0; i < MESSAGES.length; i++) {
    const update = {
      update_id: user * 10 + i,
      message: {
        message_id: i + 1, date: Math.floor(Date.now() / 1000), text: MESSAGES[i],
        chat: { id: user, type: 'private', first_name: 'Load' },
        from: { id: user, is_bot: false, first_name: 'Load', language_code: 'en' },
      },
    };
    const res = http.post(URL, JSON.stringify(update), {
      headers: { 'Content-Type': 'application/json', 'X-Telegram-Bot-Api-Secret-Token': __ENV.SECRET },
    });
    check(res, { 'webhook 200': (r) => r.status === 200 });
    sleep(4 + Math.random() * 4); // reads the answer, types the next message
  }
}

export function handleSummary(data) {
  const m = data.metrics;
  const s = { requests: m.http_reqs.values.count, failed: m.http_req_failed.values.passes ?? 0,
              p95_ms: Math.round(m.http_req_duration.values['p(95)']) };
  return { '/reports/k6-summary.json': JSON.stringify(s), stdout: `k6: ${JSON.stringify(s)}\n` };
}

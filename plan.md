# AI Front Desk — план реализации (для ИИ-агента)

Основа: `tz.md`. Здесь зафиксированы архитектурные решения, которые дорого менять потом, и порядок работ. Детали внутри фаз выбирает исполнитель.

Проект — портфолио n8n-команды, поэтому вся логика приложения живёт в воркфлоу n8n. Вне n8n только то, что n8n делать не должен: схема и инварианты БД (SQL), статический виджет, дашборд (Grafana) и тестовый инструментарий.

## 0. Ключевые решения

1. **n8n — всё приложение.** Приём вебхуков, диалог, AI-агент, запись, эскалация, напоминания, интеграции, алерты, онбординг клиники, eval.
2. **Инварианты — в Postgres.** У n8n нет транзакций между нодами, поэтому каждая мутация = один вызов SQL-функции из Postgres-ноды = одна транзакция. Уникальные ключи дают идемпотентность, exclusion constraint исключает двойную запись.
3. **Масштабирование — n8n queue mode.** Redis + воркеры, `docker compose up --scale n8n-worker=N`.
4. **Надёжность без своей очереди.**
   - Fast path: побочный эффект выполняется сразу, у внешних HTTP-нод включён Retry On Fail.
   - Сверка по состоянию: у каждого эффекта есть отметка (`processed_at`, `sent_at`, `gcal_synced_at`, `reminder_24h_sent_at`…). `cron.reconcile` раз в минуту находит незавершённое и доделывает.
   - Очередь разбора = упавшие executions. Error Workflow пишет инцидент и шлёт алерт в Telegram с кнопкой Replay; Replay = retry execution через n8n API.
5. **Один ход на диалог одновременно.** Lease на conversation (`UPDATE … WHERE lease истёк RETURNING`). Держатель забирает все необработанные входящие, после освобождения lease проверяет, не пришло ли новое. Кто не взял lease — завершается.
6. **Агент = AI Agent node.** Model Selector выбирает модель по профилю LLM тенанта (`gemini | groq | stub`) — замена LLM конфигом. Enable Fallback Model (Groq) — переключение при 429 и сбоях.
7. **LLM ничего не меняет сам.** Мутации двухшаговые: tool `propose_*` создаёт `pending_action` и кнопки → подтверждение кнопкой (детерминированная ветка без LLM) или tool `confirm_action` в следующем ходе → изменение выполняет SQL-функция.
8. **Цены, услуги, врачи, часы — из БД, не из RAG.** Структурные данные тенанта маленькие и целиком идут в системный промпт. RAG = PGVector Store с metadata filter по `tenant_id`, только статьи базы знаний.
9. **Мультитенантность.** `tenant_id` в каждой таблице, составные FK `(tenant_id, id)`. В tools `tenant_id` / `client_id` подставляются выражением из контекста хода, никогда через `$fromAI` — это главная защита от prompt injection. `scripts/check-workflows.sh` проверяет экспорт: каждый SQL по тенантным таблицам фильтрует по `tenant_id`. RLS не используем: каждая Postgres-нода — отдельная транзакция, сессионного контекста тенанта нет.
10. **Воркфлоу как код.** Источник правды — `n8n/workflows/*.json` в репо. Bootstrap импортирует их и создаёт credentials из `.env` с фиксированными id, чтобы ссылки в воркфлоу совпадали.

## 1. Сервисы (docker-compose)

- `postgres`: образ → `pgvector/pgvector:pg17`. n8n пока пустой (0 workflows, 0 credentials), поэтому `docker compose down -v` + `scripts/bootstrap.sh` безопасны. Две БД: `n8n` и `app`. Расширения в `app`: `vector`, `btree_gist`, `pgcrypto`.
- `redis`, `n8n` (main: UI, триггеры, вебхуки), `n8n-worker` (`command: worker`, масштабируется). `EXECUTIONS_MODE=queue`. Если приём вебхуков упрётся в main — добавить `n8n-webhook` процессоры за Caddy.
- `grafana`: дашборд и read-only админка, provisioning из репо.
- `caddy` (profile `prod`): TLS; наружу только `/webhook/*`, демо-страница, Grafana. UI n8n и формы админки — через SSH-туннель или basic auth.
- `stub` (profile `load`): fake OpenAI-совместимый LLM с задержкой 1–3 с + fake Telegram Bot API. Несколько десятков строк на Node, только для нагрузочного теста.
- Dev: cloudflared quick tunnel для вебхуков Telegram.

## 2. Модель данных (P0)

Все таблицы с `tenant_id`, кроме `incidents`.

```
tenants            slug, name, timezone, llm_profile, config jsonb (тон, языки, SLA оператора N мин, operator_chat_id, экстренный телефон)
channel_accounts   channel(telegram|widget|whatsapp), external_id, api_base, token_enc (pgcrypto), webhook_secret
branches           …, calendar_id
doctors, services(price, duration_min), doctor_services
doctor_shifts      doctor_id, branch_id, period tstzrange
kb_chunks          таблица PGVector-ноды: text, metadata {tenant_id, article}, embedding
clients            name, phone, summary, operator_topic_id
client_identities  channel_account_id, external_user_id → client_id, UNIQUE
                   (склейка по телефону в P1 = перевесить identity на другой client)
conversations      client_id UNIQUE, state(bot|operator), last_identity_id, not_understood_streak,
                   lease_until, awaiting_operator_since, sla_notified_at
sessions           conversation_id, started_at — эпизод для метрик; новая сессия после паузы > 12 ч
messages           session_id, direction, author(client|bot|operator|system), external_id, text, payload, processed_at, sent_at
                   UNIQUE (channel_account_id, external_id) WHERE direction = 'in'      ← идемпотентность вебхуков
appointments       client, doctor, branch, service, period tstzrange, status(booked|cancelled|done|no_show),
                   gcal_event_id, gcal_synced_at, reminder_24h_sent_at, reminder_2h_sent_at, updated_at
                   EXCLUDE USING gist (doctor_id WITH =, period WITH &&) WHERE (status = 'booked')  ← нет двойной записи
pending_actions    conversation_id, kind(book|reschedule|cancel), payload, status, expires_at
escalations        session_id, reason(user_request|complaint|medical|urgent|not_understood|tool_error), first_reply_at, returned_at
trace_events       session_id, execution_id, type(msg_in|decision|tool|msg_out|error), data jsonb, duration_ms
llm_usage          session_id, execution_id, model, tokens_in, tokens_out, cost_usd (по прайсу платного тарифа, даже на free tier)
incidents          workflow, node, execution_id, error, status(open|replayed|resolved), alerted_at
```

SQL-функции (всё, что должно быть атомарным):

- `ingest_message(...)` → identity → client → conversation → session → message `ON CONFLICT DO NOTHING`; возвращает, новое ли сообщение.
- `available_slots(tenant, service, branch, doctor?, from, to)` — смены минус записи.
- `confirm_action(tenant, pending_id)` — запись / перенос / отмена; конфликт exclusion → понятная ошибка «слот заняли».
- `upsert_tenant(jsonb)` — онбординг клиники из конфига.
- Триггер на `appointments`: `updated_at`; при смене времени сбрасывает отметки напоминаний и `gcal_synced_at`. Поэтому правка записи из любого источника (бот, админка P1) сама подхватывается сверкой.

Время — `timestamptz`, часовой пояс филиала из конфига. Тесты функций — `db/tests/*.sql` на `ASSERT`, запускаются `scripts/migrate.sh --test`.

## 3. Воркфлоу

Имена `область.действие`. У каждого воркфлоу Error Workflow = `ops.error`.

| Воркфлоу | Триггер | Что делает |
| --- | --- | --- |
| `in.telegram` | Webhook `tg/:account` | Проверка `X-Telegram-Bot-Api-Secret-Token` по `channel_accounts` → 200 → Switch: клиент / кнопка / сообщение оператора в топике |
| `in.widget` | Webhooks `widget/:account/{session,send,poll}` | Сессия с HMAC-токеном (Crypto node), приём сообщений, polling ответов |
| `out.send` | sub-workflow | Отправка в канал из `last_identity_id`, кнопки, `sent_at`. Токен бота расшифровывается здесь; сохранение успешных executions выключено |
| `core.process` | sub-workflow | Lease → контекст одним SQL → `state = operator`? переслать в топик : срочные симптомы? шаблон + эскалация : `core.turn` → `out.send` → trace → освободить lease → проверить новые |
| `core.turn` | sub-workflow | AI Agent (Model Selector + fallback + tools + Structured Output Parser `{reply, understood}`). Execution Data: `tenant_id`, `session_id`. Его же вызывает eval |
| `agent.tools` | sub-workflow | Switch по имени tool: `search_kb`, `find_slots`, `save_client_info`, `propose_*`, `confirm_action`, `escalate` |
| `core.action` | sub-workflow | Кнопки: подтвердить / отменить / перенести / вернуть боту → SQL-функция → ответ клиенту |
| `handoff.escalate` | sub-workflow | LLM-резюме → топик клиента (`createForumTopic` один раз) + история + кнопка «Вернуть боту» → `state = operator` |
| `handoff.operator_reply` | sub-workflow | Сообщение из топика → по `message_thread_id` клиенту в его канал |
| `int.gcal` | sub-workflow | Upsert / delete события через HTTP Request с Google OAuth. `event_id` = uuid записи без дефисов → повторный create идемпотентен |
| `cron.reminders` | каждые 5 мин | Записи в окне 24 ч / 2 ч без отметки → claim отметки → напоминание с кнопками |
| `cron.operator_sla` | каждую минуту | Оператор молчит N мин → заглушка клиенту + пинг в топик |
| `cron.reconcile` | каждую минуту | Непроцессированные входящие без живого lease, неотправленные исходящие, записи с `gcal_synced_at < updated_at` |
| `cron.usage` | каждые 5 мин | n8n API → executions `core.turn` → `tokenUsage` LLM-нод → `llm_usage` |
| `ops.error` | Error Trigger | Инцидент + алерт в Telegram-чат платформы (dedupe по воркфлоу / ноде, 10 мин) с кнопкой Replay |
| `ops.replay` | Telegram Trigger (бот платформы) | Replay → n8n API retry execution → статус инцидента |
| `admin.onboard` | Form | Загрузка `tenant.json` + статей `.md` → `upsert_tenant` → переиндексация KB (Data Loader → splitter → Gemini Embeddings → PGVector) → `setWebhook` → проверка прав бота в операторской группе |
| `eval.run` | Evaluation Trigger | См. раздел 6 |

## 4. Ключевые потоки

**Входящее сообщение.** Вебхук → проверка подписи → 200 сразу → `ingest_message`. Дубль вебхука — функция вернёт «не новое», дальше ничего не происходит. Новое → `core.process`. Пачка сообщений обрабатывается одним ходом.

**Ход агента.**

- Промпт: платформенные правила в system message агента (безопасность, только из базы знаний, подтверждение, эскалация, язык клиента) + блок тенанта из БД (филиалы, часы, врачи, услуги с ценами, тон) + профиль клиента и его записи + открытые `pending_actions` + summary + последние ~20 сообщений из `messages`. Memory-ноду не используем: сообщения оператора и нажатия кнопок уже лежат в `messages`, второй источник истории не нужен.
- `understood = false` два раза подряд → `escalate(not_understood)`. Ошибка tool → `escalate(tool_error)` + понятное сообщение клиенту. Упали обе модели → шаблон «передаю администратору» + эскалация; сообщение уже сохранено.
- Tool calls (intermediate steps) → `trace_events` со ссылкой на execution: наш трейс — индекс, execution n8n — полная детализация.

**Срочные симптомы.** Regex по EN/UK/RU до LLM → шаблонный ответ с экстренным телефоном из конфига + `escalate(urgent)`. Агент тоже может вызвать `escalate(urgent)`.

**Эскалация.** Бот — админ операторской супергруппы с `can_manage_topics`. `state = operator`, бот молчит, сообщения клиента пересылаются в топик. «Вернуть боту» → `state = bot`.

**Запись.** `find_slots` → `propose_booking` → кнопки (Telegram `callback_data` ≤ 64 байт) → `confirm_action` → подтверждение клиенту + fast path `int.gcal`. Напоминания и повтор синхронизации календаря подхватываются по отметкам, отдельно планировать их не нужно. Кнопка «отменить» в напоминании тоже ведёт через подтверждение.

**Сбои (AC7).** LLM: fallback-модель, потом шаблон + эскалация. Календарь: запись уже в БД, клиент получил подтверждение, `cron.reconcile` повторяет синхронизацию, `ops.error` шлёт алерт.

## 5. Дашборд и админка

- Grafana + SQL views. Переменные: тенант, филиал, период. Метрики из ТЗ 4.7 считаются из `sessions`, `appointments`, `escalations`, `messages`, `llm_usage`.
- Anonymous Viewer только на папку Public (демо), остальное за логином.
- **P0:** read-only панели Grafana — клиенты, записи, диалоги, трейс по `session_id`, открытые инциденты. Конфиг клиники меняется через форму `admin.onboard`.
- **P1: NocoDB поверх той же БД `app`.** Таблицы-гриды с CRUD для клиник, филиалов, врачей, услуг и цен, смен, клиентов и записей; роли viewer / editor. Кода нет, это один контейнер. Прямые правки безопасны: двойную запись блокирует exclusion constraint, а изменения записей подхватывают триггер и `cron.reconcile` (календарь, напоминания). Переиндексация KB остаётся формой n8n. Подключение внешней Postgres в актуальной версии NocoDB CE проверить до старта P1.

## 6. Качество

- **Eval (n8n Evaluations).** Сценарии лежат в `evals/scenarios.json` и при bootstrap синхронизируются в Data Table. Их 40+: запись, перенос, отмена, цены, вопросы вне базы знаний, срочные симптомы, попытки взлома промпта, смешение языков. Строка = сценарий с репликами клиента и ожиданиями. `eval.run` прогоняет реплики через `core.turn` на eval-тенанте. Метрики: Tools Used + custom из Code-ноды (ожидаемый tool, причина эскалации, в ответе нет цен и услуг вне прайса, язык ответа). История прогонов — во вкладке Evaluations, отчёт пишется в `reports/eval-<date>.md` (Read/Write Files, volume `./reports`). Порог 90%. В community-версии evaluations доступны ограниченному числу воркфлоу — нужен один. Учесть дневные лимиты free tier: прогон может съесть квоту, гонять на отдельном ключе или на Groq.
- **Нагрузка.** k6 в docker. Отдельный тенант `loadtest` с `llm_profile = stub` и `api_base` Telegram-аккаунта на `stub`. 100 VU × диалог из 5 сообщений через `in.telegram` — реальный путь, без поллинга виджета. После прогона по SQL: входящих без `processed_at` = 0, исходящих без `sent_at` = 0, p95 = `msg_out − msg_in`. Отчёт `reports/load-<date>.md`.

## 7. Структура репозитория

```
docker-compose.yml  Caddyfile  .env.example
db/migrations/*.sql     схема, функции, триггеры, views
db/tests/*.sql          ASSERT-тесты функций
db/seed/*.sql           демо: смены на 4 недели, 200+ клиентов с историей, исторические сессии и usage для дашборда
n8n/workflows/*.json    экспорт — источник правды
tenants/<slug>/tenant.json, tenants/<slug>/kb/*.md
evals/scenarios.json
web/                    демо-страница клиники + widget.js
stub/                   fake LLM + fake Telegram API
load/dialog.js          k6
grafana/provisioning/, grafana/dashboards/*.json
reports/
scripts/bootstrap.sh migrate.sh export-workflows.sh check-workflows.sh
```

## 8. Фазы

Каждая фаза закрывается своей проверкой. AC — критерии приёмки из ТЗ, раздел 9.

| # | Фаза | Готово, когда |
| --- | --- | --- |
| 0 | Каркас: compose (pgvector, redis, worker), миграции, функции + тесты, импорт воркфлоу и credentials, seed | `./scripts/bootstrap.sh` поднимает всё с нуля; `migrate.sh --test` зелёный |
| 1 | Каналы: `in.telegram`, `in.widget`, `out.send`, `core.process` с эхо-ответом, `cron.reconcile` | AC6; воркер убит посреди обработки → ответ всё равно приходит |
| 2 | Агент: `core.turn`, `agent.tools`, запись / перенос / отмена, RAG, срочные симптомы, трейс. **Первым делом spike:** достаётся ли `tokenUsage` через n8n API | AC1 (без календаря), AC3, AC4; первые 10 eval-сценариев проходят |
| 3 | Оператор: топики, маршрутизация ответов, молчание бота, возврат, SLA | AC5 |
| 4 | Жизненный цикл и надёжность: напоминания с кнопками, `int.gcal`, `ops.error`, `ops.replay`, `cron.usage` | AC1 целиком, AC2, AC7 (учения: неверный ключ LLM, отозванный доступ к календарю) |
| 5 | Дашборд: views, provisioning, админ-панели, трейс | Все метрики 4.7 на seed-данных, фильтры работают |
| 6 | Качество: 40+ eval, k6 | AC9, AC10, отчёты в `reports/` |
| 7 | Упаковка: второй тенант через форму, README, схема архитектуры, деплой на VPS | AC8 (засечь время); bootstrap на чистой машине |
| P1 | WhatsApp (`in.whatsapp`, `X-Hub-Signature-256` через Crypto node), склейка по телефону, неявки / отзывы / реактивация (cron-воркфлоу с лимитом отправок), NocoDB | — |

## 9. Правила для агента

1. Воркфлоу правятся через n8n MCP; после изменения — `scripts/export-workflows.sh` (без credentials) и `scripts/check-workflows.sh`.
2. Одна мутация = один вызов SQL-функции. Цепочки из нескольких пишущих Postgres-нод запрещены.
3. Каждый SQL по тенантным таблицам фильтрует по `tenant_id`. В tools идентификаторы тенанта и клиента задаются выражением из контекста, не через `$fromAI`.
4. Новый побочный эффект = отметка в таблице + ветка в `cron.reconcile`.
5. У внешних HTTP-нод включён Retry On Fail; Error Workflow у всех воркфлоу — `ops.error`.
6. Изменение промпта или модели → прогон `eval.run`, отчёт коммитится вместе с изменением.
7. Секреты только в credentials и `.env`; новая переменная сразу попадает в `.env.example`.
8. Воркфлоу больше ~40 нод режется на sub-workflow.

## 10. Сознательно не делаем

- TS-сервис: всё, кроме SQL и тестового инструментария, живёт в n8n.
- Своя очередь задач: fast path + сверка по отметкам + упавшие executions как очередь разбора.
- RLS: изоляция через `tenant_id` в каждом запросе, составные FK и статическую проверку экспорта.
- LiteLLM: Model Selector + fallback-модель покрывают замену и переключение LLM.
- Индекс pgvector: меньше 1k чанков на тенанта, seq scan достаточно.
- SSE для виджета: polling раз в 1,5 с, каждый poll — execution n8n. Для демо нормально; при реальном трафике понадобится компонент вне n8n.

Известные ограничения:

- Стоимость на диалог считается разбором execution data через n8n API. Если spike в фазе 2 покажет, что `tokenUsage` недоступен, — оценка по длине текста с пометкой «estimate» на дашборде.
- Расшифрованный токен бота попадает в данные execution `out.send`. Успешные executions этого воркфлоу не сохраняются, упавшие живут `EXECUTIONS_DATA_MAX_AGE`, UI n8n доступен только админу.

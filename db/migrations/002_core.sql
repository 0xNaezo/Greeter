-- Core functions: helpers, i18n, message ingestion, conversation turns (lease, context, result).
-- Rule: every mutation a workflow makes is one call to one of these functions = one transaction.

create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger tenants_updated before update on tenants for each row execute function set_updated_at();
create trigger clients_updated before update on clients for each row execute function set_updated_at();

-- Any change of an appointment (bot, admin grid, SQL) re-arms the calendar mirror; a new time
-- re-arms reminders. cron.reconcile and cron.reminders pick the rest up from these marks.
create function appointments_touch() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and (new.period, new.status, new.doctor_id, new.branch_id, new.service_id, new.client_id)
      is not distinct from (old.period, old.status, old.doctor_id, old.branch_id, old.service_id, old.client_id) then
    return new;  -- only marks changed
  end if;
  new.updated_at := now();
  new.gcal_synced_at := null;
  new.gcal_attempts := 0;
  new.gcal_next_at := null;
  if tg_op = 'UPDATE' and new.period is distinct from old.period then
    new.reminder_24h_sent_at := null;
    new.reminder_2h_sent_at := null;
    new.confirmed_at := null;
  end if;
  return new;
end $$;
create trigger appointments_touch before insert or update on appointments for each row execute function appointments_touch();

-- ---------------------------------------------------------------- helpers

-- Script-based guess, good enough for templates and buttons (the LLM mirrors the client itself).
-- null = no signal (digits, emoji, ambiguous Cyrillic such as "так").
create function detect_lang(p_text text) returns text language sql immutable as $$
  select case
    when p_text ~ '[іїєґІЇЄҐ]' then 'uk'
    when p_text ~ '[ыэёъЫЭЁЪ]' then 'ru'
    when lower(p_text) ~ '\m(что|как|когда|сколько|стоит|можно|спасибо|пожалуйста|здравствуйте|меня|нужно|хочу|есть|где|или|врач|запись|завтра|сегодня)\M' then 'ru'
    when lower(p_text) ~ '\m(що|як|коли|скільки|коштує|можна|дякую|будь|вітаю|мене|потрібно|добрий|лікар|запис|завтра|сьогодні|чи)\M' then 'uk'
    when p_text ~ '[а-яА-Я]' then null
    when p_text ~ '[a-zA-Z]{2,}' then 'en'
  end
$$;

-- Urgent dental symptoms (EN/UK/RU), checked before the LLM (AC4). Severe pain, trauma and bleeding that does
-- not stop are urgent however they are written. Swelling, bleeding, abscess or injury are urgent when the client
-- reports them ("my cheek is swollen", "кровоточат десны"), not in a general question ("how long does swelling
-- last after an extraction?", "чи буде набряк?"): those go to the agent, which answers from the knowledge base
-- and may still escalate. Negated symptoms ("no swelling", "не болит") do not count.
-- ponytail: keyword heuristics; a small classifier model if eval shows misses.
create function is_urgent(p_text text) returns boolean language sql immutable as $$
  with n as (
    select regexp_replace(translate(lower(coalesce(p_text, '')), 'ё’', 'е'''),
      '\m(no|not|never|without|(don|doesn|didn|isn|aren|wasn|haven|hasn)''t|не|нет|нету|без|немає|нема)\s+'
      || '((have|has|feel|feels|see|any|much|so|too|very|really|очень|сильно|дуже|особо|особливо|так|уже|вже|больше|більше)\s+){0,2}'
      || '(swell|swollen|bleed|pain|hurt|ache|бол|біл|кров|опух|отек|набряк)\w*', ' ', 'g') as s
  )
  select s ~ concat_ws('|',
      -- en
      '(severe|unbearable|terrible|extreme|excruciating|intense|awful|horrible|strong|really bad|very bad)\w*\s+(\w+\s+){0,2}(pain|ache|toothache)',
      '(hurts?|hurting|aches?|aching|pain)\s+(so|really|very|too)\s+(much|bad|badly)',
      '(can''t|cannot|can not)\s+sleep', '(pain|hurt|ache).*(can''t|cannot|can not)\s+(eat|chew)',
      '(can''t|cannot|can not)\s+(eat|chew).*(pain|hurt|ache)',
      'bleeding\s+(a lot|heavily|badly|non-?stop)', '(blood|bleeding)\s+(won''t|will not|doesn''t|does not|can''t|isn''t)\s+stop',
      'knocked\s+(\w+\s+){0,2}out', 'broke\w*\s+(\w+\s+){0,2}(tooth|teeth|jaw)', '\mbroken\s+(tooth|teeth|jaw)',
      -- ru, uk
      '(сильн|невыносим|ужасн|жутк|очень|дико|страшн|нестерпн|жахлив|дуже)\w*\s+(\w+\s+){0,2}(бол(?!ьш)|біль\M|болю)',
      'не\s+могу\s+спать', 'не\s+можу\s+спати', 'не\s+могу\s+(есть|жевать).*бол', 'не\s+можу\s+(їсти|жувати).*бол',
      'кровь\s+не\s+останавлива', 'не\s+останавливается\s+кровь', 'кров\s+не\s+зупиня', '(сильно|очень|дуже)\s+кров',
      '\m(выбил|вибив|сломал|зламав)\w*\s+(\w+\s+){0,2}зуб', '\mфлюс', '\mгно[йяиї]', '\mгній')
    or (s ~ '(swell|swollen|bleed|abscess|injur|trauma|\mpus\M|\mотек|\mопух|\mраспух|\mрозпух|кровоточ|кровотеч|\mкрови[тл]|\mкровить|абсцес|\mтравм(?!атолог)|\mнабряк)'
        and (s !~ '\?|(^|[.!,;:]\s*)(how|what|when|why|which|where|do|does|did|is|are|can|could|should|will|would|сколько|как|когда|почему|зачем|что|где|есть ли|можно|скільки|як|коли|чому|що|де|чи)\M'
             -- a question about the client's own mouth still counts
             or s ~ concat_ws('|',
                  '\m(my|me|our|we)\M', '\mi\s+(have|had|got|feel|felt|noticed|am|''m|''ve)\M', '\mi''(m|ve)\M',
                  '\m(мне|меня|мой|моя|мое|мои|моего|моей|мені|мене|мій|моє|мої|мого|моєї)\M',
                  '\mу\s+(ребенка|сына|дочки|дочери|мужа|жены|дитини|сина|доньки|чоловіка|дружини)\M',
                  '\w+\s+(is|are|am|keeps?|kept|started|still)\s+(swollen|swelling|bleeding)',
                  '\m(опух(ла|ло|ли|ает|ают)?|распух\w*|отекл\w*|отекает|кровит|кровят|кровоточ(ит|ат)|набрякл\w*|набрякає|розпух\w*|кровить|кровлять|кровоточ(ить|ать))\M',
                  'что\s+(мне\s+)?делать|що\s+(мені\s+)?робити|what\s+(should|can|do)\s+i\s+do|what\s+to\s+do')))
  from n
$$;

-- '+380501234567' or null. Local UA numbers (0XXXXXXXXX) get +380.
create function normalize_phone(p_phone text) returns text language plpgsql immutable as $$
declare
  d text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
begin
  if d ~ '^00' then d := '+' || substr(d, 3); end if;
  if d ~ '^0[0-9]{9}$' then d := '+38' || d; end if;
  if d ~ '^380[0-9]{9}$' then d := '+' || d; end if;
  if d ~ '^\+[0-9]{8,15}$' then return d; end if;
  return null;
end $$;

-- Button callbacks handled deterministically by core.action (no LLM). Telegram limit: 64 bytes.
--   pa:<pending>:y|n   confirm / reject a proposed change
--   ap:<appt>:c|x      reminder: I'll come / cancel (cancel still asks for confirmation)
--   rv:<appt>:1..5     review score (P1)
-- Other callbacks (ap:<appt>:r reschedule, ap:<appt>:b rebook) go to the agent as text. The id must be a real
-- uuid: callback data comes from the client (widget, crafted Telegram callbacks) and is cast to uuid later.
create function is_action_callback(p_data text) returns boolean language sql immutable as $$
  select coalesce(p_data ~ '^(pa:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[yn]|ap:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[cx]|rv:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[1-5])$', false)
$$;

create function tenant_tz(p_tenant uuid, p_branch uuid default null) returns text language sql stable as $$
  select coalesce((select b.timezone from branches b where b.tenant_id = p_tenant and b.id = p_branch),
                  (select t.timezone from tenants t where t.id = p_tenant), 'UTC')
$$;

-- "Center +380 44 000 11 00, Podil +380 44 000 22 00" for messages that send the client to the phone.
create function clinic_phones(p_tenant uuid) returns text language sql stable as $$
  select coalesce((select string_agg(b.name || ' ' || b.phone, ', ' order by b.slug) from branches b
                   where b.tenant_id = p_tenant and nullif(trim(b.phone), '') is not null),
                  (select t.config ->> 'emergency_phone' from tenants t where t.id = p_tenant), '')
$$;

-- A human can take a conversation over: the clinic has an operator group and an active Telegram bot to reach it.
create function tenant_has_operator(p_tenant uuid) returns boolean language sql stable as $$
  select exists (select 1 from tenants t join channel_accounts ca on ca.tenant_id = t.id
                 where t.id = p_tenant and nullif(t.config -> 'operator' ->> 'chat_id', '') is not null
                   and ca.channel = 'telegram' and ca.active and ca.token_enc is not null)
$$;

-- "Fri 03.10 10:00" in the given timezone, weekday in the client's language
create function fmt_when(p_ts timestamptz, p_tz text, p_lang text default 'en') returns text language sql immutable as $$
  select (case coalesce(p_lang, 'en')
            when 'uk' then array['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд']
            when 'ru' then array['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']
            else array['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] end
         )[extract(isodow from p_ts at time zone p_tz)::int]
         || ' ' || to_char(p_ts at time zone p_tz, 'DD.MM HH24:MI')
$$;

-- ---------------------------------------------------------------- i18n

create function t(p_key text, p_lang text, p_args jsonb default '{}') returns text
language plpgsql immutable as $$
declare
  v text;
  k text;
  val text;
begin
  select coalesce(max(x.txt) filter (where x.lang = coalesce(p_lang, 'en')), max(x.txt) filter (where x.lang = 'en'))
  into v
  from (values
    ('btn.confirm', 'en', '✅ Confirm'), ('btn.confirm', 'uk', '✅ Підтвердити'), ('btn.confirm', 'ru', '✅ Подтвердить'),
    ('btn.reject', 'en', '✖️ Cancel'), ('btn.reject', 'uk', '✖️ Скасувати'), ('btn.reject', 'ru', '✖️ Отменить'),
    ('btn.cancel_yes', 'en', '✅ Yes, cancel it'), ('btn.cancel_yes', 'uk', '✅ Так, скасувати'), ('btn.cancel_yes', 'ru', '✅ Да, отменить'),
    ('btn.cancel_no', 'en', '↩️ Keep it'), ('btn.cancel_no', 'uk', '↩️ Залишити'), ('btn.cancel_no', 'ru', '↩️ Оставить'),
    ('btn.attend', 'en', '✅ I''ll come'), ('btn.attend', 'uk', '✅ Прийду'), ('btn.attend', 'ru', '✅ Приду'),
    ('btn.reschedule', 'en', '🔁 Reschedule'), ('btn.reschedule', 'uk', '🔁 Перенести'), ('btn.reschedule', 'ru', '🔁 Перенести'),
    ('btn.cancel', 'en', '✖️ Cancel visit'), ('btn.cancel', 'uk', '✖️ Скасувати візит'), ('btn.cancel', 'ru', '✖️ Отменить визит'),
    ('btn.rebook', 'en', '📅 Book a new time'), ('btn.rebook', 'uk', '📅 Записатися знову'), ('btn.rebook', 'ru', '📅 Записаться снова'),

    ('urgent', 'en', 'This sounds urgent. With severe pain, swelling, bleeding or an injury please call our emergency line {phone} now, or 112 if it is getting worse. I am also passing your message to our administrator, who will contact you shortly. I cannot give medical advice here.'),
    ('urgent', 'uk', 'Це схоже на невідкладний стан. При сильному болю, набряку, кровотечі чи травмі зателефонуйте зараз на нашу екстрену лінію {phone}, а якщо стає гірше — 112. Я також передаю ваше повідомлення адміністратору, він скоро з вами зв''яжеться. Медичних порад тут я дати не можу.'),
    ('urgent', 'ru', 'Похоже на срочное состояние. При сильной боли, отёке, кровотечении или травме позвоните сейчас на нашу экстренную линию {phone}, а если становится хуже — 112. Я также передаю ваше сообщение администратору, он скоро с вами свяжется. Медицинских советов здесь я дать не могу.'),
    ('handoff', 'en', 'I am passing your question to our administrator. They will reply right here soon.'),
    ('handoff', 'uk', 'Передаю ваше питання адміністратору. Він відповість тут найближчим часом.'),
    ('handoff', 'ru', 'Передаю ваш вопрос администратору. Он ответит здесь в ближайшее время.'),
    ('fallback', 'en', 'Sorry, I am having technical trouble right now. I have passed your message to our administrator, who will reply here soon.'),
    ('fallback', 'uk', 'Вибачте, зараз у мене технічні труднощі. Я передав ваше повідомлення адміністратору, він скоро відповість тут.'),
    ('fallback', 'ru', 'Извините, сейчас у меня технические трудности. Я передал ваше сообщение администратору, он скоро ответит здесь.'),
    ('no_operator', 'en', 'Our administrators cannot answer in this chat right now. Please call the clinic: {phones}.'),
    ('no_operator', 'uk', 'Наші адміністратори зараз не можуть відповісти в цьому чаті. Будь ласка, зателефонуйте в клініку: {phones}.'),
    ('no_operator', 'ru', 'Наши администраторы сейчас не могут ответить в этом чате. Пожалуйста, позвоните в клинику: {phones}.'),
    ('operator_wait', 'en', 'Thanks for waiting! Our administrator is a bit busy and will answer you as soon as possible.'),
    ('operator_wait', 'uk', 'Дякуємо за очікування! Адміністратор трохи зайнятий і відповість вам якнайшвидше.'),
    ('operator_wait', 'ru', 'Спасибо за ожидание! Администратор немного занят и ответит вам как можно скорее.'),
    ('back_to_bot', 'en', 'You are chatting with the virtual assistant again. How can I help?'),
    ('back_to_bot', 'uk', 'Ви знову спілкуєтеся з віртуальним асистентом. Чим можу допомогти?'),
    ('back_to_bot', 'ru', 'Вы снова общаетесь с виртуальным ассистентом. Чем могу помочь?'),

    ('booked', 'en', '✅ Booked: {service} with {doctor}, {branch} ({address}), {when}. See you!'),
    ('booked', 'uk', '✅ Записано: {service}, лікар {doctor}, {branch} ({address}), {when}. Чекаємо на вас!'),
    ('booked', 'ru', '✅ Записано: {service}, врач {doctor}, {branch} ({address}), {when}. Ждём вас!'),
    ('rescheduled', 'en', '✅ Moved: {service} with {doctor}, {branch}, now {when}.'),
    ('rescheduled', 'uk', '✅ Перенесено: {service}, лікар {doctor}, {branch}, тепер {when}.'),
    ('rescheduled', 'ru', '✅ Перенесено: {service}, врач {doctor}, {branch}, теперь {when}.'),
    ('cancelled', 'en', 'Your visit on {when} is cancelled. Write any time if you want to book again.'),
    ('cancelled', 'uk', 'Ваш візит {when} скасовано. Пишіть будь-коли, якщо захочете записатися знову.'),
    ('cancelled', 'ru', 'Ваш визит {when} отменён. Пишите в любое время, если захотите записаться снова.'),
    ('rejected', 'en', 'OK, nothing changed. Anything else I can help with?'),
    ('rejected', 'uk', 'Добре, нічого не змінюю. Чим ще можу допомогти?'),
    ('rejected', 'ru', 'Хорошо, ничего не меняю. Чем ещё могу помочь?'),
    ('slot_taken', 'en', 'Sorry, that time was just taken. Shall I find another slot?'),
    ('slot_taken', 'uk', 'Вибачте, цей час щойно зайняли. Підібрати інший?'),
    ('slot_taken', 'ru', 'Извините, это время только что заняли. Подобрать другое?'),
    ('expired', 'en', 'That proposal has expired. Tell me what you would like and I will check again.'),
    ('expired', 'uk', 'Ця пропозиція вже неактуальна. Напишіть, що бажаєте, і я перевірю ще раз.'),
    ('expired', 'ru', 'Это предложение уже неактуально. Напишите, что хотите, и я проверю ещё раз.'),
    ('already_done', 'en', 'Already done 👍'), ('already_done', 'uk', 'Вже зроблено 👍'), ('already_done', 'ru', 'Уже сделано 👍'),
    ('not_found', 'en', 'I could not find that appointment. Tell me what you would like to do.'),
    ('not_found', 'uk', 'Не знайшов такого запису. Напишіть, що бажаєте зробити.'),
    ('not_found', 'ru', 'Не нашёл такую запись. Напишите, что хотите сделать.'),
    ('attend_ok', 'en', 'Thank you! See you {when}.'), ('attend_ok', 'uk', 'Дякуємо! Чекаємо на вас {when}.'), ('attend_ok', 'ru', 'Спасибо! Ждём вас {when}.'),
    ('cancel_ask', 'en', 'Cancel your visit: {service}, {when}?'),
    ('cancel_ask', 'uk', 'Скасувати візит: {service}, {when}?'),
    ('cancel_ask', 'ru', 'Отменить визит: {service}, {when}?'),

    ('reminder_24h', 'en', 'Reminder: {service} with {doctor} tomorrow, {when}, {branch} ({address}). Will you come?'),
    ('reminder_24h', 'uk', 'Нагадування: {service}, лікар {doctor}, завтра {when}, {branch} ({address}). Ви прийдете?'),
    ('reminder_24h', 'ru', 'Напоминание: {service}, врач {doctor}, завтра {when}, {branch} ({address}). Вы придёте?'),
    ('reminder_2h', 'en', 'See you soon: {service} with {doctor} at {when}, {branch} ({address}).'),
    ('reminder_2h', 'uk', 'Скоро побачимось: {service}, лікар {doctor}, {when}, {branch} ({address}).'),
    ('reminder_2h', 'ru', 'Скоро увидимся: {service}, врач {doctor}, {when}, {branch} ({address}).'),

    ('review_ask', 'en', 'Thank you for visiting {branch}! How was your {service} with {doctor}? Rate from 1 to 5:'),
    ('review_ask', 'uk', 'Дякуємо, що завітали до {branch}! Як вам {service} у лікаря {doctor}? Оцініть від 1 до 5:'),
    ('review_ask', 'ru', 'Спасибо, что посетили {branch}! Как вам {service} у врача {doctor}? Оцените от 1 до 5:'),
    ('review_thanks', 'en', 'Thank you for your feedback!'), ('review_thanks', 'uk', 'Дякуємо за відгук!'), ('review_thanks', 'ru', 'Спасибо за отзыв!'),
    ('review_sorry', 'en', 'We are sorry it was not great. Our administrator will contact you to make it right.'),
    ('review_sorry', 'uk', 'Нам шкода, що візит не вдався. Адміністратор зв''яжеться з вами, щоб усе виправити.'),
    ('review_sorry', 'ru', 'Нам жаль, что визит не удался. Администратор свяжется с вами, чтобы всё исправить.'),
    ('noshow', 'en', 'We missed you at {when} ({service}). Would you like to book a new time?'),
    ('noshow', 'uk', 'Ми чекали на вас {when} ({service}). Бажаєте записатися на інший час?'),
    ('noshow', 'ru', 'Мы ждали вас {when} ({service}). Хотите записаться на другое время?'),
    ('reactivation', 'en', 'Hi{name}! It has been a while since your last visit ({service}, {date}). A check-up every 6 months keeps your teeth healthy. Shall I find you a convenient time?'),
    ('reactivation', 'uk', 'Вітаємо{name}! Минуло чимало часу від вашого останнього візиту ({service}, {date}). Огляд раз на пів року береже зуби здоровими. Підібрати вам зручний час?'),
    ('reactivation', 'ru', 'Здравствуйте{name}! Прошло немало времени с вашего последнего визита ({service}, {date}). Осмотр раз в полгода бережёт зубы здоровыми. Подобрать вам удобное время?')
  ) as x(key, lang, txt)
  where x.key = p_key;

  if v is null then
    raise exception 'unknown i18n key %', p_key;
  end if;
  for k, val in select * from jsonb_each_text(p_args) loop
    v := replace(v, '{' || k || '}', coalesce(val, ''));
  end loop;
  return v;
end $$;

-- ---------------------------------------------------------------- channels

-- Webhook authentication: the account from the URL plus its secret (Telegram secret_token header).
-- Widget requests carry an HMAC session token checked in the workflow instead. null = reject.
create function channel_account_auth(p_account text, p_channel text, p_secret text default null) returns jsonb
language sql stable as $$
  select jsonb_build_object('account_id', ca.id, 'tenant_id', ca.tenant_id, 'external_id', ca.external_id,
                            'tenant_slug', t.slug, 'tenant_name', t.name,
                            'operator_chat_id', t.config -> 'operator' ->> 'chat_id')
  from channel_accounts ca join tenants t on t.id = ca.tenant_id
  where ca.id = case when p_account ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p_account::uuid end
    and ca.channel = p_channel and ca.active
    -- widget: visitors hold signed tokens; whatsapp POSTs carry the app-secret signature checked in in.whatsapp
    and (p_channel = 'widget' or (p_channel = 'whatsapp' and p_secret is null) or ca.webhook_secret = p_secret)
$$;

create function account_token(p_account_id uuid, p_key text) returns jsonb language sql stable as $$
  select jsonb_build_object('account_id', id, 'channel', channel, 'external_id', external_id, 'api_base', api_base,
                            'token', case when token_enc is not null then pgp_sym_decrypt(token_enc, p_key) end)
  from channel_accounts where id = p_account_id
$$;

-- ---------------------------------------------------------------- ingestion

-- Webhook -> identity -> client -> conversation -> session -> message, in one transaction.
-- Redelivery of the same provider message returns is_new = false and changes nothing (AC6).
create function ingest_message(
  p_account_id       uuid,
  p_external_user_id text,
  p_chat_id          text,
  p_external_id      text,
  p_text             text,
  p_payload          jsonb default '{}',
  p_profile          jsonb default '{}',
  p_execution_id     text default null
) returns jsonb language plpgsql as $$
declare
  v_acc     channel_accounts;
  v_ident   client_identities;
  v_client  uuid;
  v_conv    conversations;
  v_session uuid;
  v_msg     bigint;
  v_lang    text;
begin
  select * into v_acc from channel_accounts where id = p_account_id;
  if not found then
    raise exception 'unknown channel account %', p_account_id;
  end if;

  if exists (select 1 from messages
             where channel_account_id = p_account_id and external_id = p_external_id and direction = 'in') then
    return jsonb_build_object('is_new', false, 'tenant_id', v_acc.tenant_id);
  end if;

  -- first contact creates client + identity; concurrent first contacts converge on one identity
  select * into v_ident from client_identities
  where channel_account_id = p_account_id and external_user_id = p_external_user_id;
  if not found then
    v_lang := coalesce(detect_lang(p_text), substr(p_profile ->> 'language_code', 1, 2));
    insert into clients (tenant_id, name, lang)
    values (v_acc.tenant_id,
            nullif(trim(concat_ws(' ', p_profile ->> 'first_name', p_profile ->> 'last_name')), ''),
            case when v_lang in ('en', 'uk', 'ru') then v_lang end)
    returning id into v_client;

    insert into client_identities (tenant_id, channel_account_id, external_user_id, chat_id, client_id, profile)
    values (v_acc.tenant_id, p_account_id, p_external_user_id, p_chat_id, v_client, coalesce(p_profile, '{}'))
    on conflict (channel_account_id, external_user_id) do nothing
    returning * into v_ident;

    if v_ident.id is null then
      delete from clients where id = v_client;
      select * into v_ident from client_identities
      where channel_account_id = p_account_id and external_user_id = p_external_user_id;
    end if;
  else
    update client_identities
    set last_seen_at = now(), chat_id = p_chat_id, profile = profile || coalesce(p_profile, '{}')
    where id = v_ident.id;
  end if;
  -- P1 glue: a number the channel proves (the WhatsApp sender, the client's own Telegram contact) joins the
  -- profile that proved the same number. A number typed in the chat never glues profiles (save_client_info).
  v_client := glue_verified_phone(v_acc.tenant_id, v_ident.client_id, case
    when v_acc.channel = 'whatsapp' then '+' || regexp_replace(p_external_user_id, '\D', '', 'g')
    when v_acc.channel = 'telegram' and p_payload -> 'contact' ->> 'user_id' = p_external_user_id
      then p_payload -> 'contact' ->> 'phone_number'
  end);

  -- one conversation per client; the row lock serializes concurrent messages of this client
  insert into conversations (tenant_id, client_id, last_identity_id)
  values (v_acc.tenant_id, v_client, v_ident.id)
  on conflict (client_id) do update set last_identity_id = excluded.last_identity_id, updated_at = now()
  returning * into v_conv;

  select s.id into v_session from sessions s
  where s.conversation_id = v_conv.id and s.last_message_at > now() - interval '12 hours'
  order by s.started_at desc limit 1;
  if v_session is null then
    insert into sessions (tenant_id, conversation_id, channel)
    values (v_acc.tenant_id, v_conv.id, v_acc.channel)
    returning id into v_session;
  else
    update sessions set last_message_at = now() where id = v_session;
  end if;

  insert into messages (tenant_id, conversation_id, session_id, direction, author, channel_account_id,
                        identity_id, external_id, text, payload)
  values (v_acc.tenant_id, v_conv.id, v_session, 'in', 'client', p_account_id,
          v_ident.id, p_external_id, p_text, coalesce(p_payload, '{}'))
  on conflict (channel_account_id, external_id) where direction = 'in' do nothing
  returning id into v_msg;
  if v_msg is null then
    return jsonb_build_object('is_new', false, 'tenant_id', v_acc.tenant_id);
  end if;

  v_lang := detect_lang(p_text);
  if v_lang is not null then
    update clients set lang = v_lang where id = v_client and lang is distinct from v_lang;
  end if;
  if v_conv.state = 'operator' then
    update conversations set awaiting_operator_since = coalesce(awaiting_operator_since, now()) where id = v_conv.id;
  end if;

  insert into trace_events (tenant_id, session_id, execution_id, type, data)
  values (v_acc.tenant_id, v_session, p_execution_id, 'msg_in',
          jsonb_build_object('message_id', v_msg, 'channel', v_acc.channel, 'text', left(p_text, 500),
                             'callback', p_payload ->> 'callback'));

  return jsonb_build_object('is_new', true, 'message_id', v_msg, 'tenant_id', v_acc.tenant_id,
                            'conversation_id', v_conv.id, 'session_id', v_session, 'client_id', v_client,
                            'state', v_conv.state);
end $$;

-- ---------------------------------------------------------------- outbound

-- Queue a message to the client's last channel; out.send delivers it and sets sent_at,
-- cron.reconcile retries what is still unsent. Returns null when the client is unreachable.
create function enqueue_message(
  p_conversation_id uuid,
  p_author          text,
  p_text            text,
  p_payload         jsonb default '{}',
  p_session_id      uuid default null,
  p_external_id     text default null
) returns bigint language plpgsql as $$
declare
  v_conv    conversations;
  v_acc     uuid;
  v_session uuid := p_session_id;
  v_id      bigint;
begin
  select * into v_conv from conversations where id = p_conversation_id;
  if not found or v_conv.last_identity_id is null then
    return null;
  end if;
  select channel_account_id into v_acc from client_identities where id = v_conv.last_identity_id;
  if v_session is null then
    select s.id into v_session from sessions s where s.conversation_id = p_conversation_id
    order by s.started_at desc limit 1;
  end if;
  if v_session is null then
    insert into sessions (tenant_id, conversation_id, channel)
    select v_conv.tenant_id, v_conv.id, ca.channel from channel_accounts ca where ca.id = v_acc
    returning id into v_session;
  end if;

  insert into messages (tenant_id, conversation_id, session_id, direction, author, channel_account_id,
                        identity_id, text, payload, external_id)
  values (v_conv.tenant_id, v_conv.id, v_session, 'out', p_author, v_acc, v_conv.last_identity_id,
          p_text, coalesce(p_payload, '{}'), p_external_id)
  on conflict (tenant_id, external_id) where direction = 'out' and external_id is not null do nothing
  returning id into v_id;
  return v_id;
end $$;

-- Everything out.send needs, with the channel token decrypted. null = nothing to send.
create function outbound_message(p_message_id bigint, p_key text) returns jsonb language sql as $$
  select jsonb_build_object(
    'message_id', m.id,
    'tenant_id', m.tenant_id,
    'channel', ca.channel,
    'account_id', ca.id,
    'external_id', ca.external_id,
    'api_base', ca.api_base,
    'token', case when ca.token_enc is not null then pgp_sym_decrypt(ca.token_enc, p_key) end,
    'chat_id', ci.chat_id,
    'text', case when m.author = 'operator' then '👤 ' || m.text else m.text end,
    'buttons', coalesce(m.payload -> 'buttons', '[]'),
    'attempts', m.send_attempts)
  from messages m
  join channel_accounts ca on ca.tenant_id = m.tenant_id and ca.id = m.channel_account_id
  join client_identities ci on ci.tenant_id = m.tenant_id and ci.id = m.identity_id
  where m.id = p_message_id and m.direction = 'out' and m.sent_at is null and m.failed_at is null
$$;

-- Delivery result. A failure is retried by cron.reconcile with backoff (30 s doubling up to 1 h, at least the
-- provider's retry_after) for about 5 hours, then given up. An unreachable recipient (blocked the bot, chat gone)
-- is permanent at once. report = true asks out.send to open an incident: the channel account itself fails
-- (token revoked) or a message was given up; the next delivery through that account resolves it.
create function mark_sent(p_message_id bigint, p_ok boolean, p_provider_id text default null,
                          p_error text default null, p_permanent boolean default false,
                          p_retry_after int default null, p_account_problem boolean default false) returns jsonb
language plpgsql as $$
declare
  v messages;
begin
  update messages
  set sent_at = case when p_ok then now() end,
      provider_message_id = coalesce(p_provider_id, provider_message_id),
      send_attempts = send_attempts + 1,
      failed_at = case when not p_ok and (p_permanent or send_attempts + 1 >= 12) then now() end,
      next_attempt_at = case when not p_ok then now() + greatest(make_interval(secs => coalesce(p_retry_after, 0)),
                                                               least(interval '1 hour', interval '30 seconds' * power(2, send_attempts))) end
  where id = p_message_id and direction = 'out' and sent_at is null and failed_at is null
  returning * into v;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_pending');
  end if;
  if p_ok then
    perform resolve_incidents('send:' || v.channel_account_id);
    insert into trace_events (tenant_id, session_id, type, data)
    values (v.tenant_id, v.session_id, 'msg_out',
            jsonb_build_object('message_id', v.id, 'author', v.author, 'text', left(v.text, 500),
                               'latency_ms', (extract(epoch from now() - v.created_at) * 1000)::int));
  else
    insert into trace_events (tenant_id, session_id, type, data)
    values (v.tenant_id, v.session_id, 'error',
            jsonb_build_object('stage', 'send', 'message_id', v.id, 'error', left(p_error, 500),
                               'gave_up', v.failed_at is not null, 'next_attempt_at', v.next_attempt_at));
  end if;
  return jsonb_build_object('ok', p_ok, 'failed', v.failed_at is not null, 'attempts', v.send_attempts,
                            'report', not p_ok and (p_account_problem or (v.failed_at is not null and not p_permanent)),
                            'ref', 'send:' || v.channel_account_id);
end $$;

-- ---------------------------------------------------------------- conversation turn

create function conversation_history(p_conversation_id uuid, p_before_id bigint, p_limit int default 20)
returns text language sql stable as $$
  select coalesce(string_agg(
           to_char(h.created_at at time zone tenant_tz(h.tenant_id), 'DD.MM HH24:MI') || ' '
           || case h.author when 'client' then 'Client' when 'bot' then 'Assistant'
                            when 'operator' then 'Administrator' else 'System' end
           || ': ' || coalesce(h.text, ''), E'\n' order by h.id), '(no earlier messages)')
  from (select * from messages
        where conversation_id = p_conversation_id and id < p_before_id
        order by id desc limit p_limit) h
$$;

-- Take the conversation for one turn. Returns null if another execution holds the lease or
-- nothing is waiting; otherwise the whole turn context in one call. The lease outlives core.process
-- (executionTimeout 110 s) so a slow turn is not taken over while it still runs.
create function begin_turn(p_conversation_id uuid, p_owner text, p_ttl_sec int default 150)
returns jsonb language plpgsql as $$
declare
  v_conv     conversations;
  v_first    messages;
  v_kind     text;
  v_next     bigint;
  v_ids      bigint[];
  v_batch    jsonb;
  v_session  uuid;
  v_attempts int;
  v_text     text;
  v_client   clients;
  v_tenant   tenants;
  v_channel  text;
begin
  update conversations
  set lease_until = now() + make_interval(secs => p_ttl_sec), lease_owner = p_owner
  where id = p_conversation_id and (lease_until is null or lease_until < now())
  returning * into v_conv;
  if not found then
    return null;
  end if;

  select * into v_first from messages
  where conversation_id = p_conversation_id and direction = 'in' and processed_at is null
  order by id limit 1;
  if not found then
    update conversations set lease_until = null, lease_owner = null where id = p_conversation_id;
    return null;
  end if;

  -- a deterministic button is handled alone; consecutive texts are answered in one turn
  v_kind := case when is_action_callback(v_first.payload ->> 'callback') then 'action' else 'text' end;
  if v_kind = 'text' then
    select min(id) into v_next from messages
    where conversation_id = p_conversation_id and direction = 'in' and processed_at is null
      and id > v_first.id and is_action_callback(payload ->> 'callback');
  end if;

  with batch as (
    update messages m set process_attempts = m.process_attempts + 1
    where m.conversation_id = p_conversation_id and m.direction = 'in' and m.processed_at is null
      and (m.id = v_first.id or (v_kind = 'text' and m.id < coalesce(v_next, 9223372036854775807)))
    returning m.id, m.text, m.payload, m.session_id, m.process_attempts
  )
  select array_agg(id order by id),
         jsonb_agg(jsonb_build_object('id', id, 'text', text, 'callback', payload ->> 'callback') order by id),
         (array_agg(session_id order by id desc))[1],
         max(process_attempts),
         string_agg(coalesce(text, ''), E'\n' order by id)
  into v_ids, v_batch, v_session, v_attempts, v_text
  from batch;

  select * into v_tenant from tenants where id = v_conv.tenant_id;
  v_client := conversation_client(v_conv.id);
  select ca.channel into v_channel
  from client_identities ci join channel_accounts ca on ca.id = ci.channel_account_id
  where ci.id = v_conv.last_identity_id;

  -- nobody can pick the conversation up (no operator group, bot removed): the bot answers again
  if v_conv.state = 'operator' and not tenant_has_operator(v_conv.tenant_id) then
    update conversations set state = 'bot', awaiting_operator_since = null, sla_notified_at = null, not_understood_streak = 0
    where id = v_conv.id;
    update escalations set returned_at = now() where conversation_id = v_conv.id and returned_at is null;
    v_conv.state := 'bot';
    v_conv.not_understood_streak := 0;
  end if;

  -- a message that keeps crashing its turn is given up on instead of retried forever. An agent turn that did
  -- not finish (timeout, dead worker) is not run again: the LLM would be paid twice and its tools could act twice.
  if v_attempts > 3 or (v_kind = 'text' and v_conv.state = 'bot' and v_attempts > 1 and not is_urgent(v_text)) then
    v_kind := 'give_up';
  elsif v_kind = 'text' and v_conv.state = 'operator' then
    v_kind := 'operator';
  elsif v_kind = 'text' and is_urgent(v_text) then
    v_kind := 'urgent';
  end if;

  return jsonb_build_object(
    'owner', p_owner,
    'turn_started_at', now(),
    'kind', v_kind,
    'message_ids', to_jsonb(v_ids),
    'messages', v_batch,
    'input', v_text,
    'tenant_id', v_tenant.id,
    'tenant_slug', v_tenant.slug,
    'llm_profile', v_tenant.llm_profile,
    'models', coalesce(v_tenant.config -> 'models', '{}'),
    'conversation_id', v_conv.id,
    'state', v_conv.state,
    'not_understood_streak', v_conv.not_understood_streak,
    'session_id', v_session,
    'client_id', v_client.id,
    'lang', coalesce(detect_lang(v_text), v_client.lang, v_tenant.config ->> 'default_lang', 'en'),
    'channel', v_channel,
    'templates', jsonb_build_object(
      'urgent', t('urgent', coalesce(detect_lang(v_text), v_client.lang),
                  jsonb_build_object('phone', coalesce(v_tenant.config ->> 'emergency_phone', '112'))),
      'handoff', t('handoff', coalesce(detect_lang(v_text), v_client.lang)),
      'fallback', t('fallback', coalesce(detect_lang(v_text), v_client.lang)),
      -- given up while with the operator: the operator group is unreachable, send the client to the phone
      'give_up', case when v_conv.state = 'operator'
                      then t('no_operator', coalesce(detect_lang(v_text), v_client.lang),
                             jsonb_build_object('phones', clinic_phones(v_tenant.id)))
                      else t('fallback', coalesce(detect_lang(v_text), v_client.lang)) end),
    'attempts', v_attempts,
    'history', conversation_history(v_conv.id, v_first.id, 20),
    'clinic', tenant_prompt(v_tenant.id),
    'client', client_prompt(v_client.id, v_conv.id),
    'now_local', to_char(now() at time zone v_tenant.timezone, 'YYYY-MM-DD HH24:MI') || ', '
                 || (array['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'])
                    [extract(isodow from now() at time zone v_tenant.timezone)::int]);
end $$;

-- Close the turn: mark the batch processed, queue the reply (with buttons for changes proposed
-- during this turn), write the trace, release the lease. One transaction. p_release_operator hands
-- the conversation back to the bot (a turn given up because the operator group is unreachable).
create function finish_turn(
  p_conversation_id  uuid,
  p_owner            text,
  p_message_ids      bigint[],
  p_reply            text,
  p_understood       boolean,
  p_trace            jsonb,
  p_execution_id     text,
  p_turn_started_at  timestamptz,
  p_release_operator boolean default false
) returns jsonb language plpgsql as $$
declare
  v_conv    conversations;
  v_session uuid;
  v_lang    text;
  v_buttons jsonb;
  v_out     bigint;
  v_streak  int;
begin
  select * into v_conv from conversations where id = p_conversation_id for update;
  if v_conv.lease_owner is distinct from p_owner then
    -- lease expired and another execution took the batch over: drop this result
    return jsonb_build_object('stale', true);
  end if;

  update messages set processed_at = now()
  where conversation_id = p_conversation_id and id = any(p_message_ids) and processed_at is null;
  select session_id into v_session from messages
  where conversation_id = p_conversation_id and id = any(p_message_ids) order by id desc limit 1;
  if v_session is null then
    select s.id into v_session from sessions s where s.conversation_id = p_conversation_id
    order by s.started_at desc limit 1;
  end if;

  update conversations
  set not_understood_streak = case when p_understood is false then not_understood_streak + 1
                                   when p_understood then 0 else not_understood_streak end,
      lease_until = null, lease_owner = null, updated_at = now()
  where id = p_conversation_id
  returning not_understood_streak into v_streak;
  if p_release_operator and v_conv.state = 'operator' then
    update conversations set state = 'bot', awaiting_operator_since = null, sla_notified_at = null, not_understood_streak = 0
    where id = p_conversation_id;
    update escalations set returned_at = now() where conversation_id = p_conversation_id and returned_at is null;
    v_streak := 0;
  end if;

  if coalesce(p_reply, '') <> '' then
    select lang into v_lang from clients where id = v_conv.client_id;
    select jsonb_agg(jsonb_build_array(
             jsonb_build_object('text', t(case when pa.kind = 'cancel' then 'btn.cancel_yes' else 'btn.confirm' end, v_lang),
                                'data', 'pa:' || pa.id || ':y'),
             jsonb_build_object('text', t(case when pa.kind = 'cancel' then 'btn.cancel_no' else 'btn.reject' end, v_lang),
                                'data', 'pa:' || pa.id || ':n')) order by pa.created_at)
    into v_buttons
    from pending_actions pa
    where pa.conversation_id = p_conversation_id and pa.status = 'pending' and pa.created_at >= p_turn_started_at;

    v_out := enqueue_message(p_conversation_id, 'bot', p_reply,
                             case when v_buttons is not null then jsonb_build_object('buttons', v_buttons) else '{}' end,
                             v_session);
  end if;

  insert into trace_events (tenant_id, session_id, execution_id, type, data, duration_ms)
  select v_conv.tenant_id, v_session, p_execution_id, e ->> 'type', coalesce(e -> 'data', '{}'), (e ->> 'duration_ms')::int
  from jsonb_array_elements(coalesce(p_trace, '[]')) e
  where e ->> 'type' in ('decision', 'tool', 'error');

  return jsonb_build_object(
    'out_message_id', v_out,
    'streak', v_streak,
    'session_id', v_session,
    'more', exists (select 1 from messages
                    where conversation_id = p_conversation_id and direction = 'in' and processed_at is null));
end $$;

-- Operator mode: the batch was forwarded to the operator topic; mark it and release the lease.
create function finish_forward(p_conversation_id uuid, p_owner text, p_message_ids bigint[]) returns jsonb
language sql as $$
  select finish_turn(p_conversation_id, p_owner, p_message_ids, null, null,
                     '[{"type": "decision", "data": {"route": "operator"}}]', null, now())
$$;

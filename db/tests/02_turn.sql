-- begin_turn / finish_turn: lease, batching, routing, streak, stale results
do $$
declare
  r    jsonb;
  ctx  jsonb;
  ctx2 jsonb;
  fin  jsonb;
  conv uuid;
begin
  r := pg_temp.say('u1', 'Hi, how much is cleaning?');
  conv := (r ->> 'conversation_id')::uuid;
  perform pg_temp.say('u1', 'And do you work on Sunday?');

  ctx := begin_turn(conv, 'exec-1');
  assert ctx ->> 'kind' = 'text', ctx::text;
  assert jsonb_array_length(ctx -> 'message_ids') = 2, 'consecutive texts are answered in one turn';
  assert ctx ->> 'input' like '%cleaning?%Sunday?%';
  assert ctx ->> 'clinic' like '%cleaning: Cleaning, 1500 UAH, 60 min.%', ctx ->> 'clinic';
  assert ctx ->> 'clinic' like '%dr-a: Dr A%', ctx ->> 'clinic';
  assert ctx ->> 'client' like '%name Ivan, phone unknown%', ctx ->> 'client';
  assert ctx ->> 'llm_profile' = 'stub';
  assert begin_turn(conv, 'exec-2') is null, 'the lease blocks a second turn';

  fin := finish_turn(conv, 'exec-1', pg_temp.ids(ctx), 'Cleaning is 1500 UAH.', true,
                     '[{"type": "decision", "data": {"route": "agent"}}, {"type": "bogus"}]', 'exec-1',
                     (ctx ->> 'turn_started_at')::timestamptz);
  assert fin ->> 'out_message_id' is not null, fin::text;
  assert not (fin ->> 'more')::boolean;
  assert (select count(*) from messages where conversation_id = conv and direction = 'in' and processed_at is null) = 0;
  assert (select lease_owner from conversations where id = conv) is null, 'lease released';
  assert (select count(*) from trace_events where execution_id = 'exec-1' and type = 'decision') = 1, 'trace written, junk skipped';
  assert (select payload from messages where id = (fin ->> 'out_message_id')::bigint) = '{}', 'no buttons without proposals';
  assert begin_turn(conv, 'exec-3') is null, 'nothing left to do';
  assert conversation_history(conv, 9223372036854775807) like '%Client: Hi, how much%Assistant: Cleaning is 1500 UAH.%';

  -- a turn that outlives its lease: the next owner wins, the late result is dropped
  perform pg_temp.say('u1', 'one more');
  ctx := begin_turn(conv, 'exec-4');
  update conversations set lease_until = now() - interval '1 second' where id = conv;
  ctx2 := begin_turn(conv, 'exec-5');
  assert ctx2 is not null, 'an expired lease can be taken over';
  assert ctx2 ->> 'kind' = 'give_up' and ctx2 -> 'templates' ->> 'give_up' = ctx2 -> 'templates' ->> 'fallback',
    'an unfinished agent turn is not run (and paid for) again';
  fin := finish_turn(conv, 'exec-4', pg_temp.ids(ctx), 'late', true, '[]', 'exec-4', now());
  assert (fin ->> 'stale')::boolean, 'stale owner is ignored';
  fin := finish_turn(conv, 'exec-5', pg_temp.ids(ctx2), 'fresh', true, '[]', 'exec-5', now());
  assert (select count(*) from messages where conversation_id = conv and text in ('late', 'fresh')) = 1;

  -- not understood twice in a row
  perform pg_temp.say('u1', 'qwerty');
  ctx := begin_turn(conv, 'e6');
  fin := finish_turn(conv, 'e6', pg_temp.ids(ctx), 'Sorry?', false, '[]', 'e6', now());
  assert (fin ->> 'streak')::int = 1;
  perform pg_temp.say('u1', 'zxcv');
  ctx := begin_turn(conv, 'e7');
  assert (ctx ->> 'not_understood_streak')::int = 1;
  fin := finish_turn(conv, 'e7', pg_temp.ids(ctx), 'Sorry?', false, '[]', 'e7', now());
  assert (fin ->> 'streak')::int = 2;
  perform pg_temp.say('u1', 'ok, cleaning price');
  ctx := begin_turn(conv, 'e8');
  fin := finish_turn(conv, 'e8', pg_temp.ids(ctx), '1500', true, '[]', 'e8', now());
  assert (fin ->> 'streak')::int = 0, 'understood resets the streak';

  -- urgent symptoms are routed before the LLM (AC4)
  perform pg_temp.say('u1', 'У меня сильная боль и отёк щеки');
  ctx := begin_turn(conv, 'e9');
  assert ctx ->> 'kind' = 'urgent', ctx ->> 'kind';
  assert ctx ->> 'lang' = 'ru';
  assert ctx -> 'templates' ->> 'urgent' like '%+380440000000%', 'emergency phone from the clinic config';
  perform finish_turn(conv, 'e9', pg_temp.ids(ctx), ctx -> 'templates' ->> 'urgent', true, '[]', 'e9', now());

  -- a button is handled alone, before texts that came after it
  perform pg_temp.say('u1', null, 't1-bot', 'pa:' || gen_random_uuid() || ':y');
  perform pg_temp.say('u1', 'thanks');
  ctx := begin_turn(conv, 'e10');
  assert ctx ->> 'kind' = 'action' and jsonb_array_length(ctx -> 'message_ids') = 1, ctx::text;
  fin := finish_turn(conv, 'e10', pg_temp.ids(ctx), null, null, '[]', 'e10', now());
  assert (fin ->> 'more')::boolean, 'the text after the button is still waiting';
  ctx := begin_turn(conv, 'e11');
  assert ctx ->> 'kind' = 'text' and ctx ->> 'input' = 'thanks';
  perform finish_turn(conv, 'e11', pg_temp.ids(ctx), null, null, '[]', 'e11', now());

  -- a message that crashed three turns is given up on
  perform pg_temp.say('u1', 'poison');
  update messages set process_attempts = 3 where conversation_id = conv and processed_at is null;
  ctx := begin_turn(conv, 'e12');
  assert ctx ->> 'kind' = 'give_up', ctx ->> 'kind';
  perform finish_turn(conv, 'e12', pg_temp.ids(ctx), null, null, '[]', 'e12', now());

  -- while an operator has the conversation, texts go to the operator
  update conversations set state = 'operator' where id = conv;
  perform pg_temp.say('u1', 'hello operator');
  ctx := begin_turn(conv, 'e13');
  assert ctx ->> 'kind' = 'operator';
  fin := finish_forward(conv, 'e13', pg_temp.ids(ctx));
  assert fin ->> 'out_message_id' is null and not (fin ->> 'more')::boolean;

  -- the operator group stays unreachable: the client is sent to the phone and the bot takes over again
  perform pg_temp.say('u1', 'are you there?');
  update messages set process_attempts = 3 where conversation_id = conv and processed_at is null;
  ctx := begin_turn(conv, 'e14');
  assert ctx ->> 'kind' = 'give_up' and ctx ->> 'state' = 'operator', ctx::text;
  assert ctx -> 'templates' ->> 'give_up' like 'Our administrators cannot answer%+380440000000%', ctx -> 'templates' ->> 'give_up';
  update conversations set not_understood_streak = 2 where id = conv;
  fin := finish_turn(conv, 'e14', pg_temp.ids(ctx), ctx -> 'templates' ->> 'give_up', null, '[]', 'e14', now(), true);
  assert (select state from conversations where id = conv) = 'bot', 'released to the bot';
  assert (fin ->> 'streak')::int = 0, 'a released conversation starts over (no escalation into the broken group)';

  -- no operator group (or no bot to reach it): a conversation left with the operator comes back to the bot
  update conversations set state = 'operator' where id = conv;
  update channel_accounts set active = false where external_id = 't1-bot';
  perform pg_temp.say('u1', 'hello?');
  ctx := begin_turn(conv, 'e15');
  assert ctx ->> 'kind' = 'text' and ctx ->> 'state' = 'bot', ctx::text;
  assert (select state from conversations where id = conv) = 'bot';
  perform finish_turn(conv, 'e15', pg_temp.ids(ctx), null, null, '[]', 'e15', now());
  update channel_accounts set active = true where external_id = 't1-bot';
end $$;

do $$
begin
  assert is_urgent('У меня сильная боль и отёк');
  assert is_urgent('Сильно болит зуб, не могу спать');
  assert is_urgent('У мене сильний біль і набряк');
  assert is_urgent('severe pain and my cheek is swollen');
  assert is_urgent('My gum is bleeding a lot');
  assert is_urgent('I knocked out a tooth playing football');
  assert is_urgent('кровотеча після видалення');
  assert not is_urgent('How much is cleaning?');
  assert not is_urgent('Сколько стоит чистка?');
  assert not is_urgent('Скільки коштує пломба?');
  assert not is_urgent('my teeth are sensitive to cold');
  assert not is_urgent('не игнорируйте меня пожалуйста');
  assert not is_urgent('мені сильно більше подобається центр');
  assert not is_urgent('мне сильно больше нравится центр');
  -- reported symptoms, verb forms, "very" instead of "severe"
  assert is_urgent('очень болит зуб, не могу спать');
  assert is_urgent('дуже болить зуб');
  assert is_urgent('кровоточат десны');
  assert is_urgent('Щека опухла, что делать?');
  assert is_urgent('My face is swollen after the extraction, is it normal?');
  assert is_urgent('У сина набрякла щока, що робити?');
  assert is_urgent('Не проходит отёк уже три дня');
  -- general questions go to the agent, negated symptoms do not count
  assert not is_urgent('How long does swelling usually last after a wisdom tooth removal?');
  assert not is_urgent('Do you treat bleeding gums?');
  assert not is_urgent('у вас есть травматолог?');
  assert not is_urgent('чи буде набряк після видалення?');
  assert not is_urgent('Is swelling normal after an implant?');
  assert not is_urgent('Здравствуйте, сколько держится отёк после удаления');
  assert not is_urgent('No swelling and no pain, just want a cleaning');
  assert not is_urgent('Зуб не болит, хочу чистку');
  assert not is_urgent('У мене болить зуб, коли п''ю холодне. Це карієс?');
end $$;

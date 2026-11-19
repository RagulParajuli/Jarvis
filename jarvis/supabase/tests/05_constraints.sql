-- Uniqueness, normalisation and idempotency of the constraints that keep data sane.

begin;

select jarvis_test.reset_data();

insert into jarvis.users (id, display_name)
values ('00000000-0000-7000-8000-00000000000a', 'Owner');

insert into jarvis.devices (id, user_id, label, platform, status, paired_at) values
    ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
     'Phone', 'android', 'trusted', now());

insert into jarvis.conversations (id, user_id, device_id) values
    ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
     '00000000-0000-7000-8000-0000000000d1');

-- ── Memory content hashing ────────────────────────────────────────────────
insert into jarvis.memories (id, user_id, content)
values ('00000000-0000-7000-8000-0000000000e1',
        '00000000-0000-7000-8000-00000000000a', '  Likes Tea  ');

select jarvis_test.ok(
    (select content_hash from jarvis.memories where id = '00000000-0000-7000-8000-0000000000e1')
        ~ '^[0-9a-f]{64}$',
    'the memory hash is 64 lowercase hexadecimal characters');

select jarvis_test.ok(
    (select content_hash from jarvis.memories where id = '00000000-0000-7000-8000-0000000000e1')
        = encode(extensions.digest(lower(btrim('  Likes Tea  ')), 'sha256'), 'hex'),
    'the hash is derived from the trimmed, lowercased content');

-- Case and surrounding whitespace do not create a second active memory.
select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content)
      values ('00000000-0000-7000-8000-00000000000a', 'likes tea')$$,
    '23505',
    'the same fact cannot be stored twice while it is active');

-- Once forgotten, the fact can be remembered again.
select jarvis.delete_memory('00000000-0000-7000-8000-0000000000e1',
                            '00000000-0000-7000-8000-00000000000a', false);
insert into jarvis.memories (user_id, content)
values ('00000000-0000-7000-8000-00000000000a', 'likes tea');
select jarvis_test.ok(
    (select count(*) from jarvis.memories where status = 'active') = 1,
    'a soft deleted fact may be remembered again');

-- Different facts do not collide.
insert into jarvis.memories (user_id, content)
values ('00000000-0000-7000-8000-00000000000a', 'likes coffee');
select jarvis_test.ok(
    (select content_hash from jarvis.memories where content = 'likes coffee')
        <> (select content_hash from jarvis.memories where content = 'likes tea'),
    'different facts keep different hashes');

-- ── Memory invariants ─────────────────────────────────────────────────────
select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content)
      values ('00000000-0000-7000-8000-00000000000a', '   ')$$,
    '23514',
    'an empty memory is rejected');

select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content)
      values ('00000000-0000-7000-8000-00000000000a', repeat('x', 2001))$$,
    '23514',
    'an oversized memory is rejected');

select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content, category)
      values ('00000000-0000-7000-8000-00000000000a', 'a fact', 'secrets')$$,
    '23514',
    'an unknown memory category is rejected');

select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content, status)
      values ('00000000-0000-7000-8000-00000000000a', 'a deleted fact', 'deleted')$$,
    '23514',
    'a deleted memory must carry deleted_at');

select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content, deleted_at)
      values ('00000000-0000-7000-8000-00000000000a', 'a live fact', now())$$,
    '23514',
    'an active memory cannot carry deleted_at');

-- ── Device and credential invariants ──────────────────────────────────────
select jarvis_test.fails(
    $$insert into jarvis.devices (user_id, label, platform, status)
      values ('00000000-0000-7000-8000-00000000000a', 'Ghost', 'android', 'revoked')$$,
    '23514',
    'a revoked device must carry revoked_at');

select jarvis_test.fails(
    $$insert into jarvis.devices (user_id, label, platform)
      values ('00000000-0000-7000-8000-00000000000a', 'Watch', 'symbian')$$,
    '23514',
    'an unknown platform is rejected');

insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
values ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
        repeat('1', 64), repeat('K', 64));

select jarvis_test.fails(
    $$insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
      values ('00000000-0000-7000-8000-0000000000d1',
              '00000000-0000-7000-8000-00000000000a',
              'not-a-fingerprint', repeat('K', 64))$$,
    '23514',
    'a key fingerprint must be a SHA-256 hex digest');

select jarvis_test.fails(
    $$insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
      values ('00000000-0000-7000-8000-0000000000d1',
              '00000000-0000-7000-8000-00000000000a',
              repeat('2', 64), repeat('K', 64))$$,
    '23505',
    'a device cannot hold two active credentials');

select jarvis_test.fails(
    $$insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
      values ('00000000-0000-7000-8000-0000000000d1',
              '00000000-0000-7000-8000-00000000000a',
              repeat('1', 64), repeat('K', 64))$$,
    '23505',
    'the same public key cannot be enrolled twice');

-- Rotation: retire the old key, then enrol the new one.
update jarvis.device_credentials
   set retired_at = now()
 where device_id = '00000000-0000-7000-8000-0000000000d1';

insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
values ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
        repeat('2', 64), repeat('K', 64));

select jarvis_test.ok(
    (select count(*) from jarvis.device_credentials
      where device_id = '00000000-0000-7000-8000-0000000000d1' and retired_at is null) = 1,
    'a rotated device has exactly one active credential');

-- ── Pairing codes ─────────────────────────────────────────────────────────
insert into jarvis.pairing_codes (user_id, code_hash, expires_at)
values ('00000000-0000-7000-8000-00000000000a', repeat('c', 64), now() + interval '10 minutes');

select jarvis_test.fails(
    $$insert into jarvis.pairing_codes (user_id, code_hash, expires_at)
      values ('00000000-0000-7000-8000-00000000000a', repeat('c', 64),
              now() + interval '10 minutes')$$,
    '23505',
    'a pairing code hash cannot be reused');

select jarvis_test.fails(
    $$insert into jarvis.pairing_codes (user_id, code_hash, expires_at)
      values ('00000000-0000-7000-8000-00000000000a', repeat('d', 64),
              now() - interval '1 minute')$$,
    '23514',
    'a pairing code cannot expire before it exists');

-- ── Conversations, messages, summaries ────────────────────────────────────
insert into jarvis.conversations (id, user_id, livekit_room_name)
values ('00000000-0000-7000-8000-0000000000c3',
        '00000000-0000-7000-8000-00000000000a', 'jarvis_shared_room');

select jarvis_test.fails(
    $$insert into jarvis.conversations (user_id, livekit_room_name)
      values ('00000000-0000-7000-8000-00000000000a', 'jarvis_shared_room')$$,
    '23505',
    'two conversations cannot share a room name');

insert into jarvis.messages (conversation_id, user_id, seq, role, content, agent_item_id, occurred_at)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        1, 'user', 'hello', 'item_1', now());

select jarvis_test.fails(
    $$insert into jarvis.messages (conversation_id, user_id, seq, role, agent_item_id, occurred_at)
      values ('00000000-0000-7000-8000-0000000000c1',
              '00000000-0000-7000-8000-00000000000a', 2, 'assistant', 'item_1', now())$$,
    '23505',
    'a retried agent item cannot be written twice');

-- The idempotent form leaves the duplicate out instead of failing the batch.
insert into jarvis.messages (conversation_id, user_id, seq, role, agent_item_id, occurred_at)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        2, 'assistant', 'item_1', now())
on conflict (conversation_id, agent_item_id) where agent_item_id is not null do nothing;

select jarvis_test.ok(
    (select count(*) from jarvis.messages) = 1,
    'a deduplicated retry leaves exactly one message');

select jarvis_test.fails(
    $$insert into jarvis.messages (conversation_id, user_id, seq, role, occurred_at)
      values ('00000000-0000-7000-8000-0000000000c1',
              '00000000-0000-7000-8000-00000000000a', 3, 'robot', now())$$,
    '23514',
    'an unknown message role is rejected');

insert into jarvis.conversation_summaries
      (conversation_id, user_id, summary, covers_from_seq, covers_to_seq)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        'a greeting', 1, 1);

select jarvis_test.fails(
    $$insert into jarvis.conversation_summaries
          (conversation_id, user_id, summary, covers_from_seq, covers_to_seq)
      values ('00000000-0000-7000-8000-0000000000c1',
              '00000000-0000-7000-8000-00000000000a', 'the same range', 1, 1)$$,
    '23505',
    'the same summary range cannot be written twice');

select jarvis_test.fails(
    $$insert into jarvis.conversation_summaries
          (conversation_id, user_id, summary, covers_from_seq, covers_to_seq)
      values ('00000000-0000-7000-8000-0000000000c1',
              '00000000-0000-7000-8000-00000000000a', 'backwards', 5, 2)$$,
    '23514',
    'a summary range must be ordered');

rollback;

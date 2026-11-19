-- Composite ownership: a row can only reference data belonging to its own user.

begin;

select jarvis_test.disable_single_user_guard();
select jarvis_test.reset_data();

insert into jarvis.users (id, display_name) values
    ('00000000-0000-7000-8000-00000000000a', 'Owner A'),
    ('00000000-0000-7000-8000-00000000000b', 'Owner B');

insert into jarvis.devices (id, user_id, label, platform, status, paired_at) values
    ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
     'Phone A', 'android', 'trusted', now()),
    ('00000000-0000-7000-8000-0000000000d2', '00000000-0000-7000-8000-00000000000b',
     'Phone B', 'android', 'trusted', now());

-- Every conversation owned by B.
insert into jarvis.conversations (id, user_id, device_id) values
    ('00000000-0000-7000-8000-0000000000c2', '00000000-0000-7000-8000-00000000000b',
     '00000000-0000-7000-8000-0000000000d2');

-- B's message, used to prove memory provenance cannot cross accounts.
insert into jarvis.messages (conversation_id, user_id, device_id, seq, role, content, occurred_at)
values ('00000000-0000-7000-8000-0000000000c2', '00000000-0000-7000-8000-00000000000b',
        '00000000-0000-7000-8000-0000000000d2', 1, 'user', 'belongs to B', now());

-- A credential cannot attach another account's device.
select jarvis_test.fails(
    $$insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
      values ('00000000-0000-7000-8000-0000000000d1',
              '00000000-0000-7000-8000-00000000000b',
              repeat('a', 64), repeat('P', 64))$$,
    '23503',
    'a device credential cannot point at another account''s device');

-- A conversation cannot use another account's device.
select jarvis_test.fails(
    $$insert into jarvis.conversations (user_id, device_id)
      values ('00000000-0000-7000-8000-00000000000b',
              '00000000-0000-7000-8000-0000000000d1')$$,
    '23503',
    'a conversation cannot use another account''s device');

-- A conversation cannot be attributed to someone else's device at all.
select jarvis_test.fails(
    $$insert into jarvis.conversations (user_id, device_id)
      values ('00000000-0000-7000-8000-00000000000a',
              '00000000-0000-7000-8000-0000000000d2')$$,
    '23503',
    'ownership is checked in both directions');

-- A message cannot mix a conversation and a user from different accounts.
select jarvis_test.fails(
    $$insert into jarvis.messages (conversation_id, user_id, seq, role, occurred_at)
      values ('00000000-0000-7000-8000-0000000000c2',
              '00000000-0000-7000-8000-00000000000a',
              2, 'user', now())$$,
    '23503',
    'a message cannot mix conversation and user owners');

-- A message cannot borrow another account's device while using its own conversation.
select jarvis_test.fails(
    $$insert into jarvis.messages (conversation_id, user_id, device_id, seq, role, occurred_at)
      values ('00000000-0000-7000-8000-0000000000c2',
              '00000000-0000-7000-8000-00000000000b',
              '00000000-0000-7000-8000-0000000000d1',
              2, 'user', now())$$,
    '23503',
    'a message cannot cite another account''s device');

-- A summary cannot be attached to another account's conversation.
select jarvis_test.fails(
    $$insert into jarvis.conversation_summaries
          (conversation_id, user_id, summary, covers_from_seq, covers_to_seq)
      values ('00000000-0000-7000-8000-0000000000c2',
              '00000000-0000-7000-8000-00000000000a',
              'stolen summary', 1, 1)$$,
    '23503',
    'a summary cannot point at another account''s conversation');

-- A memory cannot cite another account's conversation.
select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content, source_conversation_id)
      values ('00000000-0000-7000-8000-00000000000a',
              'prefers tea',
              '00000000-0000-7000-8000-0000000000c2')$$,
    '23503',
    'a memory cannot point at another account''s conversation');

-- ... nor another account's message.
select jarvis_test.fails(
    $$insert into jarvis.memories (user_id, content, source_message_id)
      values ('00000000-0000-7000-8000-00000000000a',
              'prefers coffee',
              (select id from jarvis.messages
                where conversation_id = '00000000-0000-7000-8000-0000000000c2'
                limit 1))$$,
    '23503',
    'a memory cannot point at another account''s message');

-- The same rows, correctly owned, are accepted.
insert into jarvis.conversations (id, user_id, device_id) values
    ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
     '00000000-0000-7000-8000-0000000000d1');

insert into jarvis.messages (conversation_id, user_id, device_id, seq, role, content, occurred_at)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        '00000000-0000-7000-8000-0000000000d1', 1, 'user', 'belongs to A', now());

insert into jarvis.conversation_summaries
      (conversation_id, user_id, summary, covers_from_seq, covers_to_seq)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        'one turn', 1, 1);

insert into jarvis.memories (user_id, content, source_conversation_id, source_message_id)
values ('00000000-0000-7000-8000-00000000000a', 'prefers green tea',
        '00000000-0000-7000-8000-0000000000c1',
        (select id from jarvis.messages
          where conversation_id = '00000000-0000-7000-8000-0000000000c1' limit 1));

select jarvis_test.ok(
    (select count(*) from jarvis.messages
      where conversation_id = '00000000-0000-7000-8000-0000000000c1') = 1,
    'correctly owned rows are accepted');
select jarvis_test.ok(
    (select source_conversation_id from jarvis.memories
      where content = 'prefers green tea') = '00000000-0000-7000-8000-0000000000c1',
    'a memory may cite its own conversation');

-- A pairing code belongs to its account all the way through consumption.
select jarvis_test.fails(
    $$insert into jarvis.pairing_codes
          (user_id, code_hash, expires_at, consumed_by_device_id)
      values ('00000000-0000-7000-8000-00000000000a',
              repeat('b', 64), now() + interval '10 minutes',
              '00000000-0000-7000-8000-0000000000d2')$$,
    '23503',
    'a pairing code cannot be created already consumed by another account''s device');

insert into jarvis.pairing_codes (id, user_id, code_hash, expires_at)
values ('00000000-0000-7000-8000-0000000000e1',
        '00000000-0000-7000-8000-00000000000a',
        repeat('c', 64), now() + interval '10 minutes');

select jarvis_test.fails(
    $$update jarvis.pairing_codes
         set consumed_by_device_id = '00000000-0000-7000-8000-0000000000d2'
       where id = '00000000-0000-7000-8000-0000000000e1'$$,
    '23503',
    'a pairing code cannot be consumed by another account''s device');

-- The same account's device is accepted, so the rejection above is about
-- ownership rather than about consumption being impossible.
update jarvis.pairing_codes
   set used_at = now(),
       consumed_by_device_id = '00000000-0000-7000-8000-0000000000d1'
 where id = '00000000-0000-7000-8000-0000000000e1';

select jarvis_test.ok(
    (select consumed_by_device_id from jarvis.pairing_codes
      where id = '00000000-0000-7000-8000-0000000000e1') = '00000000-0000-7000-8000-0000000000d1',
    'a pairing code may be consumed by its own account''s device');

-- Consuming it first is what makes this check meaningful: with a null device the
-- composite key is not checked (MATCH SIMPLE), exactly as intended.
select jarvis_test.fails(
    $$update jarvis.pairing_codes
         set user_id = '00000000-0000-7000-8000-00000000000b'
       where id = '00000000-0000-7000-8000-0000000000e1'$$,
    '23503',
    'a consumed pairing code cannot be reassigned to another account');

rollback;

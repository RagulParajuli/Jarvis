-- Deletion behaviour: what is removed, what survives, and in what state.

begin;

select jarvis_test.reset_data();

insert into jarvis.users (id, display_name)
values ('00000000-0000-7000-8000-00000000000a', 'Owner');

insert into jarvis.devices (id, user_id, label, platform, status, paired_at) values
    ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
     'Phone', 'android', 'trusted', now());

insert into jarvis.device_credentials (device_id, user_id, key_fingerprint, public_key)
values ('00000000-0000-7000-8000-0000000000d1', '00000000-0000-7000-8000-00000000000a',
        repeat('a', 64), repeat('P', 64));

insert into jarvis.pairing_codes (user_id, code_hash, expires_at, used_at, consumed_by_device_id)
values ('00000000-0000-7000-8000-00000000000a', repeat('b', 64),
        now() + interval '10 minutes', now(), '00000000-0000-7000-8000-0000000000d1');

insert into jarvis.conversations (id, user_id, device_id) values
    ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
     '00000000-0000-7000-8000-0000000000d1');

insert into jarvis.messages (conversation_id, user_id, device_id, seq, role, content, occurred_at)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        '00000000-0000-7000-8000-0000000000d1', 1, 'user', 'hello', now()),
       ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        '00000000-0000-7000-8000-0000000000d1', 2, 'assistant', 'hi', now());

insert into jarvis.conversation_summaries
      (conversation_id, user_id, summary, covers_from_seq, covers_to_seq)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        'a greeting', 1, 2);

insert into jarvis.memories (id, user_id, content, source_conversation_id, source_message_id)
values ('00000000-0000-7000-8000-0000000000e1', '00000000-0000-7000-8000-00000000000a',
        'prefers tea',
        '00000000-0000-7000-8000-0000000000c1',
        (select id from jarvis.messages
          where conversation_id = '00000000-0000-7000-8000-0000000000c1' order by seq limit 1));

-- Deleting a conversation removes its turns and summaries, never the memory.
delete from jarvis.conversations where id = '00000000-0000-7000-8000-0000000000c1';

select jarvis_test.ok(
    (select count(*) from jarvis.messages
      where conversation_id = '00000000-0000-7000-8000-0000000000c1') = 0,
    'deleting a conversation removes its messages');
select jarvis_test.ok(
    (select count(*) from jarvis.conversation_summaries
      where conversation_id = '00000000-0000-7000-8000-0000000000c1') = 0,
    'deleting a conversation removes its summaries');
select jarvis_test.ok(
    (select count(*) from jarvis.memories) = 1,
    'a memory outlives the conversation it came from');
select jarvis_test.ok(
    (select source_conversation_id is null and source_message_id is null
       from jarvis.memories where id = '00000000-0000-7000-8000-0000000000e1'),
    'provenance is cleared instead of pointing at deleted rows');

-- Deleting a device keeps history and simply detaches it.
insert into jarvis.conversations (id, user_id, device_id) values
    ('00000000-0000-7000-8000-0000000000c2', '00000000-0000-7000-8000-00000000000a',
     '00000000-0000-7000-8000-0000000000d1');

insert into jarvis.messages (conversation_id, user_id, device_id, seq, role, content, occurred_at)
values ('00000000-0000-7000-8000-0000000000c2', '00000000-0000-7000-8000-00000000000a',
        '00000000-0000-7000-8000-0000000000d1', 1, 'user', 'still here', now());

delete from jarvis.devices where id = '00000000-0000-7000-8000-0000000000d1';

select jarvis_test.ok(
    (select device_id from jarvis.conversations
      where id = '00000000-0000-7000-8000-0000000000c2') is null,
    'deleting a device detaches the conversation');
select jarvis_test.ok(
    (select count(*) from jarvis.messages
      where conversation_id = '00000000-0000-7000-8000-0000000000c2') = 1,
    'deleting a device never deletes messages');
select jarvis_test.ok(
    (select device_id from jarvis.messages
      where conversation_id = '00000000-0000-7000-8000-0000000000c2') is null,
    'deleting a device detaches messages');
select jarvis_test.ok(
    (select count(*) from jarvis.device_credentials) = 0,
    'deleting a device removes its credentials');
select jarvis_test.ok(
    (select count(*) from jarvis.pairing_codes) = 1,
    'deleting a device does not remove pairing history');
select jarvis_test.ok(
    (select consumed_by_device_id from jarvis.pairing_codes
      where code_hash = repeat('b', 64)) is null,
    'deleting a device clears the pairing code consumption marker');
select jarvis_test.ok(
    (select user_id from jarvis.pairing_codes
      where code_hash = repeat('b', 64)) = '00000000-0000-7000-8000-00000000000a',
    'a pairing code stays with its account after the device is deleted');

-- Soft deletion is reversible and idempotent.
select jarvis_test.ok(
    jarvis.delete_memory('00000000-0000-7000-8000-0000000000e1',
                         '00000000-0000-7000-8000-00000000000a', false),
    'a soft delete reports that it changed something');
select jarvis_test.ok(
    (select status = 'deleted' and deleted_at is not null
       from jarvis.memories where id = '00000000-0000-7000-8000-0000000000e1'),
    'a soft delete marks the row and stamps deleted_at');
select jarvis_test.ok(
    not jarvis.delete_memory('00000000-0000-7000-8000-0000000000e1',
                             '00000000-0000-7000-8000-00000000000a', false),
    'deleting an already deleted memory reports no change');
select jarvis_test.ok(
    not jarvis.delete_memory('00000000-0000-7000-8000-0000000000e1',
                             '00000000-0000-7000-8000-0000000000ff', true),
    'deletion is scoped to the owning account');

-- The purge respects the undo window.
select jarvis_test.ok(
    jarvis.purge_deleted_memories(interval '30 days') = 0,
    'a freshly deleted memory survives the purge window');
update jarvis.memories
   set deleted_at = now() - interval '40 days'
 where id = '00000000-0000-7000-8000-0000000000e1';
select jarvis_test.ok(
    jarvis.purge_deleted_memories(interval '30 days') = 1,
    'a memory deleted longer ago than the window is removed');
select jarvis_test.ok(
    (select count(*) from jarvis.memories) = 0,
    'the purged row is gone');

-- Permanent deletion is immediate and needs no purge.
insert into jarvis.memories (id, user_id, content)
values ('00000000-0000-7000-8000-0000000000e2',
        '00000000-0000-7000-8000-00000000000a', 'a fact to forget now');

select jarvis_test.ok(
    jarvis.delete_memory('00000000-0000-7000-8000-0000000000e2',
                         '00000000-0000-7000-8000-00000000000a', true),
    'a permanent delete reports that it changed something');
select jarvis_test.ok(
    (select count(*) from jarvis.memories
      where id = '00000000-0000-7000-8000-0000000000e2') = 0,
    'a permanent delete leaves no soft-deleted row behind');
select jarvis_test.ok(
    (select count(*) from jarvis.memories where status = 'deleted') = 0,
    'a permanent delete never passes through the deleted state');

select jarvis_test.fails(
    $$select jarvis.purge_deleted_memories(interval '-1 day')$$,
    'P0001',
    'a negative purge window is rejected');

-- Deleting the account removes everything that belongs to it.
delete from jarvis.users where id = '00000000-0000-7000-8000-00000000000a';

select jarvis_test.ok((select count(*) from jarvis.users) = 0, 'the account row is gone');
select jarvis_test.ok((select count(*) from jarvis.devices) = 0, 'devices are gone');
select jarvis_test.ok((select count(*) from jarvis.device_credentials) = 0, 'credentials are gone');
select jarvis_test.ok((select count(*) from jarvis.pairing_codes) = 0, 'pairing codes are gone');
select jarvis_test.ok((select count(*) from jarvis.conversations) = 0, 'conversations are gone');
select jarvis_test.ok((select count(*) from jarvis.messages) = 0, 'messages are gone');
select jarvis_test.ok((select count(*) from jarvis.conversation_summaries) = 0, 'summaries are gone');
select jarvis_test.ok((select count(*) from jarvis.memories) = 0, 'memories are gone');

rollback;

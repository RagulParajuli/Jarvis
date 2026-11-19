-- Message sequence allocation: ordering, ownership, uniqueness, concurrency.
--
-- This file commits its setup on purpose: the concurrency check needs sessions
-- that can actually see the conversation row.
--
-- Every wait in this file is bounded. The concurrency block deliberately holds a
-- row lock, so an unbounded statement would turn a broken assumption into a hung
-- suite instead of a failed test.

-- Ceiling for the whole file, on top of the per-connection limits set below.
set statement_timeout = '60s';
set lock_timeout = '15s';

create extension if not exists dblink;

select jarvis_test.reset_data();

insert into jarvis.users (id, display_name)
values ('00000000-0000-7000-8000-00000000000a', 'Owner');

insert into jarvis.conversations (id, user_id) values
    ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a'),
    ('00000000-0000-7000-8000-0000000000c2', '00000000-0000-7000-8000-00000000000a');

-- Sequential allocation starts at one and counts per conversation.
select jarvis_test.ok(
    jarvis.allocate_message_seq('00000000-0000-7000-8000-0000000000c1',
                                '00000000-0000-7000-8000-00000000000a') = 1,
    'the first allocation is 1');
select jarvis_test.ok(
    jarvis.allocate_message_seq('00000000-0000-7000-8000-0000000000c1',
                                '00000000-0000-7000-8000-00000000000a') = 2,
    'the second allocation is 2');
select jarvis_test.ok(
    jarvis.allocate_message_seq('00000000-0000-7000-8000-0000000000c2',
                                '00000000-0000-7000-8000-00000000000a') = 1,
    'each conversation has its own sequence');

-- Ownership and existence are both enforced by the allocator.
select jarvis_test.ok(
    jarvis.allocate_message_seq('00000000-0000-7000-8000-0000000000c1',
                                '00000000-0000-7000-8000-0000000000ff') is null,
    'allocation for the wrong owner returns null');
select jarvis_test.ok(
    jarvis.allocate_message_seq('00000000-0000-7000-8000-0000000000ff',
                                '00000000-0000-7000-8000-00000000000a') is null,
    'allocation for an unknown conversation returns null');
select jarvis_test.ok(
    (select next_seq from jarvis.conversations
      where id = '00000000-0000-7000-8000-0000000000c1') = 2,
    'a refused allocation does not consume a number');

-- Concurrency: two sessions overlap, one holds the row lock, both must get a
-- different number. dblink keeps this dependency-free (no Node client needed).
--
-- Ordering is not left to the scheduler. Session A allocates synchronously and
-- keeps its transaction open, so the row lock is provably held before B is asked
-- anything. B is then sent asynchronously and can only finish once A commits.
do $concurrency$
declare
    connection_string text := format('port=%s dbname=%s user=%s',
        current_setting('port'), current_database(), current_user);
    allocate_c1 text := $$select jarvis.allocate_message_seq(
        '00000000-0000-7000-8000-0000000000c1',
        '00000000-0000-7000-8000-00000000000a')$$;
    seq_a bigint;
    seq_b bigint;
    drained bigint;
begin
    perform dblink_connect('seq_a', connection_string);
    perform dblink_connect('seq_b', connection_string);

    -- Bounded waits on both remote sessions. A wrong assumption fails the test;
    -- it must never sit on a lock forever.
    perform dblink_exec('seq_a', $$set statement_timeout = '15s'$$);
    perform dblink_exec('seq_a', $$set lock_timeout = '10s'$$);
    perform dblink_exec('seq_a', $$set idle_in_transaction_session_timeout = '20s'$$);
    perform dblink_exec('seq_b', $$set statement_timeout = '15s'$$);
    perform dblink_exec('seq_b', $$set lock_timeout = '10s'$$);
    perform dblink_exec('seq_b', $$set idle_in_transaction_session_timeout = '20s'$$);

    -- A takes the conversation row lock by allocating, and stays in transaction.
    perform dblink_exec('seq_a', 'begin');
    select result.seq into seq_a
      from dblink('seq_a', allocate_c1) as result(seq bigint);

    -- B asks for a number while A still holds the lock. dblink_send_query is
    -- asynchronous, so this returns without waiting for B.
    perform dblink_exec('seq_b', 'begin');
    perform dblink_send_query('seq_b', allocate_c1);

    -- Releasing A's lock is the only thing that lets B finish.
    perform dblink_exec('seq_a', 'commit');

    loop
        select result.seq into drained
          from dblink_get_result('seq_b') as result(seq bigint);
        exit when not found;
        seq_b := drained;
    end loop;
    perform dblink_exec('seq_b', 'commit');

    perform dblink_disconnect('seq_a');
    perform dblink_disconnect('seq_b');

    -- Unordered pair: both allocations must be the next two numbers, whichever
    -- session the scheduler ran first. Distinctness is what the allocator owes.
    perform jarvis_test.ok(
        seq_a is not null
          and seq_b is not null
          and seq_a <> seq_b
          and least(seq_a, seq_b) = 3
          and greatest(seq_a, seq_b) = 4,
        format('concurrent allocations take the next two numbers, in some order (got %s and %s)',
               seq_a, seq_b));
    perform jarvis_test.ok(seq_a <> seq_b, 'concurrent allocations never share a number');
end;
$concurrency$;

select jarvis_test.ok(
    (select next_seq from jarvis.conversations
      where id = '00000000-0000-7000-8000-0000000000c1') = 4,
    'the counter reflects every allocation');

-- The unique constraint is the backstop if the allocator is ever bypassed.
insert into jarvis.messages (conversation_id, user_id, seq, role, content, occurred_at)
values ('00000000-0000-7000-8000-0000000000c1', '00000000-0000-7000-8000-00000000000a',
        1, 'user', 'first', now());

select jarvis_test.fails(
    $$insert into jarvis.messages (conversation_id, user_id, seq, role, occurred_at)
      values ('00000000-0000-7000-8000-0000000000c1',
              '00000000-0000-7000-8000-00000000000a', 1, 'assistant', now())$$,
    '23505',
    'two messages cannot occupy the same position');

select jarvis_test.fails(
    $$insert into jarvis.messages (conversation_id, user_id, seq, role, occurred_at)
      values ('00000000-0000-7000-8000-0000000000c1',
              '00000000-0000-7000-8000-00000000000a', 0, 'user', now())$$,
    '23514',
    'a message position must be positive');

select jarvis_test.ok(
    (select count(*) from jarvis.messages
      where conversation_id = '00000000-0000-7000-8000-0000000000c1') = 1,
    'only the accepted message was written');

-- 20261118120200 — Conversations, messages and range summaries.
--
-- Ownership is proven by composite foreign keys: a message can only reference a
-- conversation that belongs to the same user, and a conversation or message can
-- only reference a device that belongs to that user. Deleting a device therefore
-- nulls `device_id` and never touches history.

begin;

create table jarvis.conversations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references jarvis.users (id) on delete cascade,
    device_id uuid,
    livekit_room_name text,
    title text,
    next_seq bigint not null default 0,
    started_at timestamptz not null default now(),
    last_activity_at timestamptz not null default now(),
    ended_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint conversations_room_name_length
        check (livekit_room_name is null or char_length(livekit_room_name) between 1 and 128),
    constraint conversations_title_length
        check (title is null or char_length(title) between 1 and 200),
    constraint conversations_next_seq_non_negative
        check (next_seq >= 0),
    constraint conversations_timeline_order
        check (ended_at is null or ended_at >= started_at),

    -- Ownership anchors for messages, summaries and memories.
    constraint conversations_id_user_unique unique (id, user_id),

    constraint conversations_device_ownership
        foreign key (device_id, user_id) references jarvis.devices (id, user_id)
        on delete set null (device_id)
);

comment on table jarvis.conversations is
    'One voice or text session. Owns its messages and summaries; deleting it removes both.';
comment on column jarvis.conversations.next_seq is
    'Highest message sequence already handed out. Only jarvis.allocate_message_seq() may change it.';
comment on column jarvis.conversations.device_id is
    'Device that started the session. Set to null when the device is deleted; the conversation stays.';

create index conversations_recent_idx
    on jarvis.conversations (user_id, last_activity_at desc);

create unique index conversations_room_name_idx
    on jarvis.conversations (livekit_room_name)
    where livekit_room_name is not null;

create trigger conversations_set_updated_at
    before update on jarvis.conversations
    for each row execute function jarvis.set_updated_at();

create table jarvis.messages (
    id bigint generated always as identity primary key,
    conversation_id uuid not null,
    user_id uuid not null,
    device_id uuid,
    seq bigint not null,
    role text not null,
    content text not null default '',
    content_json jsonb,
    agent_item_id text,
    source text not null default 'agent',
    occurred_at timestamptz not null,
    created_at timestamptz not null default now(),

    constraint messages_seq_positive check (seq > 0),
    constraint messages_role_valid check (role in ('user', 'assistant', 'system', 'tool')),
    constraint messages_content_length check (char_length(content) <= 32768),
    constraint messages_agent_item_id_length
        check (agent_item_id is null or char_length(agent_item_id) between 1 and 128),
    constraint messages_source_valid
        check (source in ('agent', 'offline_client', 'import')),

    -- One turn per position, and the index behind ordered reads.
    constraint messages_conversation_seq_unique unique (conversation_id, seq),

    -- Ownership anchor for memories that cite a source message.
    constraint messages_id_user_unique unique (id, user_id),

    constraint messages_conversation_ownership
        foreign key (conversation_id, user_id) references jarvis.conversations (id, user_id)
        on delete cascade,

    constraint messages_device_ownership
        foreign key (device_id, user_id) references jarvis.devices (id, user_id)
        on delete set null (device_id)
);

comment on table jarvis.messages is
    'Verbatim conversation turns, user and assistant alike. Losing this table loses history; '
    'it is deliberately separate from jarvis.memories.';
comment on column jarvis.messages.seq is
    'Position within the conversation, handed out by jarvis.allocate_message_seq().';
comment on column jarvis.messages.agent_item_id is
    'LiveKit ChatMessage id, used to make retried writes idempotent.';
comment on column jarvis.messages.source is
    'agent = written by the Python agent, offline_client = Flutter swallowed it offline, import = backfill.';

-- Idempotency for retried writes. Partial, because most rows carry no agent id.
create unique index messages_agent_item_idx
    on jarvis.messages (conversation_id, agent_item_id)
    where agent_item_id is not null;

create index messages_user_occurred_idx on jarvis.messages (user_id, occurred_at desc);

create table jarvis.conversation_summaries (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null,
    user_id uuid not null,
    summary text not null,
    covers_from_seq bigint not null,
    covers_to_seq bigint not null,
    model text,
    token_count integer,
    created_at timestamptz not null default now(),

    constraint conversation_summaries_text_length
        check (char_length(btrim(summary)) between 1 and 20000),
    constraint conversation_summaries_range_valid
        check (covers_from_seq > 0 and covers_to_seq >= covers_from_seq),
    constraint conversation_summaries_token_count
        check (token_count is null or token_count >= 0),
    constraint conversation_summaries_range_unique
        unique (conversation_id, covers_from_seq, covers_to_seq),

    constraint conversation_summaries_conversation_ownership
        foreign key (conversation_id, user_id) references jarvis.conversations (id, user_id)
        on delete cascade
);

comment on table jarvis.conversation_summaries is
    'Incremental summaries over a message range, so long conversations can be replayed '
    'cheaply without rewriting one mutable row.';

create index conversation_summaries_latest_idx
    on jarvis.conversation_summaries (conversation_id, covers_to_seq desc);

-- Concurrency-safe sequence allocation.
--
-- The UPDATE takes a row lock on the conversation, so two writers that ask at the
-- same moment queue behind each other and receive different numbers. A unique
-- constraint on (conversation_id, seq) backs this up: if the allocator were ever
-- bypassed, the second writer fails instead of corrupting order.
create or replace function jarvis.allocate_message_seq(p_conversation_id uuid, p_user_id uuid)
returns bigint
language sql
security invoker
set search_path = jarvis, pg_temp
as $$
    update jarvis.conversations
       set next_seq = next_seq + 1,
           last_activity_at = now()
     where id = p_conversation_id
       and user_id = p_user_id
    returning next_seq;
$$;

comment on function jarvis.allocate_message_seq(uuid, uuid) is
    'Atomically reserves the next message position in a conversation. Returns NULL when '
    'the conversation does not exist for that user. Gaps are expected when a reserved '
    'number is never used (a rolled back or deduplicated insert).';

commit;

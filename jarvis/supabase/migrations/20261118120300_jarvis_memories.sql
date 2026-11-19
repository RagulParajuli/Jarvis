-- 20261118120300 — Long-term memories, separate from conversation history.
--
-- Memory is curated: a deliberate "remember this" fact, not a transcript. It has
-- its own lifecycle (active / archived / deleted), its own dedupe key, and its
-- own deletion rules. Nothing here is derived automatically from jarvis.messages.

begin;

-- pg_trgm lives in the `extensions` schema; the GIN operator class is resolved
-- through search_path, so make it visible for this transaction only.
set local search_path = jarvis, public, extensions;

create table jarvis.memories (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references jarvis.users (id) on delete cascade,
    content text not null,
    content_hash text generated always as (
        encode(extensions.digest(lower(btrim(content)), 'sha256'), 'hex')
    ) stored,
    category text not null default 'general',
    source text not null default 'explicit_user',
    status text not null default 'active',
    pinned boolean not null default false,
    source_conversation_id uuid,
    source_message_id bigint,
    last_used_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz,

    constraint memories_content_length
        check (char_length(btrim(content)) between 1 and 2000),
    constraint memories_category_valid
        check (category in ('preference', 'fact', 'person', 'routine', 'project', 'general')),
    constraint memories_source_valid
        check (source in ('explicit_user', 'inferred', 'import')),
    constraint memories_status_valid
        check (status in ('active', 'archived', 'deleted')),
    constraint memories_deleted_at_consistency
        check ((status = 'deleted') = (deleted_at is not null)),

    -- Provenance only. Deleting the conversation must not delete the memory.
    constraint memories_source_conversation_ownership
        foreign key (source_conversation_id, user_id) references jarvis.conversations (id, user_id)
        on delete set null (source_conversation_id),
    constraint memories_source_message_ownership
        foreign key (source_message_id, user_id) references jarvis.messages (id, user_id)
        on delete set null (source_message_id)
);

comment on table jarvis.memories is
    'Curated long-term facts and preferences. Separate from jarvis.messages: history is '
    'a record of what was said, memory is what Jarvis should still know later.';
comment on column jarvis.memories.content_hash is
    'SHA-256 of the trimmed, lowercased content, hex encoded. Used to stop the same fact '
    'being stored twice while it is active.';
comment on column jarvis.memories.status is
    'active = usable by Jarvis, archived = kept but ignored, deleted = soft deleted and '
    'waiting for purge unless it is deleted permanently.';

-- Dedupe only among active rows, so a forgotten fact can be remembered again.
create unique index memories_active_content_unique
    on jarvis.memories (user_id, content_hash)
    where status = 'active';

create index memories_user_status_idx
    on jarvis.memories (user_id, status, updated_at desc);

create index memories_category_idx
    on jarvis.memories (user_id, category)
    where status = 'active';

-- Keyword search today. A pgvector column and HNSW index arrive with the memory
-- search work; adding a nullable vector column is cheap, so it is not guessed at now.
create index memories_fulltext_idx
    on jarvis.memories
    using gin (to_tsvector('english', content));

create index memories_trigram_idx
    on jarvis.memories
    using gin (content gin_trgm_ops);

create trigger memories_set_updated_at
    before update on jarvis.memories
    for each row execute function jarvis.set_updated_at();

-- Deletion with an explicit intent.
--
-- Soft is the default so a misheard "forget that" can be undone; permanent is a
-- first-class option because the user must be able to have a fact gone now, not
-- in thirty days. Both are scoped by user so a caller can never delete across
-- accounts.
create or replace function jarvis.delete_memory(
    p_memory_id uuid,
    p_user_id uuid,
    p_permanent boolean default false
)
returns boolean
language plpgsql
security invoker
set search_path = jarvis, pg_temp
as $$
declare
    affected integer;
begin
    if p_permanent then
        delete from jarvis.memories
         where id = p_memory_id
           and user_id = p_user_id;
    else
        update jarvis.memories
           set status = 'deleted',
               deleted_at = coalesce(deleted_at, now())
         where id = p_memory_id
           and user_id = p_user_id
           and status <> 'deleted';
    end if;

    get diagnostics affected = row_count;
    return affected > 0;
end;
$$;

comment on function jarvis.delete_memory(uuid, uuid, boolean) is
    'Soft deletes by default and removes the row outright when p_permanent is true. '
    'Returns false when nothing matched, so a caller can answer honestly.';

-- Removes soft-deleted memories once the undo window has passed. Lives in SQL so
-- the rule is identical whether it is run by a scheduled job or by hand.
create or replace function jarvis.purge_deleted_memories(p_older_than interval default '30 days')
returns bigint
language plpgsql
security invoker
set search_path = jarvis, pg_temp
as $$
declare
    removed bigint;
begin
    if p_older_than < interval '0' then
        raise exception 'p_older_than must not be negative';
    end if;

    delete from jarvis.memories
     where status = 'deleted'
       and deleted_at < now() - p_older_than;

    get diagnostics removed = row_count;
    return removed;
end;
$$;

comment on function jarvis.purge_deleted_memories(interval) is
    'Permanently removes memories soft deleted longer ago than the given window.';

commit;

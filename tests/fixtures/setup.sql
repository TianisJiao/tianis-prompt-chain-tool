-- Run this once in your own Supabase project's SQL Editor.
-- These are public demonstration records, with read-only access for visitors.
create table if not exists public.caption_ideas (
  id bigint generated always as identity primary key,
  title text not null,
  context text not null,
  category text not null,
  created_at timestamptz not null default now()
);

alter table public.caption_ideas enable row level security;

grant select on public.caption_ideas to anon, authenticated;

create policy "Anyone can read caption ideas"
on public.caption_ideas for select
to anon, authenticated
using (true);

insert into public.caption_ideas (title, context, category) values
  ('The group project group chat', 'Everyone said “sounds good” and nobody opened the document.', 'Campus life'),
  ('A calendar with too many tabs', 'The meeting about scheduling the meeting has been rescheduled.', 'Work life'),
  ('My first database query', 'I asked for three rows and got three rows. A small miracle.', 'Building');

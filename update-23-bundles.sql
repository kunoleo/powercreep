-- =====================================================================
-- Power Creep update 23: bundles in the shop
-- Run in Supabase → SQL Editor → New query → Run. Needs updates 13, 16, 19, 20 and 22. Safe to run again.
-- A bundle is a themed set of items for less than buying each one. Anyone who finishes a set gets its badge,
-- whether they bought the bundle or collected the pieces one by one.
-- =====================================================================

-- The badges that come with the bundles (they can't be bought on their own)
insert into public.items (id, kind, name, price, unlock_level, sort) values
  ('badge:playerone','badge','Player One',null,null,20), ('badge:sweetheart','badge','Sweetheart',null,null,21),
  ('badge:haunted','badge','Haunted',null,null,22), ('badge:hanami','badge','Hanami',null,null,23),
  ('badge:hacker','badge','Hacker',null,null,24), ('badge:firestarter','badge','Firestarter',null,null,25),
  ('badge:stargazer','badge','Stargazer',null,null,26), ('badge:synthwave','badge','Synthwave',null,null,27),
  ('badge:hexagons','badge','Hexagons',null,null,28), ('badge:foxspirit','badge','Fox Spirit',null,null,29)
on conflict (id) do update set kind = excluded.kind, name = excluded.name, price = excluded.price,
  unlock_level = excluded.unlock_level, sort = excluded.sort;

create table if not exists public.bundles (
  id     text primary key,
  name   text not null,
  badge  text not null references public.items(id),
  items  text[] not null,
  price  integer not null check (price > 0),
  sort   integer not null default 0
);
alter table public.bundles enable row level security;
drop policy if exists "bundles are public" on public.bundles;
create policy "bundles are public" on public.bundles for select using (true);
revoke all on public.bundles from anon, authenticated;
grant select on public.bundles to anon, authenticated;

-- To add a bundle later: add a row here (the price is what someone pays when they own none of the items)
insert into public.bundles (id, name, badge, items, price, sort) values
  ('arcade','Arcade','badge:playerone',array['frame:pixel','font:pixel','name:retro','hfx:stars'],600,1),
  ('love','Sweetheart','badge:sweetheart',array['frame:hearts','hfx:hearts','font:script','name:glow'],700,2),
  ('spooky','Haunted','badge:haunted',array['frame:ghosts','hfx:fog','font:horror'],750,3),
  ('sakura','Hanami','badge:hanami',array['frame:sakura','hfx:sakura','font:brush'],800,4),
  ('hacker','Hacker','badge:hacker',array['frame:circuit','hfx:data','name:typing','font:terminal'],900,5),
  ('inferno','Inferno','badge:firestarter',array['frame:ember','hfx:embers','name:fire'],1100,6),
  ('space','Stargazer','badge:stargazer',array['frame:nebula','hfx:shoot','name:sparkle','font:space'],1150,7),
  ('synth','Synthwave','badge:synthwave',array['frame:neon','hfx:rain','name:neon','font:retro'],1150,8),
  ('hex','Hex set','badge:hexagons',array['frame:hex','hfx:hexgrid','hfx:checker','name:holo'],1200,9),
  ('kitsune','Kitsune','badge:foxspirit',array['frame:kitsune','hfx:foxfire','name:foxfire','font:samurai'],1400,10)
on conflict (id) do update set name = excluded.name, badge = excluded.badge, items = excluded.items,
  price = excluded.price, sort = excluded.sort;

-- Buy a bundle. You only pay for the pieces you're missing (with the same discount), and you get the badge.
-- If you already own every piece, the badge is free. Returns what you paid.
create or replace function public.buy_bundle(p_bundle text) returns integer
language plpgsql security definer set search_path = public as $$
declare b public.bundles; full_value int; missing_value int; missing text[]; pay int;
begin
  if auth.uid() is null or not public.is_active() then raise exception 'Not allowed.'; end if;
  select * into b from public.bundles where id = p_bundle;
  if not found then raise exception 'That bundle doesn''t exist.'; end if;
  perform 1 from public.profiles where id = auth.uid() for update;   -- one purchase at a time per person
  if exists (select 1 from public.owned_items where user_id = auth.uid() and item_id = b.badge)
     and not exists (select 1 from unnest(b.items) i where not public.owns(auth.uid(), i)) then
    raise exception 'You already have this whole set.'; end if;
  select coalesce(sum(it.price), 0) into full_value from public.items it where it.id = any (b.items);
  select coalesce(array_agg(it.id), '{}'), coalesce(sum(it.price), 0) into missing, missing_value
    from public.items it where it.id = any (b.items) and not public.owns(auth.uid(), it.id);
  pay := case when missing_value = full_value then b.price
              else round(b.price::numeric * missing_value / greatest(full_value, 1) / 10) * 10 end;
  if pay > 0 then
    update public.profiles set volts = volts - pay where id = auth.uid() and volts >= pay;
    if not found then raise exception 'Not enough Volts yet.'; end if;
  end if;
  insert into public.owned_items (user_id, item_id)
    select auth.uid(), x from unnest(missing || b.badge) x on conflict do nothing;
  -- If you picked which badges to show, the new one is added to them (up to 6)
  update public.profiles set badges_shown = array_append(badges_shown, b.badge)
   where id = auth.uid() and badges_shown is not null and not (b.badge = any (badges_shown)) and cardinality(badges_shown) < 6;
  return pay;
end $$;
revoke all on function public.buy_bundle(text) from public;
grant execute on function public.buy_bundle(text) to authenticated;

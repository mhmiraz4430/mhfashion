-- MH FASHION: SAFE, RE-RUNNABLE DATABASE SETUP / REPAIR
-- Run once in Supabase Dashboard > SQL Editor for the same project used in config.js.
-- Does not delete existing products, orders, admin users, or storage files.

create extension if not exists pgcrypto;

-- Keep both admin tables for backward compatibility with the original school website.
create table if not exists public.school_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.store_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Migrate existing school-site admin permissions into the store admin table.
insert into public.store_admins(user_id)
select user_id from public.school_admins
on conflict (user_id) do nothing;

-- The same RPC now recognizes both legacy school admins and store admins.
create or replace function public.is_school_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.store_admins a
    where a.user_id = (select auth.uid())
  ) or exists (
    select 1 from public.school_admins a
    where a.user_id = (select auth.uid())
  );
$$;
revoke all on function public.is_school_admin() from public;
grant execute on function public.is_school_admin() to anon, authenticated;

-- Core store tables. CREATE IF NOT EXISTS preserves existing records.
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  price numeric(12,2) not null check (price > 0),
  old_price numeric(12,2),
  category text not null default 'অন্যান্য',
  stock integer not null default 0 check (stock >= 0),
  description text,
  image_url text not null default '',
  active boolean not null default true,
  size_type text not null default 'none',
  size_options text[] not null default '{}',
  length_options text[] not null default '{}',
  size_note text not null default '',
  created_at timestamptz not null default now()
);
alter table public.products add column if not exists old_price numeric(12,2);
alter table public.products add column if not exists category text not null default 'অন্যান্য';
alter table public.products add column if not exists stock integer not null default 0;
alter table public.products add column if not exists description text;
alter table public.products add column if not exists image_url text not null default '';
alter table public.products add column if not exists active boolean not null default true;
alter table public.products add column if not exists size_type text not null default 'none';
alter table public.products add column if not exists size_options text[] not null default '{}';
alter table public.products add column if not exists length_options text[] not null default '{}';
alter table public.products add column if not exists size_note text not null default '';
alter table public.products add column if not exists created_at timestamptz not null default now();

create table if not exists public.hero_slides (
  id uuid primary key default gen_random_uuid(),
  title text,
  subtitle text,
  image_url text not null,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  phone text not null,
  address text not null,
  note text,
  items jsonb not null,
  subtotal numeric(12,2) not null,
  delivery numeric(12,2) not null default 0,
  total numeric(12,2) not null,
  status text not null default 'নতুন',
  payment_method text not null default 'ক্যাশ অন ডেলিভারি',
  created_at timestamptz not null default now()
);

create table if not exists public.store_settings (
  key text primary key,
  value text not null default ''
);

-- Grants and RLS.
grant usage on schema public to anon, authenticated;
grant select on public.products, public.hero_slides, public.store_settings to anon, authenticated;
grant insert, update, delete on public.products, public.hero_slides to authenticated;
grant insert on public.orders to anon, authenticated;
grant select, update on public.orders to authenticated;
grant insert, update, delete on public.store_settings to authenticated;

alter table public.school_admins enable row level security;
alter table public.store_admins enable row level security;
alter table public.products enable row level security;
alter table public.hero_slides enable row level security;
alter table public.orders enable row level security;
alter table public.store_settings enable row level security;

drop policy if exists "Public can read active products" on public.products;
create policy "Public can read active products" on public.products
  for select to anon, authenticated using (active = true or public.is_school_admin());
drop policy if exists "Admins manage products" on public.products;
create policy "Admins manage products" on public.products
  for all to authenticated using (public.is_school_admin()) with check (public.is_school_admin());

drop policy if exists "Public can read active slides" on public.hero_slides;
create policy "Public can read active slides" on public.hero_slides
  for select to anon, authenticated using (active = true or public.is_school_admin());
drop policy if exists "Admins manage slides" on public.hero_slides;
create policy "Admins manage slides" on public.hero_slides
  for all to authenticated using (public.is_school_admin()) with check (public.is_school_admin());

drop policy if exists "Customers can place orders" on public.orders;
create policy "Customers can place orders" on public.orders
  for insert to anon, authenticated with check (
    char_length(customer_name) between 2 and 100
    and char_length(phone) between 10 and 16
    and char_length(address) between 5 and 500
    and jsonb_typeof(items) = 'array'
    and total >= 0
  );
drop policy if exists "Admins read orders" on public.orders;
create policy "Admins read orders" on public.orders
  for select to authenticated using (public.is_school_admin());
drop policy if exists "Admins update orders" on public.orders;
create policy "Admins update orders" on public.orders
  for update to authenticated using (public.is_school_admin()) with check (public.is_school_admin());

drop policy if exists "Public read store settings" on public.store_settings;
create policy "Public read store settings" on public.store_settings
  for select to anon, authenticated using (true);
drop policy if exists "Admins manage store settings" on public.store_settings;
create policy "Admins manage store settings" on public.store_settings
  for all to authenticated using (public.is_school_admin()) with check (public.is_school_admin());

-- Ensure image buckets exist (and repair public/read configuration if already present).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('product-images', 'product-images', true, 5242880, array['image/jpeg','image/png','image/webp']),
  ('hero-images', 'hero-images', true, 5242880, array['image/jpeg','image/png','image/webp']),
  ('logo-images', 'logo-images', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public read MH images" on storage.objects;
create policy "Public read MH images" on storage.objects
  for select to anon, authenticated
  using (bucket_id in ('product-images','hero-images','logo-images'));
drop policy if exists "Admins upload MH images" on storage.objects;
create policy "Admins upload MH images" on storage.objects
  for insert to authenticated
  with check (bucket_id in ('product-images','hero-images','logo-images') and public.is_school_admin());
drop policy if exists "Admins update MH images" on storage.objects;
create policy "Admins update MH images" on storage.objects
  for update to authenticated
  using (bucket_id in ('product-images','hero-images','logo-images') and public.is_school_admin())
  with check (bucket_id in ('product-images','hero-images','logo-images') and public.is_school_admin());
drop policy if exists "Admins delete MH images" on storage.objects;
create policy "Admins delete MH images" on storage.objects
  for delete to authenticated
  using (bucket_id in ('product-images','hero-images','logo-images') and public.is_school_admin());

notify pgrst, 'reload schema';

-- If the previous admin account was not in school_admins, create it in
-- Supabase Authentication > Users, copy its UUID, then run:
-- insert into public.store_admins(user_id) values ('YOUR_AUTH_USER_UUID')
-- on conflict (user_id) do nothing;

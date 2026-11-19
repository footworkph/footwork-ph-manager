-- Footwork PH: online studio rental booking
-- Renters pick a date + start hour + number of hours on the booking link (book/#rent),
-- pay the reservation fee via GCash/Maya, and upload proof. The studio confirms in the
-- Studio Manager (Rental tab), which adds the booking to the rental list.
-- Busy hours = classes (1 hour each) + rentals in the Studio Manager + online requests.

alter table public.fw_booking_config
  add column if not exists rental_open_hour  int     not null default 8,
  add column if not exists rental_close_hour int     not null default 22,
  add column if not exists rental_min_hours  int     not null default 2,
  add column if not exists rental_max_hours  int     not null default 8,
  add column if not exists rental_reserve    numeric not null default 500;

create table if not exists public.fw_rental_requests (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  owner uuid not null,
  rent_date date not null,
  start_hour int not null,
  hours int not null,
  starts_at timestamptz not null,
  name text not null,
  contact text not null,
  email text,
  fb text,
  purpose text,
  pax int,
  total numeric not null,
  reservation numeric not null,
  pay_ref text,
  proof_path text,
  status text not null default 'pending' check (status in ('pending','confirmed','declined','cancelled')),
  rental_id text,
  note text,
  agreed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fw_rental_requests_owner_date on public.fw_rental_requests (owner, rent_date);
alter table public.fw_rental_requests enable row level security;
drop policy if exists "fw rental owner read" on public.fw_rental_requests;
drop policy if exists "fw rental owner update" on public.fw_rental_requests;
create policy "fw rental owner read" on public.fw_rental_requests for select using (owner = (select auth.uid()));
create policy "fw rental owner update" on public.fw_rental_requests for update using (owner = (select auth.uid()));

-- Busy hours per day: one row per (date, hour) that is taken.
create or replace function public.fw__rental_busy(p_from date, p_to date)
returns table(d date, h int, kind text)
language sql stable security definer set search_path to 'public' as $$
  with cfg as (select * from public.fw_booking_config where id = 1),
  st as (select s.data from public.fw_studio_state s, cfg where s.owner = cfg.owner),
  blocks as (
    -- classes: 1 hour each
    select (x->>'date')::date dd,
           (split_part(x->>'time',':',1)::int * 60 + coalesce(nullif(split_part(x->>'time',':',2),'')::int,0)) m0,
           60 dur, 'class'::text k
      from st, jsonb_array_elements(coalesce(st.data->'sessions','[]'::jsonb)) x
     where coalesce(x->>'date','') ~ '^\d{4}-\d{2}-\d{2}$' and coalesce(x->>'time','') ~ '^\d{1,2}:\d{2}'
       and coalesce(x->>'status','') <> 'cancelled'
       and (x->>'date')::date between p_from and p_to
    union all
    -- rentals already in the Studio Manager
    select (x->>'date')::date,
           (split_part(x->>'time',':',1)::int * 60 + coalesce(nullif(split_part(x->>'time',':',2),'')::int,0)),
           round((coalesce(nullif(x->>'hours','')::numeric,0) + coalesce(nullif(x->>'extHours','')::numeric,0)) * 60)::int,
           'rented'
      from st, jsonb_array_elements(coalesce(st.data->'rentals','[]'::jsonb)) x
     where coalesce(x->>'date','') ~ '^\d{4}-\d{2}-\d{2}$' and coalesce(x->>'time','') ~ '^\d{1,2}:\d{2}'
       and coalesce(x->>'status','') <> 'cancelled'
       and (x->>'date')::date between p_from and p_to
    union all
    -- online requests not yet in the Studio Manager list
    select r.rent_date, r.start_hour * 60, r.hours * 60, 'rented'
      from public.fw_rental_requests r, cfg, st
     where r.owner = cfg.owner and r.rent_date between p_from and p_to
       and (r.status = 'pending'
            or (r.status = 'confirmed' and not exists (
                  select 1 from jsonb_array_elements(coalesce(st.data->'rentals','[]'::jsonb)) y where y->>'id' = r.rental_id)))
  )
  select distinct b.dd, g.hh, b.k
    from blocks b, generate_series(b.m0 / 60, greatest(b.m0 / 60, ((b.m0 + greatest(b.dur,1) - 1) / 60))) g(hh)
   where b.dur > 0;
$$;

create or replace function public.fw__rental_price(p_hours int)
returns numeric language sql stable security definer set search_path to 'public' as $$
  with cfg as (select * from public.fw_booking_config where id = 1),
  st as (select s.data from public.fw_studio_state s, cfg where s.owner = cfg.owner)
  select least(p_hours, cfg.rental_min_hours) * coalesce(nullif(st.data->'settings'->'rental'->>'hour','')::numeric, 500)
       + greatest(p_hours - cfg.rental_min_hours, 0) * coalesce(nullif(st.data->'settings'->'rental'->>'extHour','')::numeric, 300)
    from cfg, st;
$$;

-- Public: rental calendar for the booking link.
create or replace function public.fw_rental_availability()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare cfg public.fw_booking_config; st jsonb; nowt timestamp := now() at time zone 'Asia/Manila';
  d0 date; d1 date; days jsonb;
begin
  select * into cfg from public.fw_booking_config where id = 1;
  select s.data into st from public.fw_studio_state s where s.owner = cfg.owner;
  d0 := nowt::date; d1 := d0 + least(cfg.days_ahead, 30);
  with busy as (select * from public.fw__rental_busy(d0, d1)),
  grid as (
    select dd::date d, hh h,
      case when (dd::date + make_time(hh,0,0)) < nowt + make_interval(hours => cfg.cutoff_hours) then 'past'
           when exists (select 1 from busy b where b.d = dd::date and b.h = hh and b.kind = 'rented') then 'rented'
           when exists (select 1 from busy b where b.d = dd::date and b.h = hh and b.kind = 'class') then 'class'
           else 'free' end stt
      from generate_series(d0, d1, interval '1 day') dd, generate_series(cfg.rental_open_hour, cfg.rental_close_hour - 1) hh
  )
  select jsonb_agg(jsonb_build_object('date', d, 'hours', hs, 'free', nf, 'rentedHours', nr, 'classHours', nc) order by d) into days
    from (select d, jsonb_agg(jsonb_build_object('h', h, 'st', stt) order by h) hs,
                 count(*) filter (where stt = 'free') nf, count(*) filter (where stt = 'rented') nr, count(*) filter (where stt = 'class') nc
            from grid group by d) q;
  return jsonb_build_object('ok', true, 'open', cfg.open, 'owner', cfg.owner,
    'openHour', cfg.rental_open_hour, 'closeHour', cfg.rental_close_hour,
    'minHours', cfg.rental_min_hours, 'maxHours', cfg.rental_max_hours, 'reserve', cfg.rental_reserve,
    'hourRate', coalesce(nullif(st->'settings'->'rental'->>'hour','')::numeric, 500),
    'extRate', coalesce(nullif(st->'settings'->'rental'->>'extHour','')::numeric, 300),
    'payName', cfg.guest_pay_name, 'payNumber', cfg.guest_pay_number, 'cutoffHours', cfg.cutoff_hours,
    'days', coalesce(days, '[]'::jsonb));
end $$;

-- Public: reserve a rental slot (proof of the reservation payment is required).
create or replace function public.fw_rental_book(p_date date, p_start int, p_hours int, p_name text, p_mobile text,
  p_email text, p_fb text, p_purpose text, p_pax int, p_pay_ref text, p_proof_path text, p_agreed boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cfg public.fw_booking_config; v_m text; v_name text; v_email text; v_fb text; v_purpose text;
  nowt timestamp := now() at time zone 'Asia/Manila'; r text; v_total numeric;
begin
  select * into cfg from public.fw_booking_config where id = 1;
  if not cfg.open then return jsonb_build_object('ok', false, 'error', 'paused'); end if;
  if p_agreed is not true then return jsonb_build_object('ok', false, 'error', 'not_agreed'); end if;
  v_name := btrim(coalesce(p_name,'')); v_email := btrim(coalesce(p_email,'')); v_fb := btrim(coalesce(p_fb,''));
  v_purpose := left(btrim(coalesce(p_purpose,'')), 120);
  v_m := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  if length(v_name) < 2 or length(v_name) > 80 or length(v_m) < 10 or length(v_m) > 13 or length(v_fb) < 2 or length(v_fb) > 80
     or v_email = '' or length(v_email) > 120 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     or p_pax is null or p_pax < 1 or p_pax > 10 or length(coalesce(p_pay_ref,'')) > 80
     or p_proof_path is null or left(p_proof_path, length(cfg.owner::text)+1) <> cfg.owner::text || '/' or length(p_proof_path) > 200 then
    return jsonb_build_object('ok', false, 'error', 'bad_details');
  end if;
  if p_date is null or p_start is null or p_hours is null or p_hours < cfg.rental_min_hours or p_hours > cfg.rental_max_hours
     or p_start < cfg.rental_open_hour or p_start + p_hours > cfg.rental_close_hour
     or p_date > nowt::date + least(cfg.days_ahead, 30) then
    return jsonb_build_object('ok', false, 'error', 'bad_time');
  end if;
  if (p_date + make_time(p_start,0,0)) < nowt + make_interval(hours => cfg.cutoff_hours) then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;
  if (select count(*) from public.fw_rental_requests where owner = cfg.owner and created_at > now() - interval '10 minutes') >= 15 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  if (select count(*) from public.fw_rental_requests where owner = cfg.owner and status in ('pending','confirmed')
        and right(regexp_replace(contact,'\D','','g'),10) = right(v_m,10) and starts_at > now()) >= 3 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  perform pg_advisory_xact_lock(hashtext('fwrent:' || p_date::text));
  if exists (select 1 from public.fw__rental_busy(p_date, p_date) b where b.d = p_date and b.h >= p_start and b.h < p_start + p_hours) then
    return jsonb_build_object('ok', false, 'error', 'taken');
  end if;
  v_total := public.fw__rental_price(p_hours);
  r := 'RN-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
  insert into public.fw_rental_requests (ref, owner, rent_date, start_hour, hours, starts_at, name, contact, email, fb, purpose, pax,
      total, reservation, pay_ref, proof_path, agreed_at)
  values (r, cfg.owner, p_date, p_start, p_hours, (p_date + make_time(p_start,0,0)) at time zone 'Asia/Manila', v_name, v_m, v_email, v_fb,
      nullif(v_purpose,''), p_pax, v_total, cfg.rental_reserve, nullif(btrim(coalesce(p_pay_ref,'')),''), p_proof_path, now());
  return jsonb_build_object('ok', true, 'ref', r, 'total', v_total, 'reserve', cfg.rental_reserve, 'balance', greatest(v_total - cfg.rental_reserve, 0));
end $$;

-- Public: check a rental request by ref + mobile.
create or replace function public.fw_rental_status(p_ref text, p_mobile text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare cfg public.fw_booking_config; x public.fw_rental_requests; m text;
begin
  select * into cfg from public.fw_booking_config where id = 1;
  m := right(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g'), 10);
  if length(m) < 10 then return jsonb_build_object('ok', false, 'error', 'bad_details'); end if;
  select * into x from public.fw_rental_requests
   where owner = cfg.owner and upper(ref) = upper(btrim(coalesce(p_ref,''))) and right(regexp_replace(contact,'\D','','g'),10) = m
   order by created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_booking'); end if;
  return jsonb_build_object('ok', true, 'ref', x.ref, 'name', x.name, 'date', x.rent_date, 'start', x.start_hour, 'hours', x.hours,
    'total', x.total, 'reserve', x.reservation, 'balance', greatest(x.total - x.reservation, 0), 'status', x.status);
end $$;

revoke all on function public.fw__rental_busy(date, date) from public, anon, authenticated;
revoke all on function public.fw__rental_price(int) from public, anon, authenticated;
grant execute on function public.fw_rental_availability() to anon, authenticated;
grant execute on function public.fw_rental_book(date, int, int, text, text, text, text, text, int, text, text, boolean) to anon, authenticated;
grant execute on function public.fw_rental_status(text, text) to anon, authenticated;

-- Email alert to the studio when a rental request comes in (same mail setup as class bookings).
create or replace function public.fw_rental_alert_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare st jsonb; v_url text; v_key text; v_subj text; v_html text; v_text text; v_when text;
  F constant text := 'font-family:Arial,Helvetica,sans-serif;';
  MGR constant text := 'https://footworkph.github.io/footwork-ph-manager/';
  TO_ constant text := 'fwork.ph@gmail.com';
begin
  begin
    select s.data into st from fw_studio_state s where s.owner = new.owner;
    v_url := st->'settings'->'mail'->>'url'; v_key := st->'settings'->'mail'->>'key';
    if v_url is null or v_url !~ '^https://script\.google\.com/macros/s/[\w-]+/exec$' then return null; end if;
    v_when := to_char(new.rent_date, 'Dy, Mon FMDD') || ' · ' || to_char(new.rent_date + make_time(new.start_hour,0,0), 'FMHH12 AM') || '–'
              || to_char(new.rent_date + make_time(new.start_hour,0,0) + make_interval(hours => new.hours), 'FMHH12 AM') || ' (' || new.hours || ' hrs)';
    v_subj := '🏠 Studio rental request: ' || new.name || ' · ' || v_when;
    v_text := 'New studio rental request with reservation payment. Check the proof and confirm in the Studio Manager > Rental.' || E'\n\n'
      || 'Name: ' || new.name || E'\nFacebook name: ' || coalesce(new.fb,'') || E'\nContact: ' || new.contact || E'\nEmail: ' || coalesce(new.email,'')
      || E'\nWhen: ' || v_when || E'\nPax: ' || coalesce(new.pax::text,'') || E'\nPurpose: ' || coalesce(new.purpose,'')
      || E'\nTotal: ₱' || new.total || ' · Reservation paid: ₱' || new.reservation || ' · Balance: ₱' || greatest(new.total - new.reservation,0)
      || E'\nRef: ' || new.ref || case when coalesce(new.pay_ref,'') <> '' then E'\nPayment ref: ' || new.pay_ref else '' end
      || E'\n\nOpen Studio Manager: ' || MGR;
    v_html := '<div style="' || F || 'max-width:520px;margin:0 auto;border:3px solid #FA1294;border-radius:14px;overflow:hidden">'
      || '<div style="background:#111;padding:14px;text-align:center;font-size:22px;font-weight:900;font-style:italic"><span style="color:#fff">FOOT</span><span style="color:#B4FA2A">WORK</span> <span style="color:#FA1294">PH</span></div>'
      || '<div style="padding:16px 18px;font-size:15px;line-height:1.6;color:#111">'
      || '<div style="font-size:18px;font-weight:800;margin-bottom:8px">🏠 Studio rental request · reservation paid</div>'
      || '<b>Name:</b> ' || fw_esc(new.name) || '<br><b>Facebook name:</b> <span style="color:#FA1294;font-weight:800">' || fw_esc(coalesce(new.fb,'')) || '</span><br>'
      || '<b>Contact:</b> ' || fw_esc(new.contact) || '<br><b>When:</b> ' || fw_esc(v_when) || '<br>'
      || '<b>Pax:</b> ' || coalesce(new.pax::text,'') || '<br><b>Purpose:</b> ' || fw_esc(coalesce(new.purpose,'')) || '<br>'
      || '<b>Total:</b> ₱' || new.total || ' · <b>Reservation:</b> ₱' || new.reservation || ' · <b>Balance:</b> ₱' || greatest(new.total - new.reservation,0) || '<br>'
      || '<b>Ref:</b> ' || fw_esc(new.ref) || '<br>' || case when coalesce(new.pay_ref,'') <> '' then '<b>Payment ref:</b> ' || fw_esc(new.pay_ref) || '<br>' else '' end
      || '</div><div style="padding:0 18px 18px;text-align:center"><a href="' || MGR || '" style="display:inline-block;background:#111;color:#B4FA2A;font-weight:900;text-decoration:none;padding:12px 26px;border-radius:999px;border:3px solid #B4FA2A">OPEN STUDIO MANAGER</a></div></div>';
    perform net.http_post(url := v_url,
      body := jsonb_build_object('key', v_key, 'to', jsonb_build_array(TO_), 'subject', v_subj, 'html', v_html, 'text', v_text),
      headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 20000);
  exception when others then raise warning 'fw_rental_alert failed: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists fw_rental_alert on public.fw_rental_requests;
create trigger fw_rental_alert after insert on public.fw_rental_requests for each row execute function public.fw_rental_alert_trg();

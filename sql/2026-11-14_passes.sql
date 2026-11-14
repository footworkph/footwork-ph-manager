-- Footwork PH: package passes (Unli December, 5/10 sessions, Christmas Gift Pass)
-- Pass holders book without paying; the studio's package record decides coverage.

-- Pass check for one student and one class (or just a status summary when p_info = true).
-- Returns NULL when the student has no pass that covers the class (normal paid booking),
-- {ok:false,error:...} when the pass covers it but a rule blocks the booking,
-- {ok:true,...} when the class is covered.
create or replace function public.fw__pkg(p_member_id text, p_session_id text default null, p_info boolean default false)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  cfg public.fw_booking_config; d jsonb; m jsonb; p jsonb; ses jsonb;
  v_date date; v_type text; kind text; types jsonb;
  v_start date; v_from date; v_to date; v_exp date; v_first date; v_startby date;
  n_sessions int; v_days int; used int; day_n int; ns int; last_ns timestamptz; unli boolean;
  today date := (now() at time zone 'Asia/Manila')::date;
  isd text := '^\d{4}-\d{2}-\d{2}$';
begin
  select * into cfg from public.fw_booking_config where id = 1;
  select s.data into d from public.fw_studio_state s where s.owner = cfg.owner;
  select x into m from jsonb_array_elements(coalesce(d->'members','[]'::jsonb)) x where x->>'id' = p_member_id limit 1;
  if m is null or coalesce(m->>'planId','') = '' then return null; end if;
  select x into p from jsonb_array_elements(coalesce(d->'settings'->'plans','[]'::jsonb)) x where x->>'id' = m->>'planId' limit 1;
  if p is null then return null; end if;

  if p_session_id is not null then
    select x into ses from jsonb_array_elements(coalesce(d->'sessions','[]'::jsonb)) x where x->>'id' = p_session_id limit 1;
    if ses is null or coalesce(ses->>'date','') !~ isd then return null; end if;
    v_date := (ses->>'date')::date; v_type := coalesce(ses->>'typeId','');
  else
    v_date := today;
  end if;

  n_sessions := coalesce(nullif(p->>'sessions','')::int, 0);
  unli := n_sessions = 0;
  v_days := coalesce(nullif(p->>'days','')::int, 0);
  v_start := case when coalesce(m->>'startDate','') ~ isd then (m->>'startDate')::date end;
  v_from := case when coalesce(p->>'validFrom','') ~ isd then (p->>'validFrom')::date end;
  v_to := case when coalesce(p->>'validTo','') ~ isd then (p->>'validTo')::date end;
  v_startby := case when coalesce(p->>'startBy','') ~ isd then (p->>'startBy')::date end;

  -- first class used with this pass (attendance or an active pass booking)
  select min(dd) into v_first from (
    select (x->>'date')::date dd
      from jsonb_array_elements(coalesce(d->'sessions','[]'::jsonb)) x, jsonb_array_elements(coalesce(x->'attendees','[]'::jsonb)) a
     where a->>'memberId' = p_member_id and coalesce((a->>'pkg')::boolean,false)
       and coalesce(x->>'date','') ~ isd and (v_start is null or (x->>'date')::date >= v_start)
    union all
    select (b.starts_at at time zone 'Asia/Manila')::date from public.fw_bookings b
     where b.owner = cfg.owner and b.member_id = p_member_id and b.pay_method = 'package' and b.status in ('pending','confirmed')
  ) q;

  if coalesce((p->>'fromFirstClass')::boolean, false) then
    if v_first is not null then v_exp := v_first + v_days;
    elsif not p_info then v_exp := v_date + v_days; end if;
  elsif v_start is not null and v_days > 0 then
    v_exp := v_start + v_days;
  end if;
  if v_to is not null and (v_exp is null or v_to < v_exp) then v_exp := v_to; end if;

  -- sessions used so far (each class counted once)
  select count(distinct sid) into used from (
    select x->>'id' sid
      from jsonb_array_elements(coalesce(d->'sessions','[]'::jsonb)) x, jsonb_array_elements(coalesce(x->'attendees','[]'::jsonb)) a
     where a->>'memberId' = p_member_id and coalesce((a->>'pkg')::boolean,false)
       and coalesce(x->>'date','') ~ isd and (v_start is null or (x->>'date')::date >= v_start)
    union all
    select b.class_id from public.fw_bookings b
     where b.owner = cfg.owner and b.member_id = p_member_id and b.pay_method = 'package' and b.status in ('pending','confirmed')
  ) q;

  if p_info then
    return jsonb_build_object('ok', true, 'name', p->>'name', 'unli', unli, 'sessions', n_sessions,
      'left', case when unli then null else greatest(n_sessions - used, 0) end,
      'validFrom', v_from, 'validTo', v_exp, 'startBy', case when v_first is null then v_startby end,
      'expired', (v_exp is not null and v_exp < today) or (not unli and used >= n_sessions));
  end if;

  -- coverage: member/non-member price, class types, dates
  kind := case when coalesce(m->>'type','member') = 'member'
                and not (coalesce(m->>'validUntil','') ~ isd and (m->>'validUntil')::date < v_date) then 'member' else 'nonmember' end;
  if coalesce(p->>'for','') <> '' and p->>'for' <> kind then return null; end if;
  types := case when coalesce(m->>'planType','') <> '' then jsonb_build_array(m->>'planType') else coalesce(p->'typeIds','[]'::jsonb) end;
  if jsonb_array_length(types) > 0 and not (types ? v_type) then return null; end if;
  if v_start is not null and v_date < v_start then return null; end if;
  if v_from is not null and v_date < v_from then return null; end if;
  if v_first is null and v_startby is not null and v_date > v_startby then return null; end if;
  if v_exp is not null and v_date > v_exp then return null; end if;
  if not unli and used >= n_sessions then return null; end if;

  if unli then
    -- max 2 classes a day
    select count(distinct sid) into day_n from (
      select x->>'id' sid
        from jsonb_array_elements(coalesce(d->'sessions','[]'::jsonb)) x, jsonb_array_elements(coalesce(x->'attendees','[]'::jsonb)) a
       where a->>'memberId' = p_member_id and coalesce((a->>'pkg')::boolean,false) and x->>'date' = v_date::text
      union all
      select b.class_id from public.fw_bookings b
       where b.owner = cfg.owner and b.member_id = p_member_id and b.pay_method = 'package' and b.status in ('pending','confirmed')
         and (b.starts_at at time zone 'Asia/Manila')::date = v_date
    ) q;
    if day_n >= 2 then return jsonb_build_object('ok', false, 'error', 'daily_limit'); end if;

    -- no-show rule: from the 2nd no-show on, booking pauses for 3 days after each no-show.
    -- Only classes where attendance was taken (at least 1 student checked in) count.
    select count(*), max(b.starts_at) into ns, last_ns from public.fw_bookings b
     where b.owner = cfg.owner and b.member_id = p_member_id and b.pay_method = 'package' and b.status = 'confirmed'
       and b.starts_at < now() - interval '12 hours'
       and exists (select 1 from jsonb_array_elements(coalesce(d->'sessions','[]'::jsonb)) x
                    where x->>'id' = b.class_id and jsonb_array_length(coalesce(x->'attendees','[]'::jsonb)) > 0
                      and not exists (select 1 from jsonb_array_elements(x->'attendees') a where a->>'memberId' = p_member_id));
    if ns >= 2 and last_ns + interval '3 days' > now() then
      return jsonb_build_object('ok', false, 'error', 'pass_paused',
        'until', to_char((last_ns + interval '3 days') at time zone 'Asia/Manila', 'Mon DD, HH12:MI AM'));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'name', p->>'name', 'unli', unli,
    'left', case when unli then null else n_sessions - used - 1 end, 'validTo', v_exp);
end $$;
revoke all on function public.fw__pkg(text, text, boolean) from public, anon, authenticated;

-- Member booking: pass holders are confirmed right away with no payment.
create or replace function public.fw_member_book(p_no text, p_mobile text, p_session text, p_pay_ref text default null, p_proof_path text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare a jsonb; cfg public.fw_booking_config; s jsonb; v_valid text; r text; pk jsonb; v_free boolean;
begin
  a := public.fw__auth(p_no, p_mobile);
  if not (a->>'ok')::boolean then return a; end if;
  select * into cfg from public.fw_booking_config where id = 1;
  if not cfg.open then return jsonb_build_object('ok', false, 'error', 'paused'); end if;
  if length(coalesce(p_pay_ref,'')) > 80 then return jsonb_build_object('ok', false, 'error', 'bad_details'); end if;
  if p_proof_path is not null and (left(p_proof_path, length(cfg.owner::text)+1) <> cfg.owner::text || '/' or length(p_proof_path) > 200) then
    return jsonb_build_object('ok', false, 'error', 'bad_details');
  end if;
  perform pg_advisory_xact_lock(hashtext('fwbook:' || coalesce(p_session,'')));
  perform pg_advisory_xact_lock(hashtext('fwpkg:' || (a->'member'->>'id')));
  select x into s from jsonb_array_elements(public.fw__sessions(a->'member'->>'id')) x where x->>'id' = p_session;
  if s is null then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;
  if s->>'mine' is not null or (s->>'checked_in')::boolean then return jsonb_build_object('ok', false, 'error', 'already'); end if;
  if not (s->>'open')::boolean then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if (s->>'taken')::int >= (s->>'capacity')::int then return jsonb_build_object('ok', false, 'error', 'full'); end if;
  v_valid := a->'member'->>'validUntil';
  if v_valid ~ '^\d{4}-\d{2}-\d{2}$' and v_valid::date < (s->>'date')::date then
    return jsonb_build_object('ok', false, 'error', 'expires_before');
  end if;
  v_free := coalesce((s->>'free')::boolean,false);
  if not v_free then
    pk := public.fw__pkg(a->'member'->>'id', p_session);
    if pk is not null and not (pk->>'ok')::boolean then return pk; end if;
  end if;
  r := 'BK-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
  insert into public.fw_bookings (ref, owner, class_id, class_name, starts_at, name, contact, email, member_no, member_id, is_member, pay_ref, proof_path, agreed_at, pay_method, status, amount, note)
  values (r, cfg.owner, p_session, s->>'class', ((s->>'date')::date + (s->>'time')::time) at time zone 'Asia/Manila',
          a->'member'->>'name', coalesce(nullif(a->'member'->>'contact',''),'-'), nullif(a->'member'->>'email',''),
          a->'member'->>'memberNo', a->'member'->>'id', true, nullif(btrim(coalesce(p_pay_ref,'')),''), p_proof_path, now(),
          case when v_free then 'free' when pk is not null then 'package' else 'online' end,
          case when v_free or pk is not null then 'confirmed' else 'pending' end,
          case when v_free then 0 end,
          case when pk is not null then 'Pass: ' || (pk->>'name') end);
  return jsonb_build_object('ok', true, 'ref', r, 'payNote', cfg.pay_note, 'free', v_free,
    'pkg', pk is not null, 'pass', pk);
end $function$;

-- Guest booking: optional pass code (non-members with a package).
drop function if exists public.fw_guest_book(text, text, text, text, text, boolean);
create or replace function public.fw_guest_book(p_session text, p_name text, p_mobile text, p_email text, p_fb text, p_agreed boolean, p_code text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare cfg public.fw_booking_config; s jsonb; r text; v_m text; v_name text; v_email text; v_fb text; v_code text; pm jsonb; pk jsonb; v_free boolean;
begin
  select * into cfg from public.fw_booking_config where id = 1;
  if not cfg.open then return jsonb_build_object('ok', false, 'error', 'paused'); end if;
  if p_agreed is not true then return jsonb_build_object('ok', false, 'error', 'not_agreed'); end if;
  v_name := btrim(coalesce(p_name,'')); v_email := btrim(coalesce(p_email,'')); v_fb := btrim(coalesce(p_fb,''));
  v_m := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  v_code := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  if length(v_name) < 2 or length(v_name) > 80 or length(v_m) < 10 or length(v_m) > 13 or length(v_fb) < 2 or length(v_fb) > 80
     or length(v_email) > 120 or v_email = '' or (v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') or length(v_code) > 20 then
    return jsonb_build_object('ok', false, 'error', 'bad_details');
  end if;
  if v_code <> '' then
    if (select count(*) from public.fw_login_attempts where member_no = 'CODE:' || right(v_m,10) and at > now() - interval '15 minutes') >= 8 then
      return jsonb_build_object('ok', false, 'error', 'locked');
    end if;
    select x into pm from public.fw_studio_state st, jsonb_array_elements(coalesce(st.data->'members','[]'::jsonb)) x
     where st.owner = cfg.owner and upper(coalesce(x->>'passCode','')) = v_code
       and right(regexp_replace(coalesce(x->>'contact',''), '\D', '', 'g'), 10) = right(v_m, 10)
     limit 1;
    if pm is null then
      insert into public.fw_login_attempts (member_no) values ('CODE:' || right(v_m,10));
      return jsonb_build_object('ok', false, 'error', 'bad_code');
    end if;
  end if;
  if (select count(*) from public.fw_bookings where owner = cfg.owner and not is_member and created_at > now() - interval '10 minutes') >= 30 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  if pm is null and (select count(*) from public.fw_bookings where owner = cfg.owner and not is_member and status in ('pending','confirmed')
        and right(regexp_replace(contact,'\D','','g'),10) = right(v_m,10) and starts_at > now()) >= 3 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;
  perform pg_advisory_xact_lock(hashtext('fwbook:' || coalesce(p_session,'')));
  if pm is not null then perform pg_advisory_xact_lock(hashtext('fwpkg:' || (pm->>'id'))); end if;
  select x into s from jsonb_array_elements(public.fw_public_schedule()->'sessions') x where x->>'id' = p_session;
  if s is null then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;
  if (s->>'guest_soon')::boolean then return jsonb_build_object('ok', false, 'error', 'members_only', 'opensAt', s->>'guest_opens_at'); end if;
  if not (s->>'guest_open')::boolean then return jsonb_build_object('ok', false, 'error', 'closed'); end if;
  if (s->>'taken')::int >= (s->>'capacity')::int then return jsonb_build_object('ok', false, 'error', 'full'); end if;
  if exists (select 1 from public.fw_bookings where owner = cfg.owner and class_id = p_session and status in ('pending','confirmed')
             and right(regexp_replace(contact,'\D','','g'),10) = right(v_m,10)) then
    return jsonb_build_object('ok', false, 'error', 'already');
  end if;
  v_free := coalesce((s->>'free')::boolean,false);
  if pm is not null and not v_free then
    pk := public.fw__pkg(pm->>'id', p_session);
    if pk is null then return jsonb_build_object('ok', false, 'error', 'code_not_valid'); end if;
    if not (pk->>'ok')::boolean then return pk; end if;
  end if;
  r := 'BK-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
  insert into public.fw_bookings (ref, owner, class_id, class_name, starts_at, name, contact, email, member_no, member_id, is_member, agreed_at, pay_method, note, status, amount)
  values (r, cfg.owner, p_session, s->>'class', ((s->>'date')::date + (s->>'time')::time) at time zone 'Asia/Manila',
          case when pk is not null then coalesce(nullif(pm->>'name',''), v_name) else v_name end, v_m, nullif(v_email,''), null,
          case when pk is not null then pm->>'id' end, false, now(),
          case when v_free then 'free' when pk is not null then 'package' else 'guest' end,
          case when pk is not null then 'Pass ' || v_code || ' (' || (pk->>'name') || ') · FB: ' || v_fb else 'FB: ' || v_fb end,
          case when v_free or pk is not null then 'confirmed' else 'pending' end,
          case when v_free then 0 end);
  return jsonb_build_object('ok', true, 'ref', r, 'free', v_free, 'pkg', pk is not null, 'pass', pk);
end $function$;
grant execute on function public.fw_guest_book(text, text, text, text, text, boolean, text) to anon, authenticated;

-- Member cancel: pass bookings can be cancelled up to 24 hours before class (the session goes back to the pass).
create or replace function public.fw_member_cancel(p_no text, p_mobile text, p_booking uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare a jsonb; cfg public.fw_booking_config; b public.fw_bookings;
begin
  a := public.fw__auth(p_no, p_mobile);
  if not (a->>'ok')::boolean then return a; end if;
  select * into cfg from public.fw_booking_config where id = 1;
  select * into b from public.fw_bookings where id = p_booking and member_id = a->'member'->>'id' and status in ('pending','confirmed');
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'no_booking'); end if;
  if b.pay_method = 'package' then
    if now() >= b.starts_at - interval '24 hours' then return jsonb_build_object('ok', false, 'error', 'too_late_pkg'); end if;
    update public.fw_bookings set status = 'cancelled', cancelled_by = 'member (pass)', updated_at = now() where id = b.id;
    return jsonb_build_object('ok', true);
  end if;
  -- paid bookings (confirmed, or proof/pay ref sent) are non-refundable and can't be cancelled; free classes stay cancellable
  if coalesce(b.pay_method,'') <> 'free' and (b.status = 'confirmed' or b.proof_path is not null or b.pay_ref is not null) then
    return jsonb_build_object('ok', false, 'error', 'paid_no_cancel');
  end if;
  if now() >= b.starts_at - make_interval(hours => cfg.cutoff_hours) then
    return jsonb_build_object('ok', false, 'error', 'too_late');
  end if;
  update public.fw_bookings set status = 'cancelled', cancelled_by = 'member', updated_at = now() where id = b.id;
  return jsonb_build_object('ok', true);
end $function$;

-- Member schedule: include pass status.
create or replace function public.fw_schedule(p_no text, p_mobile text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare a jsonb; cfg public.fw_booking_config; e text; u text; d text;
begin
  a := public.fw__auth(p_no, p_mobile);
  if not (a->>'ok')::boolean then return a; end if;
  select * into cfg from public.fw_booking_config where id = 1;
  e := coalesce(a->'member'->>'email','');
  if position('@' in e) > 1 then
    u := split_part(e,'@',1); d := split_part(e,'@',2);
    e := left(u, least(2, length(u))) || repeat('*', greatest(3, length(u)-2)) || '@' || d;
  else e := ''; end if;
  return jsonb_build_object('ok', true, 'member', ((a->'member') - 'contact' - 'email') || jsonb_build_object('emailMasked', e), 'open', cfg.open,
    'cutoffHours', cfg.cutoff_hours, 'payNote', cfg.pay_note, 'owner', cfg.owner,
    'sessions', public.fw__sessions(a->'member'->>'id'),
    'freeGuest', public.fw__free_guest(a->'member'->>'id'),
    'pass', public.fw__pkg(a->'member'->>'id', null, true));
end $function$;

-- Pass status lookup for non-members (code + mobile).
create or replace function public.fw_pass_status(p_code text, p_mobile text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare cfg public.fw_booking_config; v_code text; v_m text; pm jsonb; i jsonb;
begin
  select * into cfg from public.fw_booking_config where id = 1;
  v_code := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  v_m := right(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g'), 10);
  if length(v_code) < 4 or length(v_code) > 20 or length(v_m) < 10 then return jsonb_build_object('ok', false, 'error', 'bad_details'); end if;
  if (select count(*) from public.fw_login_attempts where member_no = 'CODE:' || v_m and at > now() - interval '15 minutes') >= 8 then
    return jsonb_build_object('ok', false, 'error', 'locked');
  end if;
  select x into pm from public.fw_studio_state st, jsonb_array_elements(coalesce(st.data->'members','[]'::jsonb)) x
   where st.owner = cfg.owner and upper(coalesce(x->>'passCode','')) = v_code
     and right(regexp_replace(coalesce(x->>'contact',''), '\D', '', 'g'), 10) = v_m limit 1;
  if pm is null then
    insert into public.fw_login_attempts (member_no) values ('CODE:' || v_m);
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;
  i := public.fw__pkg(pm->>'id', null, true);
  if i is null then return jsonb_build_object('ok', false, 'error', 'bad_code'); end if;
  return i || jsonb_build_object('holder', split_part(coalesce(pm->>'name',''), ' ', 1));
end $function$;
grant execute on function public.fw_pass_status(text, text) to anon, authenticated;

-- Member schedule rows: flag bookings made with a pass (so the page can allow cancelling 24h before).
create or replace function public.fw__sessions(p_member_id text)
 returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with cfg as (select * from public.fw_booking_config where id = 1),
  st as (select s.data, s.owner from public.fw_studio_state s, cfg where s.owner = cfg.owner),
  now_m as (select (now() at time zone 'Asia/Manila') as nowt),
  ses as (
    select x, (x->>'date')::date as d,
           case when coalesce(x->>'time','') ~ '^\d{1,2}:\d{2}' then left(x->>'time',5) else '00:00' end as tm
      from st, cfg, now_m, jsonb_array_elements(coalesce(st.data->'sessions','[]'::jsonb)) x
     where coalesce(x->>'date','') ~ '^\d{4}-\d{2}-\d{2}$'
       and (x->>'date')::date between now_m.nowt::date and now_m.nowt::date + cfg.days_ahead and coalesce(x->>'status','') <> 'cancelled'
  ),
  act as (select b.* from public.fw_bookings b, cfg where b.owner = cfg.owner and b.status in ('pending','confirmed'))
  select coalesce(jsonb_agg(row_to_json(r)::jsonb order by r.date, r.time), '[]'::jsonb) from (
    select ses.x->>'id' as id, ses.d as date, ses.tm as time,
      coalesce((select ct->>'name' from jsonb_array_elements(st.data->'settings'->'classTypes') ct where ct->>'id' = ses.x->>'typeId'), nullif(ses.x->>'title',''), 'Class') as class,
      coalesce((select ii->>'name' from jsonb_array_elements(st.data->'settings'->'instructors') ii where ii->>'id' = ses.x->>'instructorId'), '') as coach,
      coalesce(nullif(ses.x->>'capacity','')::int, nullif(st.data->'settings'->>'capacity','')::int, 9) as capacity,
      greatest(case when ses.x->>'status' = 'full' then coalesce(nullif(ses.x->>'capacity','')::int, nullif(st.data->'settings'->>'capacity','')::int, 9) else 0 end, (select count(*) from act where act.class_id = ses.x->>'id')
      + (select count(*) from jsonb_array_elements(coalesce(ses.x->'attendees','[]'::jsonb)) aa
          where not exists (select 1 from act where act.class_id = ses.x->>'id' and act.member_id = aa->>'memberId'))) as taken,
      (select act.status from act where act.class_id = ses.x->>'id' and act.member_id = p_member_id limit 1) as mine,
      (select act.id from act where act.class_id = ses.x->>'id' and act.member_id = p_member_id limit 1) as booking_id,
      (select act.ref from act where act.class_id = ses.x->>'id' and act.member_id = p_member_id limit 1) as booking_ref,
      (select act.proof_path is not null or act.pay_ref is not null from act where act.class_id = ses.x->>'id' and act.member_id = p_member_id limit 1) as proof_sent,
      coalesce((select act.pay_method = 'package' from act where act.class_id = ses.x->>'id' and act.member_id = p_member_id limit 1), false) as pkg,
      exists (select 1 from jsonb_array_elements(coalesce(ses.x->'attendees','[]'::jsonb)) aa where aa->>'memberId' = p_member_id) as checked_in, coalesce((select coalesce((ct->>'free')::boolean,false) or coalesce(ct->>'name','') ~* '^free\y' from jsonb_array_elements(st.data->'settings'->'classTypes') ct where ct->>'id' = ses.x->>'typeId' limit 1), false) as free,
      (now_m.nowt < (ses.d + ses.tm::time) - make_interval(secs => 3600 * coalesce((select o.cutoff_hours from public.fw_session_overrides o where o.session_id = ses.x->>'id'), cfg.cutoff_hours))) as open
    from ses, st, cfg, now_m
  ) r
$function$;

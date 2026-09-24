-- ProteusOps — deployment-pod pipeline audit (read-mostly). Runs EVERY zero-argument selftest/verify function in the
-- pods* schemas, each in its own subtransaction (a failing one cannot hide the others), and reports per function:
--   PASS  = returned jsonb with ok=true (or a *_OK token)       FAIL = returned ok=false / *_FAIL token
--   ERROR = raised an exception (message captured)              OTHER = returned something without an ok/token
-- Safe on a disposable local DB. Do NOT run on hosted: legacy selftests may create fixture rows.
\pset pager off
\pset format unaligned
\pset fieldsep ' | '
create temp table _pod_audit(schema text, fn text, verdict text, detail text);
do $$
declare r record; v jsonb; t text; vd text; d text;
begin
  for r in
    select n.nspname s, p.proname f, p.proretset rs
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname like 'pods%' and p.prokind = 'f' and p.pronargs = 0
       and (p.proname like 'rpc_selftest%' or p.proname like 'rpc_verify%')
     order by 1, 2
  loop
    begin
      if r.rs then
        -- table-returning selftest: PASS only if it returns rows and EVERY row has ok=true
        execute format('select jsonb_build_object(''ok'', coalesce(bool_and((to_jsonb(x)->>''ok'')::boolean), false) and count(*) > 0, '
                       '''rows'', count(*), ''failed'', coalesce(jsonb_agg(to_jsonb(x)) filter (where (to_jsonb(x)->>''ok'') is distinct from ''true''), ''[]''::jsonb)) '
                       'from %I.%I() x', r.s, r.f) into v;
      else
        execute format('select to_jsonb(%I.%I())', r.s, r.f) into v;
      end if;
      t := coalesce(v->>'token', v->>'proof_token', '');
      if jsonb_typeof(v) = 'object' and ((v->>'ok') = 'true' or t ~ '_OK$') then vd := 'PASS';
      elsif jsonb_typeof(v) = 'object' and ((v->>'ok') = 'false' or t ~ '_FAIL') then vd := 'FAIL';
      else vd := 'OTHER'; end if;
      d := left(coalesce(nullif(t,''), v::text), 300);
    exception when others then
      vd := 'ERROR'; d := left(sqlstate || ' ' || sqlerrm, 300);
    end;
    insert into _pod_audit values (r.s, r.f, vd, d);
  end loop;
end $$;
\echo :::POD_AUDIT_SUMMARY:::
select verdict, count(*) from _pod_audit group by 1 order by 1;
\echo :::POD_AUDIT_NON_PASS:::
select schema, fn, verdict, detail from _pod_audit where verdict <> 'PASS' order by verdict, schema, fn;
\echo :::POD_AUDIT_PASS:::
select schema || '.' || fn from _pod_audit where verdict = 'PASS' order by 1;
\echo :::POD_AUDIT_GATE:::
select 'POD_AUDIT_TOTAL=' || count(*) || ' POD_AUDIT_NON_PASS_COUNT=' || count(*) filter (where verdict <> 'PASS') as pod_audit_gate from _pod_audit;

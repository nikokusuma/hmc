-- =====================================================================
-- JADWAL LES - bagian 2: fungsi (dipanggil aplikasi lewat RPC)
-- =====================================================================

-- ---------- format teks ----------
create or replace function public.jl_fmt_durasi(m int) returns text
language sql immutable set search_path = '' as $$
  select case when m < 60 then m || ' menit'
              when m % 60 = 0 then (m / 60) || ' jam'
              else (m / 60) || ' jam ' || (m % 60) || ' menit' end $$;

create or replace function public.jl_fmt_tanggal(d date) returns text
language sql immutable set search_path = '' as $$
  select extract(day from d)::int || ' ' ||
         (array['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'])[extract(month from d)::int]
         || ' ' || extract(year from d)::int $$;

create or replace function public.jl_nama_hari(d date) returns text
language sql immutable set search_path = '' as $$
  select (array['Senin','Selasa','Rabu','Kamis','Jumat','Sabtu','Minggu'])[extract(isodow from d)::int] $$;

create or replace function public.jl_isi(tpl text, kv jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare k text; v text; h text := coalesce(tpl, '');
begin
  for k, v in select key, value from pg_catalog.jsonb_each_text(kv) loop
    h := replace(h, '{' || k || '}', coalesce(v, ''));
  end loop;
  return h;
end $$;

-- nomor WA -> 62xxxxxxxxxx (null jika tidak valid)
create or replace function public.jl_no_wa(p text) returns text
language sql immutable set search_path = '' as $$
  select case when length(n) between 10 and 15 then n else null end
  from (
    select case when d = '' then ''
                when left(d, 1) = '0' then '62' || substr(d, 2)
                when left(d, 2) = '62' then d
                when left(d, 1) = '8' then '62' || d
                else d end as n
    from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
  ) y $$;

-- ---------- membuat sesi dari jadwal mingguan ----------
create or replace function public.jl_generate_sesi(p_dari date, p_sampai date) returns int
language plpgsql set search_path = public as $$
declare n int;
begin
  if p_sampai < p_dari then return 0; end if;
  if p_sampai - p_dari > 400 then raise exception 'Rentang tanggal terlalu panjang (maksimal 400 hari)'; end if;
  insert into public.jl_sesi (jadwal_id, siswa_id, guru_id, tanggal, jam, durasi, durasi_dasar, jenis, status)
  select j.id, j.siswa_id, j.guru_id, d::date, j.jam, j.durasi, j.durasi, 'reguler', 'terjadwal'
    from public.jl_jadwal j
    join public.jl_siswa s on s.id = j.siswa_id and s.aktif
   cross join lateral generate_series(p_dari::timestamp, p_sampai::timestamp, interval '1 day') d
   where j.aktif and extract(isodow from d)::int = j.hari and d::date >= j.mulai
  on conflict (jadwal_id, tanggal) where jenis = 'reguler' and jadwal_id is not null do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- mengakhiri jadwal (berlaku mulai p_mulai) ----------
create or replace function public.jl_akhiri_jadwal(p_id uuid, p_mulai date) returns int
language plpgsql set search_path = public as $$
declare n int;
begin
  update public.jl_jadwal set aktif = false where id = p_id;
  delete from public.jl_sesi
   where jadwal_id = p_id and jenis = 'reguler' and status = 'terjadwal' and tanggal >= p_mulai;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- ganti jadwal ----------
-- p_bagian: [{"tanggal":"2026-12-02","menit":30,"jam":"15:00"}, ...]
-- Jika siswa sudah punya sesi di tanggal itu, durasi sesi tsb ditambah (2x sesi dst).
-- Jika belum, dibuat sesi pengganti baru. Jumlah menit harus sama dengan durasi sesi asal.
create or replace function public.jl_ganti_jadwal(p_asal uuid, p_bagian jsonb, p_catatan text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  a public.jl_sesi%rowtype;
  t public.jl_sesi%rowtype;
  b jsonb; tgl date; mnt int; jm time; total int := 0; posisi text; baru uuid;
  hasil jsonb := '[]'::jsonb;
begin
  select * into a from public.jl_sesi where id = p_asal for update;
  if not found then raise exception 'Sesi tidak ditemukan'; end if;
  if a.status not in ('terjadwal','izin','sakit','alpa') then
    raise exception 'Sesi berstatus % tidak bisa diganti', a.status;
  end if;
  if p_bagian is null or jsonb_typeof(p_bagian) <> 'array' or jsonb_array_length(p_bagian) = 0 then
    raise exception 'Isi minimal satu bagian pengganti';
  end if;
  for b in select value from jsonb_array_elements(p_bagian) loop
    total := total + coalesce((b->>'menit')::int, 0);
  end loop;
  if total <> a.durasi then
    raise exception 'Total pengganti % menit, harus sama dengan durasi sesi % menit', total, a.durasi;
  end if;

  update public.jl_sesi set status = 'diganti', catatan = coalesce(nullif(p_catatan, ''), catatan) where id = a.id;

  for b in select value from jsonb_array_elements(p_bagian) loop
    tgl := (b->>'tanggal')::date;
    mnt := (b->>'menit')::int;
    jm := coalesce(nullif(b->>'jam', '')::time, a.jam);
    if mnt < 5 then raise exception 'Durasi tiap bagian minimal 5 menit'; end if;
    if tgl = a.tanggal then
      raise exception 'Tanggal pengganti tidak boleh sama dengan tanggal sesi asal (%)', a.tanggal;
    end if;
    perform public.jl_generate_sesi(tgl, tgl);

    select * into t from public.jl_sesi
     where siswa_id = a.siswa_id and tanggal = tgl and status = 'terjadwal'
     order by jam limit 1;
    if found then
      begin
        update public.jl_sesi set durasi = durasi + mnt where id = t.id;
        posisi := 'akhir';
      exception when raise_exception then
        if public.jl_menit(t.jam) < mnt then
          raise exception 'Tidak bisa menambah % menit pada %: bentrok setelah sesi dan tidak muat sebelum sesi', mnt, tgl;
        end if;
        begin
          update public.jl_sesi set jam = t.jam - make_interval(mins => mnt), durasi = durasi + mnt where id = t.id;
          posisi := 'awal';
        exception when raise_exception then
          raise exception 'Tidak bisa menambah % menit pada %: bentrok di awal maupun akhir sesi', mnt, tgl;
        end;
      end;
      insert into public.jl_penggantian (asal_sesi_id, ke_sesi_id, mode, posisi, menit)
      values (a.id, t.id, 'tambah', posisi, mnt);
      hasil := hasil || jsonb_build_object('tanggal', tgl, 'menit', mnt, 'mode', 'tambah', 'posisi', posisi, 'sesi_id', t.id);
    else
      insert into public.jl_sesi (jadwal_id, siswa_id, guru_id, tanggal, jam, durasi, durasi_dasar, jenis, status, asal_sesi_id)
      values (null, a.siswa_id, a.guru_id, tgl, jm, mnt, a.durasi_dasar, 'pengganti', 'terjadwal', a.id)
      returning id into baru;
      insert into public.jl_penggantian (asal_sesi_id, ke_sesi_id, mode, posisi, menit)
      values (a.id, baru, 'baru', null, mnt);
      hasil := hasil || jsonb_build_object('tanggal', tgl, 'menit', mnt, 'mode', 'baru', 'jam', to_char(jm, 'HH24:MI'), 'sesi_id', baru);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'bagian', hasil);
end $$;

-- ---------- batalkan penggantian ----------
create or replace function public.jl_batal_ganti(p_asal uuid) returns jsonb
language plpgsql set search_path = public as $$
declare a public.jl_sesi%rowtype; k public.jl_sesi%rowtype; l record;
begin
  select * into a from public.jl_sesi where id = p_asal for update;
  if not found or a.status <> 'diganti' then
    raise exception 'Sesi ini bukan sesi yang sudah diganti';
  end if;
  for l in select * from public.jl_penggantian where asal_sesi_id = p_asal order by created_at loop
    select * into k from public.jl_sesi where id = l.ke_sesi_id for update;
    if not found then continue; end if;
    if k.status <> 'terjadwal' then
      raise exception 'Sesi pengganti tanggal % sudah berstatus %, tidak bisa dibatalkan', k.tanggal, k.status;
    end if;
    if l.mode = 'baru' and k.durasi <= l.menit then
      delete from public.jl_sesi where id = k.id;
    else
      update public.jl_sesi
         set durasi = durasi - l.menit,
             jam = case when l.mode = 'tambah' and l.posisi = 'awal' then jam + make_interval(mins => l.menit) else jam end
       where id = k.id;
    end if;
  end loop;
  delete from public.jl_penggantian where asal_sesi_id = p_asal;
  update public.jl_sesi set status = 'terjadwal' where id = p_asal;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- token WA (disimpan di tabel rahasia, tidak bisa dibaca aplikasi) ----------
create or replace function public.jl_set_wa_token(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(btrim(p_token), '') = '' then
    delete from public.jl_rahasia where kunci = 'wa_token';
  else
    insert into public.jl_rahasia (kunci, nilai) values ('wa_token', btrim(p_token))
    on conflict (kunci) do update set nilai = excluded.nilai;
  end if;
end $$;

create or replace function public.jl_wa_token_ada() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.jl_rahasia where kunci = 'wa_token' and nilai <> '') $$;

-- ---------- kirim WA lewat gateway (Fonnte) ----------
create or replace function public.jl_wa_internal(
  p_tujuan text, p_pesan text, p_tipe text, p_siswa uuid, p_guru uuid, p_kunci text
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare tok text; no text; lid uuid; rid bigint;
begin
  select nilai into tok from public.jl_rahasia where kunci = 'wa_token';
  if coalesce(tok, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Token WhatsApp belum diisi di Pengaturan');
  end if;
  no := public.jl_no_wa(p_tujuan);
  if no is null then
    return jsonb_build_object('ok', false, 'error', 'Nomor WhatsApp tidak valid');
  end if;
  if coalesce(btrim(p_pesan), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Pesan kosong');
  end if;
  insert into public.jl_notif_log (kunci, tipe, siswa_id, guru_id, tujuan, pesan, status)
  values (p_kunci, p_tipe, p_siswa, p_guru, no, p_pesan, 'antri')
  on conflict (kunci) do nothing
  returning id into lid;
  if lid is null then
    return jsonb_build_object('ok', true, 'duplikat', true);
  end if;
  rid := net.http_post(
    url := 'https://api.fonnte.com/send',
    body := jsonb_build_object('target', no, 'message', p_pesan, 'countryCode', '62'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', tok),
    timeout_milliseconds := 15000
  );
  update public.jl_notif_log set req_id = rid where id = lid;
  return jsonb_build_object('ok', true, 'id', lid);
end $$;

create or replace function public.jl_kirim_wa(
  p_tujuan text, p_pesan text, p_tipe text default 'manual', p_siswa uuid default null, p_guru uuid default null
) returns jsonb language sql security definer set search_path = public as $$
  select public.jl_wa_internal(p_tujuan, p_pesan, coalesce(p_tipe, 'manual'), p_siswa, p_guru, null) $$;

-- ---------- sinkron status kirim (membaca balasan gateway) ----------
create or replace function public.jl_sinkron_log() returns void
language plpgsql security definer set search_path = public as $$
declare r record; j jsonb; st text;
begin
  for r in
    select l.id, h.content, h.error_msg, h.timed_out
      from public.jl_notif_log l
      join net._http_response h on h.id = l.req_id
     where l.status = 'antri'
  loop
    begin
      j := r.content::jsonb;
    exception when others then
      j := null;
    end;
    if r.timed_out or r.error_msg is not null then st := 'gagal';
    elsif j is not null and (j->>'status') = 'true' then st := 'terkirim';
    else st := 'gagal';
    end if;
    update public.jl_notif_log
       set status = st,
           respon = left(coalesce(j->>'reason', j->>'detail', r.error_msg, r.content, ''), 300)
     where id = r.id;
  end loop;
  update public.jl_notif_log set status = 'tidak_jelas'
   where status = 'antri' and created_at < now() - interval '3 hours';
end $$;

-- ---------- hak akses fungsi ----------
revoke all on function public.jl_generate_sesi(date, date) from public, anon;
revoke all on function public.jl_akhiri_jadwal(uuid, date) from public, anon;
revoke all on function public.jl_ganti_jadwal(uuid, jsonb, text) from public, anon;
revoke all on function public.jl_batal_ganti(uuid) from public, anon;
revoke all on function public.jl_set_wa_token(text) from public, anon;
revoke all on function public.jl_wa_token_ada() from public, anon;
revoke all on function public.jl_kirim_wa(text, text, text, uuid, uuid) from public, anon;
revoke all on function public.jl_wa_internal(text, text, text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.jl_sinkron_log() from public, anon, authenticated;
grant execute on function public.jl_generate_sesi(date, date) to authenticated;
grant execute on function public.jl_akhiri_jadwal(uuid, date) to authenticated;
grant execute on function public.jl_ganti_jadwal(uuid, jsonb, text) to authenticated;
grant execute on function public.jl_batal_ganti(uuid) to authenticated;
grant execute on function public.jl_set_wa_token(text) to authenticated;
grant execute on function public.jl_wa_token_ada() to authenticated;
grant execute on function public.jl_kirim_wa(text, text, text, uuid, uuid) to authenticated;

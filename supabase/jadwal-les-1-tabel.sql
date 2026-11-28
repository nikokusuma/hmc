-- =====================================================================
-- JADWAL LES - bagian 1: tabel, aturan bentrok, keamanan (RLS)
-- Semua objek berawalan jl_ . TIDAK menyentuh les_data / kv milik ver2.
-- =====================================================================
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create or replace function public.jl_menit(t time) returns int
language sql immutable set search_path = ''
as $$ select (extract(hour from t) * 60 + extract(minute from t))::int $$;

create or replace function public.jl_hari_ini() returns date
language sql stable set search_path = ''
as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

-- ---------- pengaturan (satu baris) ----------
create table public.jl_pengaturan (
  id int primary key default 1 check (id = 1),
  nama_lembaga text not null default 'Les Mandarin',
  bentrok_global boolean not null default true,      -- true: satu slot waktu hanya boleh satu siswa
  alpa_ditagih boolean not null default true,        -- alpa tetap ditagih (bayar di akhir)
  wa_otomatis boolean not null default false,        -- saklar pengiriman WA otomatis
  pengingat_menit int not null default 30 check (pengingat_menit between 5 and 240),
  reminder_hari_sebelum int not null default 1 check (reminder_hari_sebelum between 0 and 14),
  reminder_jam int not null default 17 check (reminder_jam between 0 and 23),
  reminder_ke_ortu boolean not null default true,
  tpl_les_siswa text not null default 'Halo {siswa}, pengingat jadwal les di {lembaga}: {hari}, {tanggal} pukul {jam} ({durasi}) bersama {guru}. Sampai jumpa!',
  tpl_les_guru text not null default 'Halo {guru}, pengingat mengajar {lembaga}: {siswa} pada {hari}, {tanggal} pukul {jam} ({durasi}).',
  tpl_reminder text not null default 'Halo {siswa}, pengingat {jenis} pada {hari}, {tanggal}: {ket}. Semangat belajar! - {lembaga}',
  tpl_tagihan_akhir text not null default 'Yth. orang tua/wali {siswa}, rincian les {lembaga} bulan {bulan}: {jam} jam ({pertemuan} pertemuan). Total biaya {total}. Mohon pembayarannya. Terima kasih.',
  tpl_tagihan_awal text not null default 'Yth. orang tua/wali {siswa}, bulan {bulan} telah dimulai. Mohon pembayaran les {lembaga} bulan {bulan} sebesar {total} ({pertemuan} pertemuan). Terima kasih.',
  updated_at timestamptz not null default now()
);
insert into public.jl_pengaturan (id) values (1);

-- token gateway WA: tidak bisa dibaca dari aplikasi (RLS tanpa policy)
create table public.jl_rahasia (
  kunci text primary key,
  nilai text not null
);

-- ---------- data utama ----------
create table public.jl_siswa (
  id uuid primary key default gen_random_uuid(),
  nama text not null,
  wa_siswa text,
  wa_ortu text,
  harga numeric(12,0) not null default 0 check (harga >= 0),
  harga_jenis text not null default 'per_pertemuan' check (harga_jenis in ('per_pertemuan','per_bulan')),
  bayar_jenis text not null default 'akhir' check (bayar_jenis in ('awal','akhir')),
  aktif boolean not null default true,
  catatan text,
  created_at timestamptz not null default now()
);

create table public.jl_guru (
  id uuid primary key default gen_random_uuid(),
  nama text not null,
  wa text,
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);

-- jadwal berulang mingguan. hari: 1=Senin ... 7=Minggu
create table public.jl_jadwal (
  id uuid primary key default gen_random_uuid(),
  siswa_id uuid not null references public.jl_siswa(id) on delete cascade,
  guru_id uuid not null references public.jl_guru(id) on delete restrict,
  hari smallint not null check (hari between 1 and 7),
  jam time not null,
  durasi int not null default 60 check (durasi between 15 and 480),
  mulai date not null default public.jl_hari_ini(),
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);
create index jl_jadwal_siswa_idx on public.jl_jadwal (siswa_id);
create index jl_jadwal_hari_idx on public.jl_jadwal (hari) where aktif;

-- sesi nyata per tanggal (dibuat dari jadwal, juga untuk sesi pengganti)
create table public.jl_sesi (
  id uuid primary key default gen_random_uuid(),
  jadwal_id uuid references public.jl_jadwal(id) on delete set null,
  siswa_id uuid not null references public.jl_siswa(id) on delete cascade,
  guru_id uuid not null references public.jl_guru(id) on delete restrict,
  tanggal date not null,
  jam time not null,
  durasi int not null check (durasi between 5 and 480),
  durasi_dasar int not null default 60 check (durasi_dasar > 0),  -- lama 1 pertemuan standar
  jenis text not null default 'reguler' check (jenis in ('reguler','pengganti')),
  status text not null default 'terjadwal' check (status in ('terjadwal','hadir','izin','sakit','alpa','diganti','batal')),
  asal_sesi_id uuid references public.jl_sesi(id) on delete set null,
  catatan text,
  rem_siswa_at timestamptz,
  rem_guru_at timestamptz,
  created_at timestamptz not null default now(),
  check (public.jl_menit(jam) + durasi <= 1440)
);
create unique index jl_sesi_reguler_uq on public.jl_sesi (jadwal_id, tanggal)
  where jenis = 'reguler' and jadwal_id is not null;
create index jl_sesi_tanggal_idx on public.jl_sesi (tanggal);
create index jl_sesi_siswa_tgl_idx on public.jl_sesi (siswa_id, tanggal);

-- catatan penggantian jadwal (agar bisa dibatalkan)
create table public.jl_penggantian (
  id uuid primary key default gen_random_uuid(),
  asal_sesi_id uuid not null references public.jl_sesi(id) on delete cascade,
  ke_sesi_id uuid not null references public.jl_sesi(id) on delete cascade,
  mode text not null check (mode in ('baru','tambah')),
  posisi text check (posisi in ('awal','akhir')),
  menit int not null check (menit > 0),
  created_at timestamptz not null default now()
);
create index jl_penggantian_asal_idx on public.jl_penggantian (asal_sesi_id);
create index jl_penggantian_ke_idx on public.jl_penggantian (ke_sesi_id);

-- ulangan, PR, tugas, dll
create table public.jl_reminder (
  id uuid primary key default gen_random_uuid(),
  siswa_id uuid not null references public.jl_siswa(id) on delete cascade,
  jenis text not null default 'Ulangan',
  tanggal date not null,
  keterangan text,
  selesai boolean not null default false,
  notif_at timestamptz,
  created_at timestamptz not null default now()
);
create index jl_reminder_tanggal_idx on public.jl_reminder (tanggal);

-- riwayat WA (otomatis dan manual lewat gateway)
create table public.jl_notif_log (
  id uuid primary key default gen_random_uuid(),
  kunci text unique,
  tipe text not null,
  siswa_id uuid references public.jl_siswa(id) on delete set null,
  guru_id uuid references public.jl_guru(id) on delete set null,
  tujuan text,
  pesan text,
  status text not null default 'antri' check (status in ('antri','terkirim','gagal','tidak_jelas')),
  respon text,
  req_id bigint,
  created_at timestamptz not null default now()
);
create index jl_notif_log_waktu_idx on public.jl_notif_log (created_at desc);

-- ---------- aturan bentrok jadwal mingguan ----------
create or replace function public.jl_trg_jadwal() returns trigger
language plpgsql set search_path = public as $$
declare g boolean; x record; a int; b int;
begin
  if not new.aktif then return new; end if;
  a := public.jl_menit(new.jam); b := a + new.durasi;
  if b > 1440 then raise exception 'Jam + durasi melewati tengah malam'; end if;
  select bentrok_global into g from public.jl_pengaturan where id = 1;
  g := coalesce(g, true);
  select j.jam as jam, j.durasi as durasi, si.nama as sn, gu.nama as gn into x
    from public.jl_jadwal j
    join public.jl_siswa si on si.id = j.siswa_id
    join public.jl_guru gu on gu.id = j.guru_id
   where j.aktif and j.id <> new.id and j.hari = new.hari
     and public.jl_menit(j.jam) < b and a < public.jl_menit(j.jam) + j.durasi
     and (g or j.siswa_id = new.siswa_id or j.guru_id = new.guru_id)
   limit 1;
  if found then
    raise exception 'BENTROK: % (guru %) sudah les pukul %-% pada hari yang sama',
      x.sn, x.gn, to_char(x.jam, 'HH24:MI'), to_char(x.jam + make_interval(mins => x.durasi), 'HH24:MI');
  end if;
  return new;
end $$;
create trigger jl_jadwal_bentrok before insert or update on public.jl_jadwal
  for each row execute function public.jl_trg_jadwal();

-- ---------- aturan bentrok sesi (pengganti / penambahan durasi) ----------
create or replace function public.jl_trg_sesi() returns trigger
language plpgsql set search_path = public as $$
declare g boolean; x record; a int; b int; occ text[] := array['terjadwal','hadir','alpa'];
begin
  if not (new.status = any(occ)) then return new; end if;
  if tg_op = 'INSERT' and new.jenis = 'reguler' then return new; end if;
  if tg_op = 'UPDATE' and old.status = any(occ) and new.tanggal = old.tanggal
     and new.jam = old.jam and new.durasi = old.durasi and new.guru_id = old.guru_id then
    return new;
  end if;
  a := public.jl_menit(new.jam); b := a + new.durasi;
  if b > 1440 then raise exception 'Jam + durasi melewati tengah malam'; end if;
  select bentrok_global into g from public.jl_pengaturan where id = 1;
  g := coalesce(g, true);
  select s.jam as jam, s.durasi as durasi, si.nama as sn, gu.nama as gn into x
    from public.jl_sesi s
    join public.jl_siswa si on si.id = s.siswa_id
    join public.jl_guru gu on gu.id = s.guru_id
   where s.id <> new.id and s.tanggal = new.tanggal and s.status = any(occ)
     and public.jl_menit(s.jam) < b and a < public.jl_menit(s.jam) + s.durasi
     and (g or s.siswa_id = new.siswa_id or s.guru_id = new.guru_id)
   limit 1;
  if found then
    raise exception 'BENTROK: % (guru %) sudah les pukul %-% pada %',
      x.sn, x.gn, to_char(x.jam, 'HH24:MI'), to_char(x.jam + make_interval(mins => x.durasi), 'HH24:MI'), new.tanggal;
  end if;
  return new;
end $$;
create trigger jl_sesi_bentrok before insert or update on public.jl_sesi
  for each row execute function public.jl_trg_sesi();

-- siswa dinonaktifkan: sesi terjadwal setelah hari ini dihapus
create or replace function public.jl_trg_siswa_nonaktif() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.aktif and not new.aktif then
    delete from public.jl_sesi
     where siswa_id = new.id and status = 'terjadwal' and tanggal > public.jl_hari_ini();
  end if;
  return new;
end $$;
create trigger jl_siswa_nonaktif after update of aktif on public.jl_siswa
  for each row execute function public.jl_trg_siswa_nonaktif();

-- ---------- keamanan: hanya pengguna yang sudah login ----------
do $$
declare t text;
begin
  foreach t in array array['jl_pengaturan','jl_siswa','jl_guru','jl_jadwal','jl_sesi','jl_penggantian','jl_reminder'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "akses_login" on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

alter table public.jl_notif_log enable row level security;
create policy "baca_login" on public.jl_notif_log for select to authenticated using (true);

alter table public.jl_rahasia enable row level security;   -- sengaja tanpa policy
revoke all on public.jl_rahasia from anon, authenticated;
revoke all on public.jl_notif_log from anon;

-- =====================================================================
-- JADWAL LES - bagian 4: ubah jadwal (atomik) dan penjaga riwayat sesi
-- =====================================================================

-- sesi dibuat dari jadwal aktif. Jangan membuat sesi ganda untuk tanggal yang sudah
-- punya catatan (izin, diganti, batal) dari jadwal lama di hari yang sama.
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
     and not exists (
       select 1 from public.jl_sesi o
         join public.jl_jadwal oj on oj.id = o.jadwal_id
        where o.siswa_id = j.siswa_id and o.tanggal = d::date and o.jenis = 'reguler'
          and not oj.aktif and oj.hari = j.hari and o.status <> 'terjadwal')
  on conflict (jadwal_id, tanggal) where jenis = 'reguler' and jadwal_id is not null do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- mengakhiri jadwal mulai p_mulai. Sesi yang sudah lewat dicatat dulu agar riwayat dan laporan tidak hilang.
create or replace function public.jl_akhiri_jadwal(p_id uuid, p_mulai date) returns int
language plpgsql set search_path = public as $$
declare n int; j public.jl_jadwal%rowtype; dari date;
begin
  select * into j from public.jl_jadwal where id = p_id;
  if not found then return 0; end if;
  dari := greatest(j.mulai, public.jl_hari_ini() - 92);
  if j.aktif and p_mulai - 1 >= dari then
    perform public.jl_generate_sesi(dari, p_mulai - 1);
  end if;
  update public.jl_jadwal set aktif = false where id = p_id;
  delete from public.jl_sesi
   where jadwal_id = p_id and jenis = 'reguler' and status = 'terjadwal' and tanggal >= p_mulai;
  get diagnostics n = row_count;
  return n;
end $$;

-- ubah satu jadwal mingguan: yang lama berakhir, yang baru berlaku mulai p_mulai (minimal besok)
create or replace function public.jl_ubah_jadwal(
  p_id uuid, p_guru uuid, p_hari int, p_jam time, p_durasi int, p_mulai date
) returns uuid language plpgsql set search_path = public as $$
declare o public.jl_jadwal%rowtype; nid uuid; mulai date := greatest(p_mulai, public.jl_hari_ini() + 1);
begin
  select * into o from public.jl_jadwal where id = p_id and aktif for update;
  if not found then raise exception 'Jadwal tidak ditemukan atau sudah tidak aktif'; end if;
  perform public.jl_akhiri_jadwal(p_id, mulai);
  insert into public.jl_jadwal (siswa_id, guru_id, hari, jam, durasi, mulai)
  values (o.siswa_id, p_guru, p_hari, p_jam, p_durasi, mulai)
  returning id into nid;
  return nid;
end $$;

-- siswa dinonaktifkan: catat dulu sesi yang sudah lewat, lalu hapus sesi terjadwal setelah hari ini
create or replace function public.jl_trg_siswa_nonaktif() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.aktif and not new.aktif then
    perform public.jl_generate_sesi(public.jl_hari_ini() - 92, public.jl_hari_ini());
    delete from public.jl_sesi
     where siswa_id = new.id and status = 'terjadwal' and tanggal > public.jl_hari_ini();
  end if;
  return new;
end $$;
drop trigger if exists jl_siswa_nonaktif on public.jl_siswa;
create trigger jl_siswa_nonaktif before update of aktif on public.jl_siswa
  for each row execute function public.jl_trg_siswa_nonaktif();

revoke all on function public.jl_ubah_jadwal(uuid, uuid, int, time, int, date) from public, anon;
grant execute on function public.jl_ubah_jadwal(uuid, uuid, int, time, int, date) to authenticated;

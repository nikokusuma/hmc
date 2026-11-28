-- =====================================================================
-- JADWAL LES - bagian 3: pengingat WA otomatis (dijalankan pg_cron tiap menit)
-- Hanya bekerja bila: Pengaturan > "WA otomatis" aktif DAN token Fonnte sudah diisi.
-- =====================================================================
create or replace function public.jl_kirim_pengingat() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.jl_pengaturan%rowtype;
  sekarang timestamp := (now() at time zone 'Asia/Jakarta');
  r record; kv jsonb;
begin
  perform public.jl_sinkron_log();
  select * into c from public.jl_pengaturan where id = 1;
  if not found or not c.wa_otomatis then return; end if;
  if not public.jl_wa_token_ada() then return; end if;

  perform public.jl_generate_sesi(sekarang::date, sekarang::date + 1);

  -- A) pengingat les: N menit sebelum jam mulai, ke WA siswa dan WA guru pengajar
  for r in
    select s.id, s.tanggal, s.jam, s.durasi, s.siswa_id, s.guru_id, s.rem_siswa_at, s.rem_guru_at,
           si.nama as sn, si.wa_siswa, g.nama as gn, g.wa as wa_guru
      from public.jl_sesi s
      join public.jl_siswa si on si.id = s.siswa_id
      join public.jl_guru g on g.id = s.guru_id
     where s.status = 'terjadwal' and si.aktif
       and s.tanggal between sekarang::date and sekarang::date + 1
       and (s.tanggal + s.jam) > sekarang
       and (s.tanggal + s.jam) <= sekarang + make_interval(mins => c.pengingat_menit)
       and (s.rem_siswa_at is null or s.rem_guru_at is null)
  loop
    kv := jsonb_build_object(
      'siswa', r.sn, 'guru', r.gn, 'hari', public.jl_nama_hari(r.tanggal),
      'tanggal', public.jl_fmt_tanggal(r.tanggal), 'jam', to_char(r.jam, 'HH24:MI'),
      'durasi', public.jl_fmt_durasi(r.durasi), 'lembaga', c.nama_lembaga);
    if r.rem_siswa_at is null then
      update public.jl_sesi set rem_siswa_at = now() where id = r.id;
      if public.jl_no_wa(r.wa_siswa) is not null then
        perform public.jl_wa_internal(r.wa_siswa, public.jl_isi(c.tpl_les_siswa, kv),
                                      'les_siswa', r.siswa_id, r.guru_id, 'les:' || r.id || ':siswa');
      end if;
    end if;
    if r.rem_guru_at is null then
      update public.jl_sesi set rem_guru_at = now() where id = r.id;
      if public.jl_no_wa(r.wa_guru) is not null then
        perform public.jl_wa_internal(r.wa_guru, public.jl_isi(c.tpl_les_guru, kv),
                                      'les_guru', r.siswa_id, r.guru_id, 'les:' || r.id || ':guru');
      end if;
    end if;
  end loop;

  -- B) reminder ulangan / PR / tugas: H-n pada jam yang ditentukan
  for r in
    select rm.id, rm.siswa_id, rm.jenis, rm.tanggal, rm.keterangan,
           si.nama as sn, si.wa_siswa, si.wa_ortu
      from public.jl_reminder rm
      join public.jl_siswa si on si.id = rm.siswa_id
     where not rm.selesai and rm.notif_at is null and si.aktif
       and rm.tanggal >= sekarang::date
       and (rm.tanggal - sekarang::date) <= c.reminder_hari_sebelum
       and ((rm.tanggal - sekarang::date) < c.reminder_hari_sebelum
            or extract(hour from sekarang) >= c.reminder_jam)
  loop
    kv := jsonb_build_object(
      'siswa', r.sn, 'jenis', r.jenis, 'hari', public.jl_nama_hari(r.tanggal),
      'tanggal', public.jl_fmt_tanggal(r.tanggal), 'ket', coalesce(nullif(r.keterangan, ''), '-'),
      'lembaga', c.nama_lembaga);
    update public.jl_reminder set notif_at = now() where id = r.id;
    if public.jl_no_wa(r.wa_siswa) is not null then
      perform public.jl_wa_internal(r.wa_siswa, public.jl_isi(c.tpl_reminder, kv),
                                    'reminder', r.siswa_id, null, 'rem:' || r.id || ':siswa');
    end if;
    if c.reminder_ke_ortu and public.jl_no_wa(r.wa_ortu) is not null then
      perform public.jl_wa_internal(r.wa_ortu,
                                    'Info untuk orang tua/wali. ' || public.jl_isi(c.tpl_reminder, kv),
                                    'reminder', r.siswa_id, null, 'rem:' || r.id || ':ortu');
    end if;
  end loop;
end $$;

revoke all on function public.jl_kirim_pengingat() from public, anon, authenticated;

-- jadwalkan tiap menit (aman dijalankan ulang)
select cron.unschedule(jobid) from cron.job where jobname = 'jl-pengingat';
select cron.schedule('jl-pengingat', '* * * * *', 'select public.jl_kirim_pengingat()');

# Jadwal Les

Aplikasi jadwal les satu file (`index.html`) yang terhubung ke Supabase. Bisa dibuka lewat browser, dipasang sebagai aplikasi dari browser (PWA), atau dipasang sebagai APK Android. Tampilan dan datanya sama karena semuanya memakai `index.html` dan database yang sama.

Folder `ver2/` adalah aplikasi lama dan tidak diubah. Aplikasi ini memakai tabel baru berawalan `jl_` di project Supabase yang sama, jadi data `ver2` tidak tersentuh.

## Menu
- **Siswa**: nama, WA siswa, WA orang tua, harga per pertemuan atau per bulan, bayar di awal atau di akhir.
- **Guru**: nama dan WA guru.
- **Jadwal les**: satu siswa bisa langsung diberi beberapa hari dan jam. Sistem menolak jadwal yang bentrok.
- **Reminder**: ulangan, PR, tugas, dan sejenisnya per siswa dengan tanggal dan keterangan.
- **Cek jadwal**: jadwal per hari, absensi, ganti jadwal (digabung ke hari yang sudah ada sesi, atau dibagi ke beberapa hari), dan log notifikasi.
- **Laporan**: jam pertemuan per bulan, biaya (bayar di akhir), tombol kirim tagihan, dan pengingat bayar (bayar di awal).
- **Pengaturan**: nama lembaga, aturan bentrok, tagihan alpa, templat pesan, token Fonnte.

## Pertama kali dipakai
1. Buka alamat GitHub Pages repo ini. Login memakai akun yang sama dengan `ver2`.
2. Isi guru, siswa, lalu jadwal les. Sesi dibuat otomatis dari jadwal mingguan.
3. Untuk WA otomatis: daftar di [Fonnte](https://fonnte.com), sambungkan nomor pengirim, lalu tempel token di **Pengaturan** dan nyalakan **WA otomatis**. Klik **Kirim pesan tes** dulu. Pengingat dikirim 30 menit sebelum les ke siswa dan guru, tiap menit dicek oleh pg_cron di Supabase, jadi tetap jalan walau aplikasi tertutup.
4. Tanpa token, tombol kirim di aplikasi membuka WhatsApp dengan pesan yang sudah terisi (kirim manual).

## Berkas SQL
Folder `supabase/` berisi salinan migrasi yang sudah dijalankan di Supabase (tabel, fungsi, pengingat otomatis, ubah jadwal). Jalankan berurutan 1 sampai 4 bila membuat project baru.

## APK Android
Workflow `.github/workflows/build-apk.yml` membuat APK dengan Capacitor.
- Otomatis jalan saat `index.html` atau folder `apk/` berubah di `main`, atau jalankan manual dari tab **Actions → Build APK → Run workflow**.
- Hasilnya ada di **Releases → Jadwal Les (APK terbaru)**, berkas `JadwalLes.apk`. Pasang di HP (izinkan pemasangan dari sumber lain).
- APK memuat salinan `index.html` saat dibuat. Bila `index.html` berubah, build ulang lalu pasang APK baru.
- Kunci tanda tangan dibuat baru tiap build, sehingga memasang di atas versi lama bisa gagal. Hapus aplikasi lama dulu (data aman di Supabase, cukup login ulang). Agar bisa langsung menimpa, simpan `debug.keystore` sebagai secret `ANDROID_DEBUG_KEYSTORE_BASE64`.

# Sistem Les Mandarin

Tanpa dependensi. Jalankan lokal: `node server.js` lalu buka http://localhost:3000

Login awal: `admin` / `admin123` (ubah lewat env `ADMIN_USER`, `ADMIN_PASS` sebelum pertama kali jalan).
Password buka-kunci lunas: `hmc` (ubah lewat env `UNLOCK_PASS`).

## Online (contoh Render.com)
1. Upload folder ini ke GitHub.
2. Render -> New Web Service -> pilih repo. Build command kosong, Start command `node server.js`.
3. Environment: `ADMIN_USER`, `ADMIN_PASS`, `UNLOCK_PASS`, dan `DATA_DIR=/data`.
4. Tambahkan Persistent Disk (mount path `/data`) agar data tidak hilang saat restart.

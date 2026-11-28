"""Pasang ikon aplikasi ke proyek Android hasil `npx cap add android`.
Pemakaian: python3 ikon.py ../icon-512.png android
"""
import os, sys
from PIL import Image

sumber, android = sys.argv[1], sys.argv[2]
res = os.path.join(android, 'app', 'src', 'main', 'res')
img = Image.open(sumber).convert('RGBA')
ukuran = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}

for dens, px in ukuran.items():
    d = os.path.join(res, 'mipmap-' + dens)
    os.makedirs(d, exist_ok=True)
    kecil = img.resize((px, px), Image.LANCZOS)
    for nama in ('ic_launcher.png', 'ic_launcher_round.png', 'ic_launcher_foreground.png'):
        kecil.save(os.path.join(d, nama))

# Ikon adaptif bawaan memakai XML; hapus agar PNG di atas yang dipakai di semua versi Android.
anydpi = os.path.join(res, 'mipmap-anydpi-v26')
if os.path.isdir(anydpi):
    for f in os.listdir(anydpi):
        os.remove(os.path.join(anydpi, f))
    os.rmdir(anydpi)
print('Ikon terpasang')

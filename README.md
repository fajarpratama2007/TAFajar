# EMS Dashboard (Vercel + Supabase)

Dashboard web untuk sistem EMS (HHO/PV/baterai) yang bisa diakses dari mana saja,
tanpa harus satu jaringan dengan ESP32.

```
ESP32 --HTTPS--> Supabase (Postgres + Auth + Realtime) <--- halaman web di Vercel (login)
   ^                                                            |
   +---------- ESP32 mengambil perintah dari tabel commands <---+
```

## Isi repo

| File | Fungsi |
|---|---|
| `index.html` | Dashboard: login, kartu sensor, grafik histori, toggle polaritas, unduh CSV |
| `config.js` | URL Supabase, kunci anon, ID perangkat |
| `supabase/schema.sql` | Tabel, aturan keamanan (RLS), fungsi, dan Realtime |

## 1. Siapkan Supabase

1. Buat project di <https://supabase.com>.
2. **SQL Editor** → tempel isi `supabase/schema.sql` → **Run**.
3. **Authentication → Users → Add user** (centang *Auto Confirm User*), buat dua akun:
   - akun untukmu (admin, dipakai login di web),
   - akun perangkat (dipakai ESP32).
4. Kembali ke SQL Editor, jalankan dua `insert into public.app_users ...` yang ada
   (dikomentari) di bagian bawah `schema.sql` setelah mengganti email-nya.
5. **Project Settings → API**: salin `Project URL` dan kunci **anon public**.

> Jangan pernah memakai atau membagikan kunci `service_role` di web atau ESP32.
> Kunci `anon` boleh publik karena akses dibatasi aturan RLS di database.

## 2. Isi `config.js`

```js
window.EMS_CONFIG = {
  SUPABASE_URL: 'https://xxxx.supabase.co',
  SUPABASE_ANON_KEY: 'eyJ...anon...',
  DEVICE_ID: 'ems-01'
};
```

## 3. Deploy ke Vercel

1. Push repo ini ke GitHub.
2. <https://vercel.com> → **Add New → Project** → import repo.
3. Framework Preset: **Other**. Build command dan output directory dikosongkan
   (situs statis). Klik **Deploy**.
4. Buka URL Vercel, login dengan akun admin.

Setiap `git push` ke branch utama akan otomatis men-deploy ulang.

## Cara kerja perintah polaritas

- Tombol menulis baris ke tabel `commands` (status `pending`).
- ESP32 mengambil perintah tiap ±2 detik lewat fungsi `next_command`, menjalankan urutan
  aman (cut 3 detik → ganti relay → sambung), lalu menandai `done` atau `rejected`.
- Hanya satu perintah `pending` per perangkat, dan perintah > 30 detik otomatis kedaluwarsa.
- Halaman menandai perangkat **offline** bila tidak ada update > 12 detik, dan toggle dikunci.

## Catatan

- Firmware ESP32 (pengirim data) ada di repo terpisah dan tidak termasuk di sini.
- Histori tersimpan di tabel `telemetry`. Hapus otomatis > 30 hari bisa diaktifkan
  lewat `pg_cron` (contoh ada di `schema.sql`).
- Project Supabase gratis dijeda bila tidak aktif seminggu; selama ESP32 mengirim data
  ini tidak terjadi.

# EMS Dashboard (Vercel + Supabase)

Dashboard web untuk sistem EMS (HHO/PV/baterai) yang bisa diakses dari mana saja,
tanpa harus satu jaringan dengan ESP32. **Tanpa login**: siapa pun yang punya link bisa
melihat data dan mengirim perintah polaritas (lihat bagian Keamanan).

```
ESP32 --HTTPS--> Supabase (Postgres + Realtime) <--- halaman web di Vercel
   ^                                                      |
   +---- ESP32 mengambil perintah dari tabel commands <---+
```

## Isi repo

| File | Fungsi |
|---|---|
| `index.html` | Dashboard: kartu sensor, grafik histori, toggle polaritas, unduh CSV |
| `config.js` | URL Supabase, kunci anon, ID perangkat |
| `supabase/schema.sql` | Tabel, aturan RLS, fungsi untuk ESP32, dan Realtime |

## 1. Siapkan Supabase

1. Buat project di <https://supabase.com>.
2. **SQL Editor** → tempel seluruh isi `supabase/schema.sql` → **Run**.
3. Daftarkan rahasia perangkat (sekali). Buat rahasia acak yang panjang, simpan di
   `secrets.h` ESP32 sebagai `DEVICE_SECRET`, lalu jalankan di SQL Editor
   (hanya hash-nya yang disimpan di database):

   ```sql
   insert into public.device_secrets (device_id, secret_hash)
   values ('ems-01', encode(extensions.digest('RAHASIA_PERANGKAT_ANDA', 'sha256'), 'hex'))
   on conflict (device_id) do update set secret_hash = excluded.secret_hash;
   ```
4. **Project Settings → API**: salin `Project URL` dan kunci **anon public**.

> Jangan pernah memakai atau membagikan kunci `service_role` di web atau ESP32.

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

Setiap `git push` ke branch utama akan otomatis men-deploy ulang.

## Cara kerja

- **Web** memakai kunci anon: hanya boleh **membaca** `device_state`, `telemetry`,
  `commands`, dan **menambah** perintah polaritas (0/1). Tidak bisa menulis data sensor.
- **ESP32** menulis lewat fungsi `device_push`, `device_next_command`, `device_ack_command`
  yang mewajibkan rahasia perangkat, jadi data tidak bisa dipalsukan dari luar.
- Perintah polaritas: web menulis baris `commands` (status `pending`) → ESP32 mengambilnya
  tiap ±2 detik → menjalankan urutan aman (cut 3 detik → ganti relay → sambung) → menandai
  `done` / `rejected`.
- Satu perintah `pending` per perangkat, jeda minimal 10 detik antar perintah, dan perintah
  > 30 detik otomatis kedaluwarsa.
- Halaman menandai perangkat **offline** bila tidak ada update > 12 detik, dan toggle dikunci.

## Keamanan (tanpa login)

Karena tidak ada login, **siapa pun yang tahu URL web dan kunci anon** (kunci anon terlihat
di `config.js`) dapat mengirim perintah polaritas. Batasannya:

- hanya perintah polaritas 0/1 yang diterima;
- jeda 10 detik antar perintah, perintah kedaluwarsa 30 detik;
- ESP32 tetap menjalankan interlock lokal (cut 3 detik, ditolak saat trip / sensor error).

Jangan sebarkan link web secara luas. Kalau nanti perlu dibatasi, tambahkan PIN sederhana
atau Supabase Auth.

## Catatan

- Firmware ESP32 ada di repo terpisah dan tidak termasuk di sini.
- Hapus otomatis histori > 30 hari bisa diaktifkan lewat `pg_cron` (contoh di `schema.sql`).
- Project Supabase gratis dijeda bila tidak aktif seminggu; selama ESP32 mengirim data
  ini tidak terjadi.

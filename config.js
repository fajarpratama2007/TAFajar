// Konfigurasi dashboard web.
// SUPABASE_ANON_KEY memang boleh publik (dibatasi aturan RLS di database).
// JANGAN pernah menaruh kunci "service_role" di sini.
window.EMS_CONFIG = {
  SUPABASE_URL: 'https://YOUR-PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR_ANON_KEY',
  DEVICE_ID: 'ems-01'
};

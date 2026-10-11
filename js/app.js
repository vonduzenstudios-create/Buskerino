// Shared Supabase client and live board updates for all three pages.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const configured = !SUPABASE_ANON_KEY.includes('YOUR-');

export const sb = configured ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;

export const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// The audience page lives at the site root, next to display.html.
export const audienceUrl = () => new URL('./', location.href).href;

export async function call(fn, args = {}) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

// Calls onChange() now and whenever the show changes (votes, lock, played...).
export function watchShow(onChange) {
  let pending = false;
  const refresh = async () => {
    if (pending) return;
    pending = true;
    try { await onChange(); } catch (e) { console.error(e); } finally { pending = false; }
  };
  sb.channel('show')
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'show_state' }, refresh)
    .subscribe();
  // Safety net in case the live connection drops (phones sleeping, bad venue Wi-Fi).
  setInterval(refresh, 15000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  refresh();
}

export function showSetupNeeded() {
  document.body.innerHTML = `<div style="padding:24px;font-family:system-ui;color:#f4f0ff">
    <h2>Almost there</h2><p>Add your Supabase URL and anon key to <code>js/config.js</code>. See the README for the steps.</p></div>`;
}

import { createClient } from '@supabase/supabase-js';
const url = process.env.REACT_APP_SUPABASE_URL;
const key = process.env.REACT_APP_SUPABASE_PUBLISHABLE_KEY;
export const isConfigured = Boolean(url && key);
export const supabase = isConfigured ? createClient(url, key) : null;
export function getSupabase() {
  if (!supabase) throw new Error('Le service est en cours de configuration. Réessayez plus tard.');
  return supabase;
}
export const isAdmin = user => user?.app_metadata?.role === 'admin';

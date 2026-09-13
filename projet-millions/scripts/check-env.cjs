process.env.NODE_ENV = 'production';
// Load exactly the same precedence as the subsequent Create React App build.
require('react-scripts/config/env');
const url = process.env.REACT_APP_SUPABASE_URL || '';
const key = process.env.REACT_APP_SUPABASE_PUBLISHABLE_KEY || '';
if (!/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(url) || !key.startsWith('sb_publishable_') || /REPLACE|YOUR_PROJECT/.test(url + key)) {
  console.error('Déploiement bloqué : configurez REACT_APP_SUPABASE_URL et REACT_APP_SUPABASE_PUBLISHABLE_KEY (clé publiable uniquement).');
  process.exit(1);
}

/* global chrome, TwoHbc */
const root = document.getElementById('tasks');
const error = document.getElementById('error');
const terminal = new Set(['verified','partial','indeterminate','cancelled','expired','interaction_required']);
async function call(action, id) {
  const r = await chrome.runtime.sendMessage({ kind: 'CONTROL', action, id });
  if (!r.ok) throw new Error(r.error);
  return r.result;
}
function element(tag, text) { const el = document.createElement(tag); el.textContent = text; return el; }
function action(label, handler) {
  const b = element('button', label);
  b.addEventListener('click', async () => { b.disabled = true; error.textContent = ''; try { await handler(); await render(); } catch(e) { error.textContent = e.message; b.disabled = false; } });
  return b;
}
async function render() {
  const data = await call('LIST');
  root.replaceChildren();
  if (!data.tasks.length) root.append(element('p','Aucun transfert. Depuis le panier 2HBC, choisissez « Préparer mon panier ».'));
  for (const t of data.tasks) {
    const card = document.createElement('section');
    card.append(element('h2',TwoHbc.SUPPLIERS[t.supplier].name + ' · ' + t.count + ' référence(s)'),
      element('p',t.message));
    if (t.detail) card.append(element('p',t.detail));
    if (t.result?.lines) {
      const list = document.createElement('ul');
      for (const l of t.result.lines) list.append(element('li',l.ref + ' : attendu ' + l.expected + ', présent ' + l.actual));
      card.append(list);
    }
    card.append(action('Voir le fournisseur', () => call('FOCUS',t.id)));
    if (['awaiting_setup','awaiting_confirmation'].includes(t.state)) {
      const label = document.createElement('label');
      const check = document.createElement('input'); check.type = 'checkbox';
      label.append(check, document.createTextNode(' Je suis connecté au bon compte fournisseur et j’autorise ce test d’ajout.'));
      card.append(label);
      const run = action('Préparer automatiquement le panier', () => call('RUN',t.id));
      run.disabled = true; check.addEventListener('change', () => { run.disabled = !check.checked; });
      card.append(run);
    }
    if (!terminal.has(t.state)) card.append(action('Arrêter l’assistance', () => call('CANCEL',t.id)));
    else {
      const label = document.createElement('label'), check = document.createElement('input'); check.type = 'checkbox';
      label.append(check, document.createTextNode(' J’ai contrôlé le panier fournisseur et les éventuels ajouts.'));
      const close = action('Clore cet essai', () => call('ARCHIVE',t.id)); close.disabled = true;
      check.addEventListener('change', () => { close.disabled = !check.checked; }); card.append(label, close);
    }
    root.append(card);
  }
}
document.getElementById('settings').addEventListener('click', () => chrome.runtime.openOptionsPage());
render().catch(e => { error.textContent = e.message; });
// Refresh only when no confirmation checkbox is being edited.
setInterval(() => {
  if (!root.querySelector('input[type="checkbox"]')) render().catch(e => { error.textContent = e.message; });
}, 2500);

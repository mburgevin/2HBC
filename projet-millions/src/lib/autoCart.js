import { PROTOCOL } from './supplierTransfer';
export function extensionRequest(action, payload, timeout = 1800) {
  return new Promise((resolve, reject) => {
    const requestId = window.crypto.randomUUID();
    const origin = window.location.origin;
    let timer;
    function finish(error, result) {
      clearTimeout(timer); window.removeEventListener('message', receive);
      if (error) reject(error); else resolve(result);
    }
    function receive(event) {
      const m = event.data;
      if (event.source !== window || event.origin !== origin || !m || m.channel !== PROTOCOL ||
          m.direction !== 'extension' || m.requestId !== requestId) return;
      if (m.ok) finish(null, m.result);
      else finish(new Error(m.error || 'Transfert impossible.'));
    }
    window.addEventListener('message', receive);
    timer = setTimeout(() => finish(new Error(action === 'START'
      ? 'Réponse non reçue. Ouvrez l’extension pour vérifier la tâche avant de recommencer.'
      : 'Extension non détectée. Installez-la puis autorisez ce site dans ses réglages.')), timeout);
    window.postMessage({ channel: PROTOCOL, direction: 'app', requestId, action, payload }, origin);
  });
}

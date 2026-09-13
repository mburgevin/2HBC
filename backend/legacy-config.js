// Backend historique uniquement ; non déployé sur Vercel.
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET.length < 32) {
  throw new Error('Définir un JWT_SECRET aléatoire de 32 caractères minimum pour le backend historique.');
}
module.exports = { JWT_SECRET };

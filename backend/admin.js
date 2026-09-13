const express = require('express');
const jwt = require('jsonwebtoken');
const db = require('./database');

const router = express.Router();
const JWT_SECRET = require('./legacy-config').JWT_SECRET;

function requireAdmin(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader) return res.status(401).json({ error: 'Non authentifié' });
  const token = authHeader.split(' ')[1];
  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    if (decoded.role !== 'admin') return res.status(403).json({ error: 'Accès refusé' });
    req.user = decoded;
    next();
  } catch {
    res.status(401).json({ error: 'Token invalide' });
  }
}

router.get('/produits', requireAdmin, (req, res) => {
  const produits = db.prepare('SELECT * FROM produits ORDER BY nom_produit').all();
  res.json({ produits });
});

router.post('/prix', requireAdmin, (req, res) => {
  const { reference_fabricant, prix_rexel, prix_sonepar, prix_yesss } = req.body;
  if (!reference_fabricant) return res.status(400).json({ error: 'Référence manquante' });

  db.prepare(`
    UPDATE produits 
    SET prix_rexel = ?, prix_sonepar = ?, prix_yesss = ?, date_maj = datetime('now')
    WHERE reference_fabricant = ?
  `).run(prix_rexel, prix_sonepar, prix_yesss, reference_fabricant);

  res.json({ success: true });
});

module.exports = router;

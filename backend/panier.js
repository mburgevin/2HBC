// panier.js — Routes API panier pour 2HBC
// Adapté à la structure réelle : prix_rexel, prix_sonepar, prix_yesss dans table produits
const express = require("express");
const router = express.Router();
const jwt = require("jsonwebtoken");
const JWT_SECRET = require('./legacy-config').JWT_SECRET;

function authenticateToken(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader) return res.status(401).json({ error: "Non authentifié" });
  const token = authHeader.split(" ")[1];
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ error: "Token invalide ou expiré" });
  }
}

module.exports = (db) => {

  // GET /api/panier
  router.get("/", authenticateToken, (req, res) => {
    try {
      const articles = db.prepare(`
        SELECT
          ap.id,
          ap.quantite,
          ap.fournisseur,
          p.id AS produit_id,
          p.nom_produit AS nom,
          p.reference_fabricant AS ref_fabricant,
          p.image_rexel AS image_url,
          p.prix_rexel,
          p.prix_sonepar,
          p.prix_yesss,
          p.url_rexel,
          p.url_sonepar,
          p.url_yesss
        FROM articles_panier ap
        JOIN paniers pa ON pa.id = ap.panier_id
        JOIN produits p ON p.id = ap.produit_id
        WHERE pa.client_id = ?
        ORDER BY ap.fournisseur, ap.id
      `).all(req.user.id);

      const result = articles.map(a => {
        let prix = null;
        if (a.fournisseur === 'Rexel') prix = a.prix_rexel;
        else if (a.fournisseur === 'Sonepar') prix = a.prix_sonepar;
        else if (a.fournisseur === 'Yesss') prix = a.prix_yesss;

        // Extraire l'ID interne Rexel depuis l'URL (dernier segment après /p/)
        let rexel_product_id = null;
        let rexel_product_code = null;
        if (a.url_rexel) {
          const segs = a.url_rexel.split('/').filter(Boolean);
          const pIdx = segs.lastIndexOf('p');
          if (pIdx !== -1 && segs[pIdx + 1]) {
            rexel_product_id = segs[pIdx + 1];
            rexel_product_code = segs[pIdx - 1] || null;
          }
        }

        return {
          id: a.id,
          quantite: a.quantite,
          fournisseur: a.fournisseur || 'Non défini',
          produit_id: a.produit_id,
          nom: a.nom,
          ref_fabricant: a.ref_fabricant,
          image_url: a.image_url,
          prix,
          rexel_product_id,
          rexel_product_code,
        };
      });

      res.json(result);
    } catch (err) {
      console.error("Erreur GET panier:", err);
      res.status(500).json({ error: "Erreur serveur" });
    }
  });

  // POST /api/panier
  router.post("/", authenticateToken, (req, res) => {
    const { produit_id, quantite = 1, fournisseur = 'meilleur' } = req.body;
    if (!produit_id) return res.status(400).json({ error: "produit_id requis" });

    const produit = db.prepare("SELECT id FROM produits WHERE id = ?").get(produit_id);
    if (!produit) return res.status(400).json({ error: "Produit introuvable" });

    try {
      let panier = db.prepare("SELECT id FROM paniers WHERE client_id = ? LIMIT 1").get(req.user.id);
      if (!panier) {
        const r = db.prepare("INSERT INTO paniers (client_id) VALUES (?)").run(req.user.id);
        panier = { id: r.lastInsertRowid };
      }

      const existant = db.prepare(
        "SELECT id, quantite FROM articles_panier WHERE panier_id = ? AND produit_id = ? AND fournisseur = ?"
      ).get(panier.id, produit_id, fournisseur);

      if (existant) {
        db.prepare("UPDATE articles_panier SET quantite = ? WHERE id = ?").run(existant.quantite + quantite, existant.id);
        return res.json({ message: "Quantité mise à jour", id: existant.id, quantite: existant.quantite + quantite });
      }

      const insert = db.prepare(
        "INSERT INTO articles_panier (panier_id, produit_id, quantite, fournisseur) VALUES (?, ?, ?, ?)"
      ).run(panier.id, produit_id, quantite, fournisseur);

      res.status(201).json({ message: "Produit ajouté", id: insert.lastInsertRowid, produit_id, quantite, fournisseur });
    } catch (err) {
      console.error("Erreur POST panier:", err);
      res.status(500).json({ error: "Erreur serveur" });
    }
  });

  // PATCH /api/panier/:id
  router.patch("/:id", authenticateToken, (req, res) => {
    const { quantite } = req.body;
    const articleId = parseInt(req.params.id);
    if (!quantite || quantite < 1) return res.status(400).json({ error: "Quantité invalide" });
    try {
      const article = db.prepare(`
        SELECT ap.id FROM articles_panier ap
        JOIN paniers pa ON pa.id = ap.panier_id
        WHERE ap.id = ? AND pa.client_id = ?
      `).get(articleId, req.user.id);
      if (!article) return res.status(404).json({ error: "Article non trouvé" });
      db.prepare("UPDATE articles_panier SET quantite = ? WHERE id = ?").run(quantite, articleId);
      res.json({ message: "Quantité mise à jour", id: articleId, quantite });
    } catch (err) {
      res.status(500).json({ error: "Erreur serveur" });
    }
  });

  // DELETE /api/panier/:id
  router.delete("/:id", authenticateToken, (req, res) => {
    const articleId = parseInt(req.params.id);
    try {
      const article = db.prepare(`
        SELECT ap.id FROM articles_panier ap
        JOIN paniers pa ON pa.id = ap.panier_id
        WHERE ap.id = ? AND pa.client_id = ?
      `).get(articleId, req.user.id);
      if (!article) return res.status(404).json({ error: "Article non trouvé" });
      db.prepare("DELETE FROM articles_panier WHERE id = ?").run(articleId);
      res.json({ message: "Article supprimé", id: articleId });
    } catch (err) {
      res.status(500).json({ error: "Erreur serveur" });
    }
  });

  return router;
};

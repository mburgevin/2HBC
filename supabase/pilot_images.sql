-- Photos des trois références pilotes contrôlées sur Rexel ET Sonepar le 13 octobre 2026.
-- Enrichissement additif du champ image_url déjà présent ; aucune migration requise.
-- Les sources détaillées sont conservées dans catalog/pilot-images.json.
begin;
update public.produits set image_url='https://api.rexel.fr/media/api/fr/content/73224603/EXTRA_LARGE' where marque='Legrand' and ref_fabricant='069511L' and code_ean='3414971877986' and catalogue_verifie and image_url is null;
update public.produits set image_url='https://api.rexel.fr/media/api/fr/content/73224659/EXTRA_LARGE' where marque='Legrand' and ref_fabricant='069611L' and code_ean='3414971880092' and catalogue_verifie and image_url is null;
update public.produits set image_url='https://api.rexel.fr/media/api/fr/content/73224702/EXTRA_LARGE' where marque='Legrand' and ref_fabricant='069711L' and code_ean='3414971881778' and catalogue_verifie and image_url is null;
commit;

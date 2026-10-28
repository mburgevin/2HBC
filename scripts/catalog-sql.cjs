const fs=require('node:fs'),path=require('node:path');
const products=JSON.parse(fs.readFileSync(path.join(__dirname,'../catalog/pilot-products.json'),'utf8'));
const sql=v=>"'"+String(v).replaceAll("'","''")+"'";
const seen=new Set(),lines=['-- Sources officielles vérifiées le 11 octobre 2026. Aucun prix personnel inventé.','begin;'];
for(const p of products){
 if(!/^\d{13}$/.test(p.ean) || [...p.ean].reduce((s,n,i)=>s+Number(n)*(i%2?3:1),0)%10)throw Error('EAN13 invalide');
 const key=p.brand+':'+p.reference;if(seen.has(key))throw Error('Doublon');seen.add(key);
 lines.push(`insert into public.produits(marque,ref_fabricant,code_ean,nom,catalogue_verifie,source_catalogue,catalogue_verifie_le) values(${sql(p.brand)},${sql(p.reference)},${sql(p.ean)},${sql(p.name)},true,${sql(p.offers[0].url)},'2026-10-11T13:55:00Z') on conflict(marque,ref_fabricant) do nothing;`);
 for(const o of p.offers){
  const host={Rexel:'www.rexel.fr',Sonepar:'www.sonepar.fr'}[o.supplier];
  if(!host||new URL(o.url).hostname!==host||new URL(o.url).protocol!=='https:')throw Error('Source invalide');
  lines.push(`insert into public.fournisseurs(nom,site_web) values(${sql(o.supplier)},${sql('https://'+host)}) on conflict(nom) do nothing;`);
  lines.push(`insert into public.produits_fournisseurs(produit_id,fournisseur_id,ref_fournisseur,prix,nature_prix,conditionnement,url_produit,reference_verifiee,reference_verifiee_le) select p.id,f.id,${sql(o.reference)},null,'public',${sql(o.pack)},${sql(o.url)},true,'2026-10-11T13:55:00Z' from public.produits p cross join public.fournisseurs f where p.marque=${sql(p.brand)} and p.ref_fabricant=${sql(p.reference)} and f.nom=${sql(o.supplier)} on conflict(produit_id,fournisseur_id) do nothing;`);
 }
}
lines.push('commit;');process.stdout.write(lines.join('\n')+'\n');

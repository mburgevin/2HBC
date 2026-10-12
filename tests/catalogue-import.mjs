import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

// Données SYNTHÉTIQUES réservées aux tests, jamais appliquées au projet cloud.
function candidate(n) {
 const stem=String(200000000000+n), check=(10-[...stem].reduce((a,c,i)=>a+Number(c)*(i%2?3:1),0)%10)%10;
 return {brand:'Marque de test',reference:`00${n}`,ean:stem+check,name:n===1?"Prise d'essai \\ '); delete from produits; --":`Produit de test ${n}`,
  review_status:'pending',categories:['Catégorie de découverte'],offers:[{
   supplier:'Sonepar',reference:`000${n}`,url:`https://www.sonepar.fr/catalog/fr-fr/products/test-${n}`,
   pack:'Conditionnement à confirmer',collected_at:'2026-10-11T12:00:00Z',page_sha256:'a'.repeat(64)}]};
}
const approved=p=>({...structuredClone(p),review_status:'approved'});
const sql='select public.importer_produit_collecte($1::jsonb,$2) result';
const admin={app_metadata:{role:'admin'}};

export async function testCatalogueImport(db,t,run,A,B,real) {
 const folder=new URL('../supabase/migrations/',import.meta.url);
 const file=(await readdir(folder)).find(n=>n.endsWith('_catalogue_integrity_import.sql'));
 await db.exec(await readFile(new URL(file,folder),'utf8'));
 const count=async table=>Number((await db.query(`select count(*) n from ${table}`)).rows[0].n);
 const initial=await count('produits');
 const importAs=(p,approve=false,claims=admin,user=A)=>run(user,sql,[JSON.stringify(p),approve],claims);

 await t.test('Intégrité : EAN, doublons normalisés, preuves de vérification',async()=>{
  for(const code of ['3414971877986','03414971877986','96385074','036000291452'])
   assert.equal((await db.query('select gtin_valide($1) ok',[code])).rows[0].ok,true);
  for(const code of ['3414971877987','123456789','ABCDEFGH'])
   assert.equal((await db.query('select gtin_valide($1) ok',[code])).rows[0].ok,false);
  await assert.rejects(db.query("insert into produits(marque,ref_fabricant,nom) values(' legrand ','069511l','Doublon')"));
  await assert.rejects(db.query("insert into produits(marque,ref_fabricant,nom,code_ean) values('X','X','X','03414971877986')"));
  await assert.rejects(db.query("insert into produits(ref_fabricant,nom,catalogue_verifie) values('X','X',true)"));
  await assert.rejects(db.query("update produits_fournisseurs set reference_verifiee=true where ref_fournisseur is null"));
  await db.exec("insert into categories(nom) values('Éclairage')");
  await assert.rejects(db.query("insert into categories(nom) values(' éclairage ')"));
  assert.equal(await count('produits'),initial);
 });
 await t.test('Collecte : privé pour visiteurs/artisans, admin via app_metadata uniquement',async()=>{
  const p=candidate(1);
  await assert.rejects(run(null,sql,[JSON.stringify(p),false],{},'anon'));
  await assert.rejects(importAs(p,false,{}));
  await assert.rejects(importAs(p,false,{user_metadata:{role:'admin'}}));
  await importAs(p);
  assert.equal((await run(B,'select * from collectes_catalogue')).length,0);
  await assert.rejects(run(null,'select * from collectes_catalogue',[],{},'anon'));
  assert.equal((await run(A,'select * from collectes_catalogue',[],admin)).length,1);
  assert.equal(await count('produits'),initial);
 });
 await t.test('Validation serveur : types, prix, URL étrangères, dates et revue requise',async()=>{
  const cases=[{...candidate(2),ean:3414971877986},{...candidate(2),ean:'3414971877987'},
   {...candidate(2),price:10},{...candidate(2),categories:null},{...candidate(2),offers:[]}];
  for(const patch of [{url:'https://www.sonepar.fr.evil.test/catalog/fr-fr/products/test'},
    {url:'https://www.sonepar.fr/catalog/fr-fr/products/test?token=secret'},
    {collected_at:'2099-01-01T00:00:00Z'},{page_sha256:null},{price:10},{reference:123}]) {
   const p=candidate(2);Object.assign(p.offers[0],patch);cases.push(p);
  }
  for(const p of cases) await assert.rejects(importAs(p));
  await assert.rejects(importAs(candidate(2),true));
  assert.equal(await count('collectes_catalogue'),1);
 });
 await t.test('Parcours réel du programme : 100 JSON → SQL → préparation → publication idempotente',async()=>{
  const batch=Array.from({length:100},(_,i)=>candidate(i+1));
  // Exécute le véritable générateur Python, puis son résultat dans PostgreSQL.
  const generate=(items,approve)=>execFileSync('python3',['-c',
   'import json,sys; from scripts.prepare_catalogue_import import generate_sql; print(generate_sql(json.load(sys.stdin),sys.argv[1]=="true"))',String(approve)],
   {cwd:new URL('../',import.meta.url),input:JSON.stringify(items),encoding:'utf8'});
  const staged=generate(batch,false);await db.exec(staged);await db.exec(staged);
  assert.equal(await count('collectes_catalogue'),100);assert.equal(await count('produits'),initial);
  batch.forEach(p=>p.review_status='approved');
  const published=generate(batch,true);await db.exec(published);await db.exec(published);
  assert.equal(await count('collectes_catalogue'),100);assert.equal(await count('produits'),initial+100);
  assert.equal((await db.query("select count(*)::int n from collectes_catalogue where statut='imported'")).rows[0].n,100);
  const offer=(await db.query("select * from produits_fournisseurs where ref_fournisseur='0001'")).rows[0];
  assert.equal(offer.prix,null);assert.equal(offer.nature_prix,'public');assert.equal(offer.reference_verifiee,true);
  const p=(await run(A,'select * from rechercher_catalogue_personnel($1)',[batch[0].ean]))[0];
  assert.equal(p.nom,batch[0].name);assert.equal(p.ref_fabricant,'001');
 });
 await t.test('Conflits : EAN, référence fournisseur réutilisée, remplacement d’URL ; transaction annulée',async()=>{
  const wrongEAN=approved(candidate(1));wrongEAN.ean=candidate(101).ean;
  await assert.rejects(importAs(wrongEAN,true));
  const duplicateSKU=approved(candidate(102));duplicateSKU.offers[0].reference='0001';
  await assert.rejects(importAs(duplicateSKU,true));
  const wrongURL=approved(candidate(1));wrongURL.offers[0].url+='-autre';
  await assert.rejects(importAs(wrongURL,true));
  const sharedEAN=approved(candidate(103));sharedEAN.ean=candidate(1).ean;
  await assert.rejects(importAs(sharedEAN,true));
  assert.equal(await count('produits'),initial+100);assert.equal(await count('collectes_catalogue'),100);
  await db.exec('begin');
  try {
   await db.query(sql,[JSON.stringify(approved(candidate(104))),true]);
   await assert.rejects(db.query(sql,[JSON.stringify(duplicateSKU),true]));
  } finally { await db.exec('rollback'); }
  assert.equal(await count('produits'),initial+100);
 });
 await t.test('Réimport : tarifs existants, identifiants d’offres et prix privés restent intacts',async()=>{
  const p=approved(candidate(1));
  const before=(await db.query("select * from produits_fournisseurs where ref_fournisseur='0001'")).rows[0];
  await db.query("update produits_fournisseurs set prix=23.45,nature_prix='negocie' where id=$1",[before.id]);
  p.offers[0].page_sha256='b'.repeat(64); // Nouvelle collecte, même correspondance.
  await importAs(p,true);
  const after=(await db.query('select * from produits_fournisseurs where id=$1',[before.id])).rows[0];
  assert.equal(Number(after.prix),23.45);assert.equal(after.nature_prix,'negocie');assert.equal(after.id,before.id);
  assert.equal((await run(null,'select * from produits_fournisseurs',[],{},'anon')).length,0);
  await run(A,`insert into prix_personnels(id,client_id,offre_id,contexte_empreinte,quantite,montant_ht,base_prix,unite,source_url,observe_le,expire_le)
   values('66666666-6666-4666-8666-666666666666',$1,$2,$3,10,12.34,1,'piece',$4,now(),now()+interval '10 minutes')`,[A,real.id,'c'.repeat(64),real.url_produit]);
  assert.equal((await run(A,'select * from prix_personnels')).length,1);
  assert.equal((await run(B,'select * from prix_personnels',[],admin)).length,0);
  assert.equal((await db.query('select url_produit from produits_fournisseurs where id=$1',[real.id])).rows[0].url_produit,real.url_produit);
  assert.equal((await db.query("select count(*)::int n from pg_tables where schemaname='public' and not rowsecurity")).rows[0].n,0);
  assert.equal((await db.query("select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef")).rows[0].n,0);
 });
}

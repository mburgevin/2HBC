// Audit reproductible sur PostgreSQL embarqué ; aucun appel réseau ni écriture distante.
// Exécuter depuis le dépôt : node docs/audits/2026-10-15/local-audit.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
const root = new URL('../../../', import.meta.url);
const read = p => readFile(new URL(p, root), 'utf8');
const db = new PGlite();
const A='11111111-1111-4111-8111-111111111111', B='22222222-2222-4222-8222-222222222222';
const results=[];
async function check(name,fn){await fn();results.push({name,passed:true});}
async function rollback(fn){await db.exec('begin');try{return await fn();}finally{await db.exec('rollback');}}
async function asUser(uid,sql,params=[],extra={}) {
 return rollback(async()=>{
  await db.exec('set local role authenticated');
  await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:uid,role:'authenticated',is_anonymous:false,app_metadata:{},...extra})]);
  return (await db.query(sql,params)).rows;
 });
}
const counts=async()=> (await db.query("select (select count(*) from produits)::int products,(select count(*) from produits_fournisseurs)::int offers")).rows[0];
try {
 await db.exec(`create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
 create schema auth; create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$ select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
 create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
 grant usage on schema auth to anon,authenticated;
 grant execute on all functions in schema auth to anon,authenticated;`);
 for(const p of ['supabase/migrations/20260913161414_initial_mvp.sql','supabase/seed.sql','supabase/migrations/20261011140316_personal_supplier_prices.sql','supabase/pilot_catalog.sql','supabase/pilot_images.sql','catalog/imports/20261015/import.sql']) await db.exec(await read(p));
 await db.query('insert into auth.users values($1),($2)',[A,B]);
 await db.query('insert into clients(id) values($1),($2)',[A,B]);
 await check('Fixture identique au volume distant : 114 produits, 148 offres',async()=>assert.deepEqual(await counts(),{products:114,offers:148}));
 const real=(await db.query('select pf.*,p.marque,p.ref_fabricant,p.code_ean from produits_fournisseurs pf join produits p on p.id=pf.produit_id where reference_verifiee order by pf.id limit 1')).rows[0];
 const demo=(await db.query('select id from produits_fournisseurs where not reference_verifiee order by id limit 1')).rows[0];

 await check('Lacune actuelle : cycle de deux catégories accepté',()=>rollback(async()=>{
  const x=(await db.query("insert into categories(nom) values('Audit A') returning id")).rows[0].id;
  const y=(await db.query("insert into categories(nom,parent_id) values('Audit B',$1) returning id",[x])).rows[0].id;
  await db.query('update categories set parent_id=$1 where id=$2',[y,x]);
 }));
 await check('Lacune actuelle : doublons de catégories racines acceptés',()=>rollback(async()=>{
  await db.exec("insert into categories(nom) values('Audit'),(' audit ')");
 }));
 await check('Lacune actuelle : longueur GTIN invalide et mauvaise clé acceptées',()=>rollback(async()=>{
  await db.exec("insert into produits(marque,ref_fabricant,nom,code_ean) values('Audit','GTIN9','Audit','123456789'),('Audit','GTIN13','Audit','3414971877987')");
 }));
 await check('Lacune actuelle : EAN existant réutilisable sur une autre identité',()=>rollback(async()=>{
  await db.query("insert into produits(marque,ref_fabricant,nom,code_ean) values('Audit','EAN_DUP','Audit',$1)",[real.code_ean]);
 }));
 await check('Lacune actuelle : doublon marque/référence avec casse ou espaces accepté',()=>rollback(async()=>{
  await db.query("insert into produits(marque,ref_fabricant,nom) values($1,$2,'Audit')",[' '+real.marque.toUpperCase()+' ',real.ref_fabricant.toLowerCase()]);
 }));
 await check('Lacune actuelle : code fournisseur réutilisable pour un autre produit',()=>rollback(async()=>{
  const id=(await db.query("insert into produits(marque,ref_fabricant,nom) values('Audit','SKU_DUP','Audit') returning id")).rows[0].id;
  await db.query('insert into produits_fournisseurs(produit_id,fournisseur_id,ref_fournisseur) values($1,$2,$3)',[id,real.fournisseur_id,real.ref_fournisseur]);
 }));
 await check('Lacune actuelle : publication sans preuve de vérification acceptée',()=>rollback(async()=>{
  await db.exec("insert into produits(ref_fabricant,nom,catalogue_verifie) values('AUDIT_UNVERIFIED','Audit',true)");
 }));
 await check('Lacune actuelle : ajout RPC d’une offre de démonstration accepté',async()=>{
  const row=await asUser(A,'select ajouter_au_panier($1,1) id',[demo.id]); assert(row[0].id);
 });
 await check('Contrôle : rôle admin fourni dans user_metadata sans effet',async()=>{
  assert.equal((await asUser(A,'update produits set nom=$1 where id=$2 returning id',['Audit',real.produit_id],{user_metadata:{role:'admin'}})).length,0);
 });
 await check('Contrôle : panier et observation privés invisibles à un autre client et à un admin tiers',async()=>{
  const cart=(await db.query('insert into paniers(client_id) values($1) returning id',[A])).rows[0].id;
  await db.query('insert into articles_panier(panier_id,offre_id) values($1,$2)',[cart,real.id]);
  await db.query("insert into prix_personnels(id,client_id,offre_id,contexte_empreinte,quantite,montant_ht,base_prix,unite,source_url,observe_le,expire_le) values('33333333-3333-4333-8333-333333333333',$1,$2,$3,1,12.34,1,'piece',$4,now(),now()+interval '10 minutes')",[A,real.id,'a'.repeat(64),real.url_produit]);
  assert.equal((await asUser(A,'select * from prix_personnels')).length,1);
  assert.equal((await asUser(B,'select * from prix_personnels')).length,0);
  assert.equal((await asUser(B,'select * from prix_personnels',[],{app_metadata:{role:'admin'}})).length,0);
  assert.equal((await asUser(B,'select * from articles_panier')).length,0);
 });

 const before=(await db.query('select id,produit_id,fournisseur_id,ref_fournisseur from produits_fournisseurs order by id')).rows;
 await check('Migrations en attente applicables localement aux 100 produits importés',async()=>{
  for(const p of ['supabase/migrations/20261012163203_catalogue_integrity_import.sql','supabase/migrations/20261013131653_catalogue_images.sql']) await db.exec(await read(p));
  assert.deepEqual(await counts(),{products:114,offers:148});
  assert.deepEqual((await db.query('select id,produit_id,fournisseur_id,ref_fournisseur from produits_fournisseurs order by id')).rows,before);
 });
 await check('Après migrations : EAN invalide, doublon et publication sans preuve refusés',async()=>{
  for(const sql of [
   "insert into produits(marque,ref_fabricant,nom,code_ean) values('Audit','GTIN9','Audit','123456789')",
   "insert into produits(ref_fabricant,nom,catalogue_verifie) values('AUDIT_UNVERIFIED','Audit',true)"
  ]) await assert.rejects(db.exec(sql));
  await assert.rejects(db.query("insert into produits(marque,ref_fabricant,nom,code_ean) values('Audit','EAN_DUP','Audit',$1)",[real.code_ean]));
 });
 await check('Après migrations : la protection contre les cycles reste à ajouter',()=>rollback(async()=>{
  const x=(await db.query("insert into categories(nom) values('Audit A') returning id")).rows[0].id;
  const y=(await db.query("insert into categories(nom,parent_id) values('Audit B',$1) returning id",[x])).rows[0].id;
  await db.query('update categories set parent_id=$1 where id=$2',[y,x]);
 }));
 await check('Après migrations : les démos restent accessibles et ajoutables',async()=>{
  assert.equal((await asUser(A,'select * from produits where not catalogue_verifie')).length,11);
  assert((await asUser(A,'select ajouter_au_panier($1,1) id',[demo.id]))[0].id);
 });
 console.log(JSON.stringify({runtime:'PGlite 0.5.8',scope:'isolated local database; remote database unchanged',checks:results.length,results},null,2));
} finally {await db.close();}

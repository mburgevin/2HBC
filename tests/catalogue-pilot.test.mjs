import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {PGlite} from '@electric-sql/pglite';

const root=new URL('../',import.meta.url);
const archive=execFileSync('python3',['-c',`
import json,zipfile
from scripts.build_reviewed_pilot import build
with zipfile.ZipFile('releases/lot-pilote-20261030.zip') as z:
 source=z.read('source-products-v2.json'); manifest=json.loads(z.read('review-manifest.json'))
 pending,reviewed,report=build(source,manifest)
 assert reviewed==json.loads(z.read('products-reviewed.json'))
 try: build(source+b' ',manifest)
 except ValueError: pass
 else: raise AssertionError('Une source différente ne doit pas réutiliser la revue')
 print(json.dumps(dict(pending=pending,reviewed=reviewed,report=report)))
`],{cwd:root,encoding:'utf8',maxBuffer:5*1024*1024});
const {pending,reviewed}=JSON.parse(archive);

test('Lot réel du 28 octobre : préparation de 100 fiches puis publication de 9 références relues',async t=>{
 const db=new PGlite();
 const rows=async sql=>(await db.query(sql)).rows;
 const count=async table=>Number((await rows('select count(*) n from '+table))[0].n);
 const batch=async(products,approve,publish)=>{
  await db.exec('begin');
  try{
   for(const p of products)await db.query('select importer_catalogue_v3($1,$2,$3)',[JSON.stringify(p),approve,publish]);
   await db.exec('commit');
  }catch(e){await db.exec('rollback');throw e;}
 };
 const visible=async(role,sql)=>{
  await db.exec('begin;set local role '+role);
  try{return await rows(sql);}finally{await db.exec('rollback');}
 };
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
   create schema auth;create table auth.users(id uuid primary key);
   create function auth.uid() returns uuid language sql stable as $$select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid$$;
   create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}')$$;
   grant usage on schema auth to anon,authenticated,service_role;
   alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
   alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
   alter default privileges in schema public grant execute on functions to anon,authenticated,service_role;`);
  for(const f of (await readdir(new URL('supabase/migrations/',root))).sort())await db.exec(await readFile(new URL('supabase/migrations/'+f,root),'utf8'));
  await db.exec("insert into fournisseurs(nom) values('Rexel'),('Sonepar');");
  await t.test('Les 100 identités restent privées pendant la préparation',async()=>{
   await batch(pending,false,false);
   assert.equal(await count('produits'),0);
   assert.equal((await rows("select count(distinct donnees->>'ean')::int n from collectes_catalogue where donnees->>'schema_version'='3'"))[0].n,100);
   assert.deepEqual(await visible('authenticated','select empreinte from collectes_catalogue'),[]);
  });
  await t.test('Les 9 fiches qualifiées satisfont toutes les règles, mais restent privées',async()=>{
   await batch(reviewed,true,false);
   assert.equal(await count('produits'),9);
   assert.equal(await count('produits_fournisseurs'),16);
   assert.equal(await count('valeurs_catalogue'),81);
   assert.equal(await count('observations_attributs'),163);
   assert((await rows('select diagnostic_publication(id) d from produits')).every(r=>r.d.publiable));
   assert.deepEqual(await visible('anon','select id from produits'),[]);
  });
  await t.test('Publication publique : 6 familles, 3 univers, aucune valeur non relue',async()=>{
   await batch(reviewed,true,true);
   assert.equal((await visible('anon','select id from produits')).length,9);
   assert.equal((await visible('anon','select * from valeurs_catalogue')).length,81);
   assert.equal((await rows('select count(distinct c.id)::int families,count(distinct c.parent_id)::int roots from produits p join categories c on c.id=p.categorie_id'))[0].families,6);
   assert.equal((await rows('select count(distinct c.parent_id)::int n from produits p join categories c on c.id=p.categorie_id'))[0].n,3);
   assert.equal((await rows("select count(*)::int n from valeurs_catalogue where attribut_code in ('icn_400','icu_400','ip')"))[0].n,0);
   assert.equal((await rows("select valeur from valeurs_catalogue v join produits p on p.id=v.produit_id where p.ref_fabricant='600002' and attribut_code='fonction_commande'"))[0].valeur,'double_va_et_vient');
   assert.equal((await rows("select count(*)::int n from observations_attributs where statut='rejetee'"))[0].n,2);
   assert.equal(await count('compatibilites_produits'),1);
   assert.equal((await rows('select count(*)::int n from produits_fournisseurs where prix is not null'))[0].n,0);
  });
  await t.test('Le rejeu conserve les preuves, les valeurs et la publication, sans doublons',async()=>{
   const before=await rows('select ref_fabricant,qualification_le from produits order by ref_fabricant');
   const collections=await count('collectes_catalogue');
   await batch(pending,false,false);await batch(reviewed,true,false);
   assert.deepEqual(await rows('select ref_fabricant,qualification_le from produits order by ref_fabricant'),before);
   // Une republication explicite revérifie le diagnostic et actualise sa date.
   await batch(reviewed,true,true);
   assert.equal((await visible('anon','select id from produits')).length,9);
   assert.equal(await count('collectes_catalogue'),collections);
   assert.equal(await count('valeurs_catalogue'),81);
   assert.equal(await count('observations_attributs'),163);
  });
  await t.test('Une prise incomplète ne peut pas rejoindre le lot public',async()=>{
   const p=structuredClone(pending.find(p=>p.reference==='069731L'));p.review_status='approved';
   await assert.rejects(batch([p],true,true),/Publication refusée/);
   assert.equal(await count('produits'),9);
   assert.equal((await visible('anon','select id from produits')).length,9);
  });
 }finally{await db.close();}
});

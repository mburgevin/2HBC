import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

// PostgreSQL embarqué ; claims Auth simulés, sans appel au projet cloud.
test('Migration, catalogue et isolation des comptes', async t => {
 const db = new PGlite();
 const A='11111111-1111-4111-8111-111111111111', B='22222222-2222-4222-8222-222222222222';
 await db.exec(`create role anon nologin; create role authenticated nologin;
 create schema auth; create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$ select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
 create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
 grant usage on schema auth to anon,authenticated; grant execute on all functions in schema auth to anon,authenticated;
 insert into auth.users values('${A}'),('${B}');`);
 await db.exec(await readFile(new URL('../supabase/migrations/20260913161414_initial_mvp.sql',import.meta.url),'utf8'));
 const seed=await readFile(new URL('../supabase/seed.sql',import.meta.url),'utf8'); await db.exec(seed);
 async function run(user,sql,params=[],extra={},role='authenticated') {
  await db.exec('begin');
  try { await db.exec(`set local role ${role}`); await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:user,role,app_metadata:{},...extra})]); const r=await db.query(sql,params); await db.exec('commit'); return r.rows; }
  catch(e) { await db.exec('rollback'); throw e; }
 }
 let offer,article,cart;
 try {
 await t.test('RLS sur toutes les tables métier',async()=>assert.equal((await db.query("select count(*)::int n from pg_tables where schemaname='public' and not rowsecurity")).rows[0].n,0));
 await t.test('Seed idempotent sans compte client',async()=>{await db.exec(seed);assert.equal((await db.query('select count(*)::int n from produits')).rows[0].n,11);assert.equal((await db.query('select count(*)::int n from clients')).rows[0].n,0);});
 await t.test('Visiteur : catalogue public, tarifs invisibles par table et RPC',async()=>{assert.equal((await run(null,'select * from produits_fournisseurs',[],{},'anon')).length,0);const p=await run(null,'select * from rechercher_catalogue()',[],{},'anon');assert.equal(p.length,11);assert(p.every(x=>x.offres.length===0));});
 await t.test('Profil privé et identifiant non transférable',async()=>{await run(A,'insert into clients(id) values($1)',[A]);await run(B,'insert into clients(id) values($1)',[B]);assert.equal((await run(A,'select * from clients')).length,1);await assert.rejects(run(A,'update clients set id=$1 where id=$2',[B,A]));});
 await t.test('Compte connecté : tarifs visibles',async()=>{offer=(await run(A,'select id from produits_fournisseurs where prix is not null order by id'))[0].id;assert((await run(A,'select * from rechercher_catalogue()')).some(p=>p.offres.length));});
 await t.test('Ajout au panier atomique et cumul',async()=>{article=(await run(A,'select ajouter_au_panier($1,2) id',[offer]))[0].id;assert.equal((await run(A,'select ajouter_au_panier($1,3) id',[offer]))[0].id,article);const row=(await run(A,'select * from articles_panier'))[0];assert.equal(row.quantite,5);cart=row.panier_id;});
 await t.test('Autre compte : aucun accès au panier',async()=>{assert.equal((await run(B,'select * from articles_panier')).length,0);assert.equal((await run(B,'update articles_panier set quantite=9 where id=$1 returning id',[article])).length,0);assert.equal((await run(B,'delete from articles_panier where id=$1 returning id',[article])).length,0);await assert.rejects(run(B,'insert into articles_panier(panier_id,offre_id) values($1,$2)',[cart,offer]));});
 await t.test('Quantités invalides et dépassement du cumul rejetés',async()=>{for(const q of [-1,0,10000,null])await assert.rejects(run(A,'select ajouter_au_panier($1,$2)',[offer,q]));await assert.rejects(run(A,'update articles_panier set quantite=$1 where id=$2',['1.5',article]));await assert.rejects(run(A,'select ajouter_au_panier($1,9999)',[offer]));assert.equal((await run(A,'select quantite from articles_panier'))[0].quantite,5);});
 await t.test('Offre inconnue et visiteur rejetés',async()=>{await assert.rejects(run(A,'select ajouter_au_panier(999999,1)'));await assert.rejects(run(null,'select ajouter_au_panier($1,1)',[offer],{},'anon'));});
 await t.test('Un rôle admin dans user_metadata ne donne aucun droit',async()=>assert.equal((await run(A,'update produits_fournisseurs set prix=0 where id=$1 returning id',[offer],{user_metadata:{role:'admin'}})).length,0));
 await t.test('Administrateur autorisé, prix négatif interdit, seed non écrasant',async()=>{const claims={app_metadata:{role:'admin'}};assert.equal((await run(A,'update produits_fournisseurs set prix=123.45 where id=$1 returning id',[offer],claims)).length,1);await assert.rejects(run(A,'update produits_fournisseurs set prix=-1 where id=$1',[offer],claims));await db.exec(seed);assert.equal(Number((await run(A,'select prix from produits_fournisseurs where id=$1',[offer]))[0].prix),123.45);});
 await t.test('Recherche littérale et zéros initiaux',async()=>{assert.equal((await run(null,"select * from rechercher_catalogue('(',0)",[],{},'anon')).length,0);await db.exec("insert into produits(ref_fabricant,nom) values('00123','Produit test (A)')");assert.equal((await run(null,"select * from rechercher_catalogue('00123',0)",[],{},'anon'))[0].ref_fabricant,'00123');assert.equal((await run(null,"select * from rechercher_catalogue('(',0)",[],{},'anon')).length,1);});
 await t.test('Pas de fonction métier SECURITY DEFINER',async()=>assert.equal((await db.query("select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef")).rows[0].n,0));
 await t.test('Suppression autorisée au propriétaire',async()=>assert.equal((await run(A,'delete from articles_panier where id=$1 returning id',[article])).length,1));
 } finally { await db.close(); }
});

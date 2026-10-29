import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222';
const root=new URL('../',import.meta.url);
const file=async path=>readFile(new URL(path,root),'utf8');
async function setup(){
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}')$$;
 grant usage on schema auth to anon,authenticated,service_role;
 create schema supabase_migrations;create table supabase_migrations.schema_migrations(version text primary key,name text,statements text[]);
 alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
 alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
 alter default privileges in schema public grant execute on functions to anon,authenticated,service_role;
 insert into auth.users values('${A}'),('${B}');`);
 for(const f of ['20260913161414_initial_mvp.sql','20261011140316_personal_supplier_prices.sql']){
  await db.exec(await file('supabase/migrations/'+f));
  await db.query('insert into supabase_migrations.schema_migrations(version,name) values($1,$2)',[f.slice(0,14),f.slice(15,-4)]);
 }
 await db.exec(`insert into clients(id) values('${A}');insert into fournisseurs(nom) values('Rexel'),('Sonepar'),('Fournisseur conservé');`);
 return db;
}
test('Business model: atomic installation on empty catalogue and live-like grants',async t=>{
 const db=await setup();
 const run=async(role,sql,args=[],admin=false,user=A)=>{
  await db.exec('begin');try{await db.exec('set local role '+role);
   await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:user,app_metadata:admin?{role:'admin'}:{}})]);
   const r=await db.query(sql,args);await db.exec('commit');return r.rows;
  }catch(e){await db.exec('rollback');throw e;}
 };
 const admin=(sql,args=[])=>run('authenticated',sql,args,true);
 const publicQuery=(sql,args=[])=>run('anon',sql,args);
 const count=async table=>Number((await db.query('select count(*) n from '+table)).rows[0].n);
 const install=await file('supabase/operations/20261029_install_catalogue_v1.sql');
 let pid,other;
 const newProduct=async(n,category='bornes')=>{
  const stem=String(200000000000+n),digit=(10-[...stem].reduce((s,c,i)=>s+Number(c)*(i%2?3:1),0)%10)%10;
  const fiche={brand:'Fabricant test',reference:'00'+n,ean:stem+digit,name:'Borne de test '+n,categories:[],review_status:'approved',offers:[{supplier:'Rexel',reference:'TEST'+n,url:'https://www.rexel.fr/frx/p/'+(800000+n),collected_at:new Date().toISOString(),page_sha256:'a'.repeat(64)}]};
  const id=(await admin('select importer_produit_collecte($1,true) result',[JSON.stringify(fiche)]))[0].result.produit_id;
  await admin('update produits set categorie_id=(select id from categories where code=$1) where id=$2',[category,id]);return id;
 };
 const observation=async(id,code,value,ctx={},status='validee',unitOverride)=>{
  const spec=(await db.query('select unite from attributs where code=$1',[code])).rows[0];
  return (await admin(`insert into observations_attributs(produit_id,attribut_code,valeur,unite,contexte,libelle_source,valeur_source,source_url,observe_le,regle_version,statut,motif_revue)
   values($1,$2,$3,$4,$5,$2,$6,'https://www.rexel.fr/frx/p/800001',now(),'test-v1',$7,$8) returning id`,
   [id,code,JSON.stringify(value),unitOverride??spec.unite,JSON.stringify(ctx),JSON.stringify(value),status,status==='conflit'?'Désaccord constaté dans les sources':null]))[0].id;
 };
 const selectValue=async(id,code,value,ctx={})=>{
  const oid=await observation(id,code,value,ctx);
  await admin('insert into valeurs_catalogue(produit_id,attribut_code,valeur,contexte,observation_id) values($1,$2,$3,$4,$5)',[id,code,JSON.stringify(value),JSON.stringify(ctx),oid]);return oid;
 };
 const complete=async id=>{
  await selectValue(id,'actionnement','levier');await selectValue(id,'points_connexion',3);
  await selectValue(id,'potentiels_independants',1);await selectValue(id,'types_conducteurs',['souple']);
  await selectValue(id,'section_souple_avec_embout',{min:0.5,max:2.5});
 };
 const publish=id=>admin('select publier_produit_catalogue($1)',[id]);
 const diag=async id=>(await admin('select diagnostic_publication($1) d',[id]))[0].d;
 try{
  await t.test('A forced migration failure rolls back ALL schema changes and preserves users',async()=>{
   await assert.rejects(db.exec(install.replace('-- Catalogue métier v1.','select deliberately_missing_function();\n-- Catalogue métier v1.')));
   await db.exec('rollback');assert.equal(await count('supabase_migrations.schema_migrations'),2);
   assert.equal((await db.query("select to_regclass('public.attributs') t")).rows[0].t,null);
   assert.equal(await count('auth.users'),2);assert.equal(await count('fournisseurs'),3);
  });
  await db.exec(install);
  await t.test('3 roots, 19 leaf families, 99 active attributes; empty catalogue and six migrations',async()=>{
   assert.equal((await db.query('select count(*)::int n from categories where actif')).rows[0].n,22);
   assert.equal((await db.query('select count(*)::int n from categories where actif and parent_id is null')).rows[0].n,3);
   assert.equal((await db.query('select count(*)::int n from attributs where actif')).rows[0].n,99);
   assert.equal(await count('produits'),0);assert.equal(await count('auth.users'),2);assert.equal(await count('clients'),1);assert.equal(await count('fournisseurs'),3);
   assert.equal(await count('supabase_migrations.schema_migrations'),6);
   assert.equal((await publicQuery('select rechercher_catalogue_v2() r'))[0].r.categories.length,0);
   try { await assert.rejects(db.exec(install),/Catalogue non vide|Historique/); } finally { await db.exec('rollback'); }
  });
  await t.test('Profiles cannot advertise circuit breaker curves on a plate or an RCD',async()=>{
   const rows=(await db.query("select c.code from categorie_attributs ca join categories c on c.id=ca.categorie_id where ca.attribut_code='courbe' and ca.actif order by c.code")).rows;
   assert.deepEqual(rows.map(r=>r.code),['disjoncteurs','disjoncteurs-differentiels']);
   assert.equal((await db.query("select count(*)::int n from categorie_attributs ca join categories c on c.id=ca.categorie_id where c.code='differentiels' and ca.attribut_code in ('sensibilite','type_differentiel') and ca.essentiel")).rows[0].n,2);
  });
  pid=await newProduct(1);
  await t.test('Legacy approved import stays private and cannot bypass publication checks',async()=>{
   assert.deepEqual(await publicQuery('select id from produits'),[]);
   assert.equal((await publicQuery('select rechercher_catalogue_v2() r'))[0].r.total,0);
   await assert.rejects(publish(pid),/Publication refusée/);
   await assert.rejects(admin("update produits set statut_qualification='publie' where id=$1",[pid]),/Publication refusée/);
   assert((await diag(pid)).erreurs.includes('manquant:actionnement'));
  });
  await t.test('Typed values: strict enums, integral counts, atomic intervals, units and contexts',async()=>{
   for(const [code,value,ctx,unit] of [['points_connexion',2.5],['actionnement','inventé'],['types_conducteurs',['souple','souple']],['section_souple',{min:4,max:2}],['section_souple',{min:0.2}],['section_souple',{min:0.2,max:4},{},'A'],['icn_230',6,{}],['ip','IP55',{}],['ip','IP55',{assemblage:null}],['ip','IP55',{assemblage:''}],['section_souple',3],['section_souple',{min:null,max:4}],['types_conducteurs',{}]])
    await assert.rejects(observation(pid,code,value,ctx??{},'validee',unit),/invalide/);
   assert.equal((await admin("select valeur_metier_valide('icn_230','6','kA','{\"norme\":\"EN 60898\",\"tension_v\":230}') v"))[0].v,true);
   assert.equal((await admin("select valeur_metier_valide('ip','\"IP2XC\"','','{\"assemblage\":\"livre\"}') v"))[0].v,true);
  });
  await t.test('Canonical values must exactly match the same product, source, value and context',async()=>{
   const oid=await observation(pid,'courant',32);
   await assert.rejects(admin('insert into valeurs_catalogue(produit_id,attribut_code,valeur,observation_id) values($1,$2,$3,$4)',[pid,'courant','16',oid]),/correspondante/);
   const pole=await observation(pid,'courbe','C');
   await assert.rejects(admin('insert into valeurs_catalogue(produit_id,attribut_code,valeur,observation_id) values($1,$2,$3,$4)',[pid,'courbe','"C"',pole]),/non applicable/);
   await assert.rejects(admin("insert into valeurs_catalogue(produit_id,attribut_code,statut) values($1,'courant','non_applicable')",[pid]),/motif/);
  });
  await t.test('Family-specific gates require exact compatibility, multipost spacing and qualified breaking capacity',async()=>{
   const plate=await newProduct(4,'plaques');
   for(const [code,value] of [['postes',2],['orientation',['horizontal']],['couleur','blanc']])await selectValue(plate,code,value);
   assert((await diag(plate)).erreurs.includes('entraxe_absent'));
   assert((await diag(plate)).erreurs.includes('compatibilite_absente'));
   await selectValue(plate,'entraxe',71);
   await assert.rejects(admin(`insert into compatibilites_produits(produit_id,systeme,role_relation,source_url,observe_le,preuve,statut)
    values($1,'Gamme test','compatible_avec','https://fabricant.example/fiche',now(),'Compatibilité vérifiée sur la notice','valide')`,[plate]),/check constraint/);
   await admin(`insert into compatibilites_produits(produit_id,systeme,version_systeme,role_relation,source_url,observe_le,preuve,statut)
    values($1,'Gamme test','Version explicitement documentée','compatible_avec','https://fabricant.example/fiche',now(),'Compatibilité vérifiée sur la notice','valide')`,[plate]);
   assert.equal((await diag(plate)).publiable,true);
   const breaker=await newProduct(5,'disjoncteurs');
   for(const [code,value] of [['courant',16],['configuration_poles','1P_N'],['courbe','C'],['tension',230],['type_tension','AC'],['modules_din',1]])await selectValue(breaker,code,value);
   assert((await diag(breaker)).erreurs.includes('coupure_qualifiee_absente'));
   await selectValue(breaker,'icn_230',6,{norme:'EN 60898',tension_v:230});
   assert.equal((await diag(breaker)).publiable,true);
  });
  await t.test('Conductor sets are order-independent and one conductor range cannot cover another type',async()=>{
   const id=await newProduct(6);await complete(id);
   await admin("delete from valeurs_catalogue where produit_id=$1 and attribut_code='types_conducteurs'",[id]);
   await admin("delete from observations_attributs where produit_id=$1 and attribut_code='types_conducteurs'",[id]);
   await selectValue(id,'types_conducteurs',['massif','souple']);
   await observation(id,'types_conducteurs',['souple','massif']);
   assert(!(await diag(id)).erreurs.includes('conflit_non_resolu'));
   assert((await diag(id)).erreurs.includes('plage_manquante:massif'));
   await selectValue(id,'section_rigide',{min:0.2,max:4});
   assert.equal((await diag(id)).publiable,true);
  });
  await complete(pid);
  await t.test('Publication revalidates evidence against a revised dictionary; documented non-applicability is explicit',async()=>{
   await admin("delete from attribut_valeurs where attribut_code='actionnement' and code='levier'");
   assert((await diag(pid)).erreurs.includes('valeur_retenue_invalide'));
   await assert.rejects(publish(pid),/Publication refusée/);
   await admin("insert into attribut_valeurs values('actionnement','levier','levier')");
   await admin(`insert into valeurs_catalogue(produit_id,attribut_code,statut,motif,source_exception)
    values($1,'courant','non_applicable','Exception fictive documentée pour le test','https://fabricant.example/exception')`,[pid]);
   assert.equal((await diag(pid)).publiable,true);
  });
  await t.test('Qualified publication is public; raw evidence remains admin-only; ranges are retained',async()=>{
   assert.equal((await diag(pid)).publiable,true);await publish(pid);
   assert.equal((await publicQuery('select id from produits')).length,1);
   const vals=await publicQuery("select valeur from valeurs_catalogue where attribut_code='section_souple_avec_embout'");assert.deepEqual(vals[0].valeur,{min:0.5,max:2.5});
   await assert.rejects(publicQuery('select * from observations_attributs'),/permission denied/);
   assert.equal((await run('authenticated','select * from observations_attributs',[],false,B)).length,0);
   const nav=(await publicQuery('select rechercher_catalogue_v2() r'))[0].r.categories;
   assert.deepEqual(nav.map(c=>c.code).sort(),['bornes','raccordement']);
   assert.equal((await publicQuery("select intervalle_catalogue_contient('{\"min\":0.5,\"max\":2.5}',2.5) ok"))[0].ok,true);
   assert.equal((await publicQuery("select intervalle_catalogue_contient('{\"min\":0.5,\"max\":2.5}',4) ok"))[0].ok,false);
  });
  await t.test('New conflicting evidence automatically unpublishes; explicit resolution is required',async()=>{
   const oid=await observation(pid,'points_connexion',5,{},'observee');
   assert.deepEqual(await publicQuery('select id from produits'),[]);
   assert((await diag(pid)).erreurs.includes('conflit_non_resolu'));
   await assert.rejects(publish(pid),/Publication refusée/);
   await admin("update observations_attributs set statut='rejetee',motif_revue='Source relue : valeur incorrecte' where id=$1",[oid]);await publish(pid);
   await assert.rejects(admin("update observations_attributs set valeur='8' where produit_id=$1 and attribut_code='points_connexion' and statut='validee'",[pid]),/immuable/);
  });
  await t.test('Changes to reference rules cannot invalidate published data silently',async()=>{
   await assert.rejects(admin("delete from attribut_valeurs where attribut_code='actionnement' and code='levier'"),/Dépublier/);
   await assert.rejects(admin("update categories set actif=false where code='raccordement'"),/Dépublier/);
  });
  await t.test('Draft offers cannot be put in a cart, including by an administrator',async()=>{
   other=await newProduct(2);await complete(other);
   await run('authenticated','insert into paniers(client_id) values($1)',[A]);
   const cart=(await run('authenticated','select id from paniers'))[0].id;
   const offer=(await admin('select id from produits_fournisseurs where produit_id=$1',[other]))[0].id;
   await assert.rejects(admin('insert into articles_panier(panier_id,offre_id) values($1,$2)',[cart,offer]),/non publiée/);
   await publish(other);await run('authenticated','insert into articles_panier(panier_id,offre_id) values($1,$2)',[cart,offer]);
   assert.deepEqual(await run('authenticated','select * from articles_panier',[],false,B),[]);
  });
  await t.test('Private prices remain isolated after all new migrations',async()=>{
   const offer=(await admin('select id,url_produit from produits_fournisseurs where produit_id=$1',[other]))[0];
   await run('authenticated',`insert into prix_personnels(id,client_id,offre_id,contexte_empreinte,quantite,montant_ht,base_prix,unite,source_url,observe_le,expire_le)
    values('33333333-3333-4333-8333-333333333333',$1,$2,$3,1,10,1,'piece',$4,now(),now()+interval '10 minutes')`,[A,offer.id,'a'.repeat(64),offer.url_produit]);
   assert.equal((await run('authenticated','select * from prix_personnels')).length,1);
   assert.deepEqual(await run('authenticated','select * from prix_personnels',[],true,B),[]);
  });
  await t.test('RLS and least privilege on all tables, sequences and administrative RPCs',async()=>{
   assert.equal((await db.query("select count(*)::int n from pg_tables where schemaname='public' and not rowsecurity")).rows[0].n,0);
   for(const role of ['anon','authenticated'])assert.deepEqual((await db.query("select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' and has_table_privilege($1,oid,'TRUNCATE')",[role])).rows,[]);
   await assert.rejects(publicQuery('select publier_produit_catalogue($1)',[pid]),/permission denied/);
   await assert.rejects(run('authenticated','select publier_produit_catalogue($1)',[pid],false,B),/administrateur/);
   await assert.rejects(run('authenticated',"insert into observations_attributs(produit_id,attribut_code,libelle_source,valeur_source,source_url,observe_le,regle_version) values($1,'courant','A','32','https://www.rexel.fr/frx/p/1',now(),'x')",[pid],false,B),/row-level security/);
   assert.equal((await db.query("select count(*)::int n from pg_proc where pronamespace='public'::regnamespace and prosecdef")).rows[0].n,0);
  });
 }finally{await db.close();}
});

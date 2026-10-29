import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {PGlite} from '@electric-sql/pglite';

const A='11111111-1111-4111-8111-111111111111', B='22222222-2222-4222-8222-222222222222';
// Synthetic catalogue, never loaded into the live project.
function candidate(n) {
 const stem=String(200000000000+n),digit=(10-[...stem].reduce((s,c,i)=>s+Number(c)*(i%2?3:1),0)%10)%10;
 const color=n%2?'blanc':'noir',current=n%3?16:20;
 return {schema_version:2,brand:'Fabricant test',reference:`00${n}`,ean:stem+digit,name:`Prise électrique test ${n}`,
  review_status:'approved',categories:['Découverte'],category_code:'prises',range:'Série test',attribute_conflicts:[],
  attributes:[{code:'couleur',type:'text',value:color,unit:'',supplier:'Rexel',raw_label:'Couleur',raw_value:color},
   {code:'courant',type:'number',value:current,unit:'A',supplier:'Rexel',raw_label:'Intensité',raw_value:current+' A'},
   {code:'sans_halogene',type:'boolean',value:false,unit:'',supplier:'Rexel',raw_label:'Sans halogène',raw_value:'Non'}],
  offers:[{supplier:'Rexel',reference:`TEST00${n}`,url:`https://www.rexel.fr/frx/p/${900000+n}`,pack:'À confirmer',collected_at:'2026-10-15T10:00:00Z',page_sha256:'a'.repeat(64),range:'Série test',description:'Description technique sourcée',category_path:[],
   raw_attributes:[{label:'Couleur',value:color},{label:'Intensité',value:current+' A'},{label:'Sans halogène',value:'Non'}]}]};
}

test('Catalogue v2 : migrations, import, recherche, facettes et RLS',async t=>{
 const db=new PGlite();
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}')$$;
 grant usage on schema auth to anon,authenticated;insert into auth.users values('${A}'),('${B}');`);
 async function as(role,sql,params=[],id=A,admin=false){await db.exec('begin');try{await db.exec('set local role '+role);await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:id,app_metadata:admin?{role:'admin'}:{}})]);const r=await db.query(sql,params);await db.exec('commit');return r.rows;}catch(e){await db.exec('rollback');throw e;}}
 const search=async(q='',filters={},page=0,role='anon')=>(await as(role,'select rechercher_catalogue_v2($1,$2,$3) result',[q,JSON.stringify(filters),page]))[0].result;
 const publish=async(p,approve=true)=>(await as('authenticated','select importer_catalogue_v2($1,$2) result',[JSON.stringify(p),approve],A,true))[0].result;
 try {
  // Reproduce the actual project's broad defaults, not bare PostgreSQL defaults.
  await db.exec(`alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
   alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
   alter default privileges in schema public grant execute on functions to anon,authenticated,service_role;`);
  // v2 contract regression. The stricter v1 business model and publication gate
  // are exercised against ALL migrations in catalogue-model.test.mjs.
  for(const file of (await readdir('supabase/migrations')).filter(f=>f<='20261015130122_catalogue_facets.sql').sort()){
   await db.exec(await readFile('supabase/migrations/'+file,'utf8'));
   if(file.endsWith('_initial_mvp.sql'))await db.exec(await readFile('supabase/seed.sql','utf8'));
   if(file.endsWith('_personal_supplier_prices.sql'))await db.exec(await readFile('supabase/pilot_catalog.sql','utf8'));
  }
  await as('authenticated','insert into clients(id) values($1)',[A]);
  await t.test('Migration sans destruction : anciens produits conservés, démos masquées',async()=>{
   assert.equal(Number((await db.query('select count(*) n from produits')).rows[0].n),14);
   assert.equal((await search()).total,3);
   assert.equal((await as('anon','select * from produits')).length,3);
   assert.equal((await as('anon','select * from produits_fournisseurs')).length,0);
   assert.equal((await as('authenticated','select * from produits_fournisseurs')).length,6);
   assert((await search('LEG069511L')).items.some(p=>p.sources.some(s=>s.reference==='LEG069511L')));
  });
  await t.test('Arbre : cycle indirect et doublon racine refusés',async()=>{
   await assert.rejects(db.exec("update categories set parent_id=(select id from categories where code='prises') where code='appareillage'"),/Cycle/);
   await assert.rejects(db.exec("insert into categories(code,nom) values('doublon',' Appareillage ')"));
  });
  await t.test('Import réel Python → SQL → PostgreSQL, 30 produits, publication idempotente',async()=>{
   const batch=Array.from({length:30},(_,i)=>candidate(i+1));
   const sql=execFileSync('python3',['-c','import json,sys;from scripts.prepare_catalogue_import import generate_sql;print(generate_sql(json.load(sys.stdin),True))'],{input:JSON.stringify(batch),encoding:'utf8'});
   await db.exec(sql);await db.exec(sql);
   assert.equal((await search('prise test')).total,30);
   assert.equal((await db.query('select count(*)::int n from produit_attributs')).rows[0].n,90);
   const p=(await search('001')).items[0];assert.equal(p.gamme,'Série test');assert.equal(p.attributs.find(a=>a.code==='sans_halogene').valeur,false);
  });
  await t.test('Recherche par GTIN, référence fabricant et code fournisseur, sans fuite de prix',async()=>{
   for(const q of [candidate(1).ean,'001','TEST001','test001']){const r=await search(q);assert.equal(r.total,1,q);assert.equal(r.items[0].offres.length,0);}
   assert.equal((await search('prise electrique fabricant')).total,30);
   assert.equal((await search(candidate(1).ean+'12345')).total,0);
   const p=(await search('001',{},0,'authenticated')).items[0];assert.equal(p.offres.length,1);assert.equal(p.offres[0].prix,null);
  });
  await t.test('Comptages avant pagination et facettes disjonctives, combinaisons ET/OU',async()=>{
   const all=await search('prise test');assert.equal(all.total,30);assert.equal(all.items.length,24);
   assert.equal((await search('prise test',{},1)).items.length,6);
   const white=await search('prise test',{'a:couleur':['blanc']});assert.equal(white.total,15);
   const colors=white.facets.find(f=>f.key==='a:couleur');assert.deepEqual(colors.values.map(v=>v.count),[15,15]);
   assert.equal((await search('prise test',{'a:couleur':['blanc','noir']})).total,30);
   assert.equal((await search('prise test',{'a:couleur':['blanc'],'a:courant':['16']})).total,10);
   assert.equal((await search('prise test',{'a:courant':{min:19,max:21}})).total,10);
   assert.equal((await search('prise test',{'a:sans_halogene':['false']})).total,30);
   assert.equal((await search('prise test',{categorie:['appareillage']})).total,30);
   assert.equal((await search('prise test',{fournisseur:['Sonepar']})).total,0);
   for(const f of [{'a:courant':{min:20,max:10}},{secret:['x']},{marque:{min:1}},{'a:couleur':[null]}])await assert.rejects(search('',f));
  });
  await t.test('Publication : catégorie, conflits, types, unités et provenance contrôlés',async()=>{
   const invalid=[];let p=candidate(31);p.category_code=null;invalid.push(p);
   p=candidate(31);p.attributes[0].raw_value='inventé';invalid.push(p);
   p=candidate(31);p.attributes[1].unit='mA';invalid.push(p);
   p=candidate(31);p.attributes[1].value=null;invalid.push(p);
   p=candidate(31);p.attribute_conflicts=['couleur'];invalid.push(p);
   p=candidate(31);p.offers[0].cookie='secret';invalid.push(p);
   p=candidate(31);p.category_code='appareillage';invalid.push(p);
   for(const x of invalid)await assert.rejects(publish(x));
   assert.equal((await search('prise test')).total,30);
   p=candidate(31);p.review_status='pending';p.category_code=null;await publish(p,false);assert.equal((await search('0031')).total,0);
   await assert.rejects(as('authenticated','select importer_catalogue_v2($1,true)',[JSON.stringify(candidate(32))],B));
  });
  await t.test('Écritures directes : attribut mal typé et offre démo au panier refusés',async()=>{
   const pid=(await search('001')).items[0].id;
   await assert.rejects(db.query("update produit_attributs set valeur_nombre=null where produit_id=$1 and attribut_code='courant'",[pid]));
   await assert.rejects(db.query("update produits set categorie_id=null where id=$1",[pid]));
   const demo=(await db.query('select id from produits_fournisseurs where not reference_verifiee limit 1')).rows[0].id;
   await assert.rejects(as('authenticated','select ajouter_au_panier($1)',[demo]));
   await as('authenticated','insert into paniers(client_id) values($1) on conflict do nothing',[A]);
   const cart=(await as('authenticated','select id from paniers'))[0].id;
   await assert.rejects(as('authenticated','insert into articles_panier(panier_id,offre_id) values($1,$2)',[cart,demo]));
  });
  await t.test('Renommage : marque et gamme répercutées dans la recherche indexée',async()=>{
   await db.exec("update marques set nom='Marque renommée' where nom='Fabricant test';update gammes set nom='Collection nouvelle' where nom='Série test'");
   assert.equal((await search('prise renommee nouvelle')).total,30);
   assert.equal((await search('prise fabricant')).total,0);
  });
  await t.test('Fiches réelles Rexel/Sonepar : le contrat v0.4.0 se publie et conserve les unités',async()=>{
   const samples=JSON.parse(await readFile('catalog/validation/20261016/products-pending.json','utf8'));
   for(const p of samples)await publish({...p,review_status:'approved'});
   const found=await search('A9P22610');assert.equal(found.total,1);
   assert.equal(found.items[0].attributs.find(a=>a.code==='icn_230').valeur,4.5);
   assert.equal(found.items[0].attributs.find(a=>a.code==='icu_230').valeur,6);
   assert.equal(found.items[0].attributs.find(a=>a.code==='poles_proteges').valeur,1);
   assert.equal(found.items[0].sources.length,2);
  });
  await t.test('RLS partout, aucun SECURITY DEFINER et aucune observation privée dans les facettes',async()=>{
   assert.equal((await db.query("select count(*)::int n from pg_tables where schemaname='public' and not rowsecurity")).rows[0].n,0);
   assert.equal((await db.query("select count(*)::int n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef")).rows[0].n,0);
   assert.equal((await as('authenticated','select * from collectes_catalogue',[],B)).length,0);
   assert(!(await search()).facets.some(f=>/prix|price/.test(f.key)));
  });
  await t.test('Droits hérités retirés : TRUNCATE, séquences et imports anonymes',async()=>{
   for(const role of ['anon','authenticated']) {
    const rights=(await db.query(`select c.relname from pg_class c where c.relnamespace='public'::regnamespace
     and c.relkind='r' and (has_table_privilege($1,c.oid,'TRUNCATE') or has_table_privilege($1,c.oid,'TRIGGER') or has_table_privilege($1,c.oid,'REFERENCES'))`,[role])).rows;
    assert.deepEqual(rights,[],role);
    await assert.rejects(as(role,'truncate marques cascade'),/permission denied/);
    const sequences=(await db.query(`select c.relname from pg_class c where c.relnamespace='public'::regnamespace
     and case when c.relkind='S' then has_sequence_privilege($1,c.oid,$2) else false end`,[role,role==='anon'?'USAGE,SELECT,UPDATE':'UPDATE'])).rows;
    assert.deepEqual(sequences,[],role);
   }
   for(const signature of ['importer_produit_collecte(jsonb,boolean)','importer_catalogue_v2(jsonb,boolean)','ajouter_au_panier(bigint,integer)'])
    assert.equal((await db.query("select has_function_privilege('anon',$1,'EXECUTE') allowed",[signature])).rows[0].allowed,false,signature);
   await assert.rejects(as('anon','select importer_catalogue_v2($1,true)',[JSON.stringify(candidate(99))]),/permission denied/);
   await assert.rejects(as('authenticated','insert into marques(nom) values($1)',['Sans droit admin'],B),/row-level security/);
  });
 } finally {await db.close();}
});

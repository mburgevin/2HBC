import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {PGlite} from '@electric-sql/pglite';
const root=new URL('../',import.meta.url);
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222';
function python(code,value,args=[]){return execFileSync('python3',['-c',code,...args],{cwd:root,input:JSON.stringify(value),encoding:'utf8'});}
function candidate(n=1){
 const stem=String(200000000100+n),digit=(10-[...stem].reduce((s,c,i)=>s+Number(c)*(i%2?3:1),0)%10)%10;
 const p={brand:'Fabricant de test v3',reference:'00'+n,ean:stem+digit,name:"Borne d'essai \\ '); delete from produits; --",categories:[],review_status:'pending',offers:[{supplier:'Rexel',reference:'V3TEST'+n,url:'https://www.rexel.fr/frx/p/'+(900000+n),collected_at:'2026-10-11T12:00:00Z',page_sha256:'a'.repeat(64),raw_attributes:[
  {label:'Actionnement',value:'levier'},{label:'Nombre de points de connexion',value:'3'},{label:'Nombre de potentiels',value:'1'},
  {label:'Types de conducteurs',value:'souple'},{label:'Section conducteur souple avec embout',value:'0,5...2,5 mm²'}],category_path:[],description:'Donnée fictive réservée au test',range:null}]};
 return JSON.parse(python('import json,sys;from scripts.catalogue_metier import enrich;print(json.dumps(enrich(json.load(sys.stdin))))',p));
}
const reviewed=p=>{p=structuredClone(p);p.category_code='bornes';p.review_status='approved';p.observations.forEach(a=>{a.status='validated';a.selected=true;});return p;};
const generated=(items,approve=false,publish=false)=>python('import json,sys;from scripts.prepare_catalogue_import import generate_sql;print(generate_sql(json.load(sys.stdin),sys.argv[1]=="true",sys.argv[2]=="true"))',items,[String(approve),String(publish)]);

test('Import métier v3 : Python → SQL → qualification privée → publication contrôlée',async t=>{
 const db=new PGlite();let pid;
 const run=async(role,sql,args=[],admin=false,user=A)=>{
  await db.exec('begin');try{await db.exec('set local role '+role);
   await db.query("select set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:user,app_metadata:admin?{role:'admin'}:{}})]);
   const result=await db.query(sql,args);await db.exec('commit');return result.rows;
  }catch(e){await db.exec('rollback');throw e;}
 };
 const importAs=(p,approve=false,publish=false,admin=true)=>run('authenticated','select importer_catalogue_v3($1,$2,$3) r',[JSON.stringify(p),approve,publish],admin);
 const admin=(sql,args=[])=>run('authenticated',sql,args,true);
 const count=async name=>Number((await db.query('select count(*) n from '+name)).rows[0].n);
 const visible=()=>run('anon','select id from produits');
 const p=candidate(),approved=reviewed(p);
 try{
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
   create schema auth;create table auth.users(id uuid primary key);
   create function auth.uid() returns uuid language sql stable as $$select (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid$$;
   create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}')$$;
   grant usage on schema auth to anon,authenticated,service_role;
   alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
   alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
   alter default privileges in schema public grant execute on functions to anon,authenticated,service_role;
   insert into auth.users values('${A}'),('${B}');`);
  for(const f of (await readdir(new URL('supabase/migrations/',root))).sort())await db.exec(await readFile(new URL('supabase/migrations/'+f,root),'utf8'));
  await db.exec(`insert into fournisseurs(nom) values('Rexel'),('Sonepar');insert into clients(id) values('${A}'),('${B}');`);
  await t.test('La préparation conserve les preuves sans créer de produit ; les rôles ordinaires sont refusés',async()=>{
   const sql=generated([p]);await db.exec(sql);await db.exec(sql);
   assert.equal(await count('produits'),0);assert.equal(await count('observations_attributs'),0);
   assert.equal(await count('collectes_catalogue'),3);
   await assert.rejects(importAs(p,false,false,false),/administrateur/);
   await assert.rejects(run('anon','select importer_catalogue_v3($1,false,false)',[JSON.stringify(p)]),/permission denied/);
   assert.deepEqual(await run('authenticated','select * from collectes_catalogue',[],false,B),[]);
   await assert.rejects(importAs({...p,category_code:'bornes'},true),/approuv/);
  });
  await t.test('Une identité relue crée une fiche privée avec observations encore non validées',async()=>{
   const draft={...p,category_code:'bornes',review_status:'approved'};
   pid=(await importAs(draft,true))[0].r.produit_id;
   assert.equal(await count('produits'),1);assert.equal(await count('observations_attributs'),5);
   assert.equal(await count('valeurs_catalogue'),0);assert.deepEqual(await visible(),[]);
   assert.equal((await admin('select diagnostic_publication($1) d',[pid]))[0].d.publiable,false);
   await assert.rejects(importAs(draft,true,true),/Publication refusée/);
  });
  await t.test('Sélection explicite, provenance et publication : le vrai générateur produit un lot idempotent',async()=>{
   await db.exec(generated([approved],true));assert.deepEqual(await visible(),[]);
   assert.equal(await count('observations_attributs'),5);assert.equal(await count('valeurs_catalogue'),5);
   const raw=(await admin("select valeur,unite,collecte_empreinte from observations_attributs where attribut_code='section_souple_avec_embout'"))[0];
   assert.deepEqual(raw.valeur,{min:0.5,max:2.5});assert.equal(raw.unite,'mm²');assert.match(raw.collecte_empreinte,/^[a-f0-9]{64}$/);
   const sql=generated([approved],true,true);await db.exec(sql);
   const before=(await admin('select qualification_le from produits where id=$1',[pid]))[0].qualification_le;
   await db.exec(generated([approved],true));
   assert.equal((await admin('select qualification_le from produits where id=$1',[pid]))[0].qualification_le.getTime(),before.getTime());
   assert.equal((await visible()).length,1);assert.equal(await count('observations_attributs'),5);
   assert.equal((await admin('select nom from produits where id=$1',[pid]))[0].nom,p.name);
   assert.equal((await admin('select prix from produits_fournisseurs'))[0].prix,null);
  });
  await t.test('La validation serveur refuse provenance, types, secrets, doublons et sélection implicite',async()=>{
   for(const patch of [{value:9},{raw_label:'inventé'},{selected:true,status:'pending'},{code:'inconnu'},{unit:'A'},{context:null},{cookie:'secret'}]){
    const invalid=structuredClone(approved);Object.assign(invalid.observations[0],patch);
    // A reviewed changed value is allowed if source evidence exists: validators
    // cannot read supplier pages. Use a boolean for strict type rejection.
    if('value' in patch)invalid.observations[0].value=true;
    await assert.rejects(importAs(invalid,true));
   }
   for(const patch of [{price:99},{schema_version:4},{observations:null},{category_code:'fils'}])await assert.rejects(importAs({...approved,...patch},true));
   const duplicate=structuredClone(approved);duplicate.observations.push(duplicate.observations[0]);await assert.rejects(importAs(duplicate,true),/dupliquée/);
   const missing=structuredClone(approved);delete missing.observations[0].review_note;await assert.rejects(importAs(missing,true),/manquants/);
   assert.equal((await visible()).length,1);assert.equal(await count('produits'),1);
  });
  await t.test('Une nouvelle préparation ne rétrograde pas les observations déjà validées',async()=>{
   const collected=structuredClone(p);collected.category_code='bornes';collected.review_status='approved';
   collected.name='Titre relu sans changement des preuves';
   const result=(await importAs(collected,true))[0].r;
   assert.equal(result.diagnostic.publiable,true);
   assert.equal((await admin("select count(*)::int n from observations_attributs where statut='validee'"))[0].n,5);
   assert.equal(await count('valeurs_catalogue'),5);
  });
  await t.test('Une source contradictoire dépublie ; son rejet documenté résout le conflit sans effacer les preuves',async()=>{
   const changed=structuredClone(approved);
   changed.offers[0].raw_attributes.push({label:'Points connexion',value:'5'});
   changed.observations.push({...changed.observations[1],value:5,raw_label:'Points connexion',raw_value:'5',status:'pending',selected:false});
   const result=(await importAs(changed,true))[0].r;
   assert.equal(result.qualification,'a_revoir');assert(result.diagnostic.erreurs.includes('conflit_non_resolu'));
   assert.equal(await count('observations_attributs'),6);assert.deepEqual(await visible(),[]);
   await assert.rejects(importAs(changed,true,true),/Publication refusée/);
   changed.observations.at(-1).status='rejected';changed.observations.at(-1).review_note='Source contrôlée : valeur erronée pour cette référence';
   await importAs(changed,true,true);assert.equal((await visible()).length,1);
   assert.equal(await count('observations_attributs'),6);
   assert.equal((await admin("select count(*)::int n from observations_attributs where statut='rejetee'"))[0].n,1);
  });
  await t.test('Rejeter une ancienne sélection retire sa valeur et exige une nouvelle qualification',async()=>{
   const rejected=structuredClone(approved);rejected.observations[0].status='rejected';rejected.observations[0].selected=false;rejected.observations[0].review_note='Actionnement retenu par erreur : à revérifier';
   await importAs(rejected,true);
   assert.equal(await count('valeurs_catalogue'),4);assert.deepEqual(await visible(),[]);
   await assert.rejects(importAs(rejected,true,true),/Publication refusée/);
  });
  await t.test('Un échec dans un lot annule toutes ses fiches et preuves',async()=>{
   const good=reviewed(candidate(20)),bad=reviewed(candidate(21));bad.observations[0].selected=false;
   const before=await count('produits');
   await assert.rejects(db.exec(generated([good,bad],true,true)),/Publication refusée/);await db.exec('rollback');
   assert.equal(await count('produits'),before);
   assert.equal((await db.query("select count(*)::int n from observations_attributs where source_url like '%900020'")).rows[0].n,0);
  });
  await t.test('Exceptions et compatibilités documentées importables ; aucun prix personnel modifié',async()=>{
   const other=reviewed(candidate(30));other.category_code='plaques';other.observations=[];
   other.exceptions=['postes','orientation','couleur'].map(code=>({code,context:{},reason:'Exception synthétique documentée pour test',source_url:'https://fabricant.example/notice'}));
   other.compatibilities=[{system:'Système documenté',version:'2026',role:'compatible_avec',source_url:'https://fabricant.example/notice',observed_at:'2026-10-11T12:00:00Z',evidence:'Compatibilité explicitement documentée dans la notice'}];
   await importAs(other,true,true);await importAs(other,true,true);
   assert.equal(await count('compatibilites_produits'),1);
   assert.equal((await run('anon',"select count(*)::int n from valeurs_catalogue where statut='non_applicable'"))[0].n,0);
   const offer=(await admin('select id,url_produit from produits_fournisseurs where produit_id=$1',[pid]))[0];
   await run('authenticated',`insert into prix_personnels(id,client_id,offre_id,contexte_empreinte,quantite,montant_ht,base_prix,unite,source_url,observe_le,expire_le)
    values('33333333-3333-4333-8333-333333333333',$1,$2,$3,1,10,1,'piece',$4,now(),now()+interval '10 minutes')`,[A,offer.id,'a'.repeat(64),offer.url_produit],true);
   await importAs(approved,true);
   assert.equal((await run('authenticated','select * from prix_personnels')).length,1);
   assert.deepEqual(await run('authenticated','select * from prix_personnels',[],true,B),[]);
  });
  await t.test('Six fiches officielles collectées réellement : préparation v3 sans publication ni perte des observations',async()=>{
   const live=JSON.parse(await readFile(new URL('catalog/validation/20261030/products-pending.json',root),'utf8'));
   const before=await count('produits'),observations=await count('observations_attributs');
   const sql=generated(live);await db.exec(sql);await db.exec(sql);
   assert.equal(await count('produits'),before);assert.equal(await count('observations_attributs'),observations);
   for(const p of live){
    const rows=await admin("select donnees from collectes_catalogue where donnees->>'schema_version'='3' and donnees->>'ean'=$1",[p.ean]);
    assert.equal(rows.length,1);assert.deepEqual(rows[0].donnees.observations,p.observations);
    assert.deepEqual(rows[0].donnees.offers,p.offers);
   }
  });
  await t.test('RLS conservée et fonction métier invoker sans exécution publique',async()=>{
   assert.equal((await db.query("select count(*)::int n from pg_tables where schemaname='public' and not rowsecurity")).rows[0].n,0);
   assert.equal((await db.query("select count(*)::int n from pg_proc where pronamespace='public'::regnamespace and prosecdef")).rows[0].n,0);
   assert.equal((await db.query("select has_function_privilege('anon','importer_catalogue_v3(jsonb,boolean,boolean)','EXECUTE') ok")).rows[0].ok,false);
  });
 }finally{await db.close();}
});

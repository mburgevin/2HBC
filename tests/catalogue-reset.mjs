// Explicit local rehearsal with the private backup; never contacts Supabase.
// node tests/catalogue-reset.mjs /absolute/path/to/backup.json
import {PGlite} from '@electric-sql/pglite';import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';
const backup=JSON.parse(await readFile(process.argv[2],'utf8'));const db=new PGlite();
try{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid$$;create function auth.jwt() returns jsonb language sql as $$select '{}'::jsonb$$;
 create schema supabase_migrations;create table supabase_migrations.schema_migrations(version text primary key,name text,statements text[]);`);
 await db.exec(`alter default privileges in schema public grant all on tables to anon,authenticated,service_role;
  alter default privileges in schema public grant all on sequences to anon,authenticated,service_role;
  alter default privileges in schema public grant execute on functions to anon,authenticated,service_role;`);
 for(const f of ['20260913161414_initial_mvp.sql','20261011140316_personal_supplier_prices.sql']){await db.exec(await readFile('supabase/migrations/'+f,'utf8'));await db.query('insert into supabase_migrations.schema_migrations(version,name) values($1,$2)',[f.slice(0,14),f.slice(15,-4)]);}
 await db.exec("insert into auth.users values('11111111-1111-4111-8111-111111111111');insert into clients(id) select id from auth.users;");
 for(const table of ['categories','fournisseurs','produits','produits_fournisseurs']){
  const rows=backup[table];if(!rows.length)continue;const cols=Object.keys(rows[0]).map(x=>'"'+x+'"').join(',');
  await db.query(`insert into ${table}(${cols}) select ${cols} from jsonb_populate_recordset(null::${table},$1)`,[JSON.stringify(rows)]);
 }
 for(const id of new Set(backup.articles_panier.map(a=>a.panier_id)))await db.query("insert into paniers(id,client_id) values($1,'11111111-1111-4111-8111-111111111111')",[id]);
 if(backup.articles_panier.length){const cols=Object.keys(backup.articles_panier[0]).map(x=>'"'+x+'"').join(',');await db.query(`insert into articles_panier(${cols}) select ${cols} from jsonb_populate_recordset(null::articles_panier,$1)`,[JSON.stringify(backup.articles_panier)]);}
 const sql=await readFile('supabase/operations/20261016_reset_catalogue.sql','utf8');
 // A deliberately injected migration failure must roll back all deletions.
 await assert.rejects(db.exec(sql.replace('-- 20261012163203_catalogue_integrity_import.sql',"select no_such_test_function();\n-- 20261012163203_catalogue_integrity_import.sql")));
 await db.exec('rollback');
 assert.equal(Number((await db.query('select count(*) n from produits')).rows[0].n),114);
 assert.equal(Number((await db.query('select count(*) n from articles_panier')).rows[0].n),7);
 await db.exec(sql);
 for(const table of ['produits','produits_fournisseurs','articles_panier'])assert.equal(Number((await db.query('select count(*) n from '+table)).rows[0].n),0);
 for(const table of ['clients','paniers'])assert.equal(Number((await db.query('select count(*) n from '+table)).rows[0].n),1);
 assert.equal(Number((await db.query('select count(*) n from categories')).rows[0].n),21);
 assert.equal(Number((await db.query('select count(*) n from attributs')).rows[0].n),22);
 assert.equal(Number((await db.query('select count(*) n from supabase_migrations.schema_migrations')).rows[0].n),5);
 assert.equal((await db.query("select count(*)::int n from pg_tables where schemaname='public' and rowsecurity")).rows[0].n,17);
 await assert.rejects(db.exec(sql));await db.exec('rollback');
 console.log('PASS: rollback, reset scoped to catalogue, accounts/cart preserved, 3 migrations registered, second execution refused.');
}finally{await db.close();}

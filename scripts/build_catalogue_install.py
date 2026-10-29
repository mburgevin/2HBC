"""Assemble the pending migration and an atomic installer for the empty live catalogue.

Does not connect to Supabase. Refuses to assemble a historical migration other
than the explicit pending version below. All SQL sources stay reviewable in git.
"""
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]
folder=ROOT/'supabase/migrations'
name='20261029161909_catalogue_modele_metier_v1.sql'
previous=(folder/'20261015130122_catalogue_facets.sql').read_text()
rpc=previous[previous.index('create function public.rechercher_catalogue_v2('):previous.index('revoke all on function public.rechercher_catalogue_v2(')]
rpc=rpc.replace('create function public.rechercher_catalogue_v2','create or replace function public.rechercher_catalogue_v2').replace('from public.categories where actif','from public.categories_catalogue where actif')
(folder/name).write_text('begin;\n'+(ROOT/'supabase/catalogue/referentiel_schema.sql').read_text()+'\n'+(ROOT/'supabase/catalogue/referentiel_seed.sql').read_text()+'\n'+rpc+'\ncommit;\n')
pending=['20261012163203_catalogue_integrity_import.sql','20261013131653_catalogue_images.sql','20261015130122_catalogue_facets.sql',name]
sql=["""-- 2HBC / gueuqeqyshhhmxbsiuxg. Empty catalogue installation; no DELETE/TRUNCATE.
-- Preserves accounts, clients, suppliers and carts. Stop on error; do not run fragments.
begin;
set local lock_timeout='5s';
set local statement_timeout='120s';
select pg_advisory_xact_lock(2042,1);
lock table public.produits,public.produits_fournisseurs,public.categories in share row exclusive mode;
do $guard$ begin
 if exists(select 1 from public.produits) or exists(select 1 from public.produits_fournisseurs) or exists(select 1 from public.categories)
 then raise exception 'Catalogue non vide : revoir le plan avant installation'; end if;
 if (select array_agg(version::text order by version) from supabase_migrations.schema_migrations)
   is distinct from array['20260913161414','20261011140316']::text[]
 then raise exception 'Historique différent : installation déjà faite ou migration concurrente'; end if;
end $guard$;
"""]
for file in pending:
    raw=(folder/file).read_text()
    body=re.sub(r'^begin;\s*','',raw,flags=re.I)
    body=re.sub(r'\s*commit;\s*$','',body,flags=re.I)
    version,title=file[:-4].split('_',1)
    marker='$migration_'+version+'$'
    assert marker not in body
    sql += ['\n-- '+file+'\n'+body, f"\ninsert into supabase_migrations.schema_migrations(version,name,statements) values('{version}','{title}',array[{marker}{body}{marker}]);"]
sql += ["""
do $verify$ begin
 if (select count(*) from public.categories where actif)<>22 or (select count(*) from public.attributs where actif)<>99
 then raise exception 'Référentiel incomplet'; end if;
 if exists(select 1 from pg_tables where schemaname='public' and not rowsecurity)
 then raise exception 'RLS manquante'; end if;
 if exists(select 1 from pg_class c cross join(values('anon'),('authenticated')) r(role_name)
 where c.relnamespace='public'::regnamespace and c.relkind='r' and
 (has_table_privilege(r.role_name,c.oid,'TRUNCATE') or has_table_privilege(r.role_name,c.oid,'TRIGGER') or has_table_privilege(r.role_name,c.oid,'REFERENCES')))
 then raise exception 'Droits de table excessifs'; end if;
end $verify$;
notify pgrst,'reload schema';
commit;
"""]
target=ROOT/'supabase/operations/20261029_install_catalogue_v1.sql'
target.write_text('\n'.join(sql))
print(name,(folder/name).stat().st_size,'bytes; installer',target.stat().st_size,'bytes')

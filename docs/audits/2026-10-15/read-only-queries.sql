-- Audit en lecture seule. Les claims utilisés sont synthétiques.
-- Aucun INSERT / UPDATE / DELETE / DDL sur le projet distant.

-- structure
select jsonb_build_object(
'server_version',current_setting('server_version'),
'tables',(select jsonb_agg(jsonb_build_object('name',c.relname,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,'bytes',pg_total_relation_size(c.oid),'approx_rows',c.reltuples,'acl',c.relacl)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r'),
'columns',(select jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'type',data_type,'nullable',is_nullable,'default',column_default,'identity',is_identity) order by table_name,ordinal_position) from information_schema.columns where table_schema='public'),
'constraints',(select jsonb_agg(jsonb_build_object('table',r.relname,'name',c.conname,'type',c.contype,'definition',pg_get_constraintdef(c.oid),'validated',c.convalidated)) from pg_constraint c join pg_class r on r.oid=c.conrelid join pg_namespace n on n.oid=r.relnamespace where n.nspname='public'),
'indexes',(select jsonb_agg(jsonb_build_object('table',tablename,'name',indexname,'definition',indexdef)) from pg_indexes where schemaname='public'),
'extensions',(select jsonb_agg(jsonb_build_object('name',extname,'version',extversion)) from pg_extension)
) as audit;

-- access
select jsonb_build_object(
'policies',(select jsonb_agg(to_jsonb(p)) from pg_policies p where schemaname='public'),
'functions',(select jsonb_agg(jsonb_build_object('name',p.proname,'signature',pg_get_function_identity_arguments(p.oid),'definer',p.prosecdef,'config',p.proconfig,'acl',p.proacl,'definition',pg_get_functiondef(p.oid))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f'),
'triggers',(select jsonb_agg(jsonb_build_object('table',c.relname,'definition',pg_get_triggerdef(t.oid))) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal),
'views',(select jsonb_agg(jsonb_build_object('name',c.relname,'options',c.reloptions,'definition',pg_get_viewdef(c.oid))) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('v','m'))
) as audit;

-- quality
with p as (select *, case when code_ean ~ '^([0-9]{8}|[0-9]{12,14})$' then
(select sum(substring(code_ean from i for 1)::int*case when (length(code_ean)-i)%2=0 then 1 else 3 end)%10=0 from generate_series(1,length(code_ean)) i) else false end as valid_gtin from public.produits)
select jsonb_build_object(
'counts',jsonb_build_object('tables',10,'products',(select count(*) from p),'published',(select count(*) from p where catalogue_verifie),'unverified',(select count(*) from p where not catalogue_verifie),'offers',(select count(*) from public.produits_fournisseurs),'verified_offers',(select count(*) from public.produits_fournisseurs where reference_verifiee),'categories',(select count(*) from public.categories),'suppliers',(select count(*) from public.fournisseurs)),
'published_completeness',(select jsonb_build_object('categorized',count(*) filter(where categorie_id is not null),'images',count(*) filter(where image_url is not null),'description',count(*) filter(where nullif(btrim(description),'') is not null),'specificite',count(*) filter(where nullif(btrim(specificite),'') is not null),'pdf',count(*) filter(where pdf_url is not null),'valid_gtin',count(*) filter(where valid_gtin),'identity_and_provenance',count(*) filter(where btrim(nom)<>'' and btrim(marque)<>'' and btrim(ref_fabricant)<>'' and source_catalogue is not null and catalogue_verifie_le is not null)) from p where catalogue_verifie),
'conflicts',jsonb_build_object(
'normalized_identity',(select count(*) from (select lower(btrim(marque)),lower(btrim(ref_fabricant)) from p group by 1,2 having count(*)>1) d),
'normalized_gtin',(select count(*) from (select lpad(code_ean,14,'0') from p where code_ean is not null group by 1 having count(*)>1) d),
'normalized_supplier_sku',(select count(*) from (select fournisseur_id,lower(btrim(ref_fournisseur)) from public.produits_fournisseurs where ref_fournisseur is not null group by 1,2 having count(*)>1) d),
'invalid_gtin_all',(select count(*) from p where code_ean is not null and not valid_gtin),
'blank_names_refs_all',(select count(*) from p where btrim(nom)='' or btrim(ref_fabricant)=''),
'incomplete_verified_offer',(select count(*) from public.produits_fournisseurs where reference_verifiee and (nullif(btrim(ref_fournisseur),'') is null or url_produit is null or reference_verifiee_le is null))
),
'shared_prices',(select jsonb_agg(to_jsonb(t)) from (select nature_prix,count(*) as offers,count(prix) as with_price from public.produits_fournisseurs group by nature_prix order by nature_prix) t),
'verified_by_supplier',(select jsonb_agg(to_jsonb(t)) from (select f.nom,count(*) as verified_offers from public.produits_fournisseurs pf join public.fournisseurs f on f.id=pf.fournisseur_id where pf.reference_verifiee group by f.nom) t),
'fk_without_leading_index',(select jsonb_agg(c.conname) from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace where n.nspname='public' and c.contype='f' and cardinality(c.conkey)=1 and not exists(select 1 from pg_index i where i.indrelid=c.conrelid and i.indisvalid and i.indpred is null and i.indkey[0]=c.conkey[1]))
) as audit;

-- anon
begin read only; set local role anon; select jsonb_build_object(
'role',current_user,'direct_products',(select count(*) from public.produits),
'direct_unverified',(select count(*) from public.produits where not catalogue_verifie),
'direct_offers',(select count(*) from public.produits_fournisseurs),
'legacy_rpc_products',(select count(*) from generate_series(0,4) n cross join lateral public.rechercher_catalogue('',n)),
'current_rpc_products',(select count(*) from generate_series(0,4) n cross join lateral public.rechercher_catalogue_personnel('',n)),
'private_prices_select_grant',has_table_privilege(current_user,'public.prix_personnels','SELECT')
) as audit; rollback;

-- plan
begin read only; set local role anon; explain (analyze, buffers, format json) select * from public.rechercher_catalogue_personnel('prise',0); rollback;

-- expanded_plan
begin read only; set local role anon; explain (analyze,buffers,format json) select p.id,p.ref_fabricant,p.nom,p.marque,p.image_url,
 coalesce((select jsonb_agg(jsonb_build_object(
  'id',pf.id,'fournisseur',f.nom,'prix',pf.prix,'nature_prix',pf.nature_prix,
  'ref_fournisseur',pf.ref_fournisseur,'reference_verifiee',pf.reference_verifiee,
  'conditionnement',pf.conditionnement,'date_verification',pf.date_verification,'url_produit',pf.url_produit)
  order by f.nom) from public.produits_fournisseurs pf join public.fournisseurs f on f.id=pf.fournisseur_id
  where pf.produit_id=p.id and pf.reference_verifiee),'[]'::jsonb)
 from public.produits p where p.catalogue_verifie
 and position(lower(left(coalesce('prise',''),100)) in lower(p.nom || ' ' || p.ref_fabricant || ' ' || p.marque))>0
 order by p.nom,p.id limit 24 offset (greatest(0,least(coalesce(0,0),100000))*24); rollback;

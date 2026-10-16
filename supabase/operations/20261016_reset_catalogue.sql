-- Projet 2HBC (gueuqeqyshhhmxbsiuxg), SQL Editor Supabase.
-- NETTOYAGE AUTORISÉ : 114 produits, 148 offres, 7 lignes de panier de démonstration.
-- Sauvegarde : Sauvegarde_catalogue_2HBC_2026-10-16.zip.
-- Comptes, paniers et fournisseurs conservés. Aucune séquence réinitialisée.
-- Tout est atomique : si un contrôle ou une migration échoue, exécuter ROLLBACK;
-- aucune suppression ne doit être validée séparément.
begin;
set local timezone='UTC';
set local lock_timeout='5s';
set local statement_timeout='60s';
lock table public.produits,public.produits_fournisseurs,public.articles_panier,public.prix_personnels,public.categories,public.fournisseurs in share row exclusive mode;
do $guard$
begin
 if (select md5(backup::text) from (select jsonb_build_object('categories',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.categories t),'fournisseurs',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.fournisseurs t),'produits',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.produits t),'produits_fournisseurs',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.produits_fournisseurs t),'articles_panier',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.articles_panier t),'prix_personnels',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') from public.prix_personnels t)) backup) s) <> 'ddcd60b13e9ee0fda578740b7519c6f1'
 then raise exception 'La base a changé depuis la sauvegarde. Annulation : refaire une sauvegarde et adapter ce script.'; end if;
 if exists(select 1 from supabase_migrations.schema_migrations where version in ('20261012163203','20261013131653','20261015130122'))
 then raise exception 'Une migration est déjà appliquée. Revoir le plan avant nettoyage.'; end if;
end $guard$;
delete from public.articles_panier where offre_id in (select id from public.produits_fournisseurs);
delete from public.prix_personnels where offre_id in (select id from public.produits_fournisseurs);
delete from public.produits_fournisseurs;
delete from public.produits;

-- 20261012163203_catalogue_integrity_import.sql
-- GTIN-8/12/13/14 : longueur ET clé de contrôle, références conservées en texte.
create function public.gtin_valide(code text) returns boolean
language sql immutable strict parallel safe security invoker set search_path='' as $$
 select case when code ~ '^([0-9]{8}|[0-9]{12,14})$' then
   (select sum(substring(code from i for 1)::int *
      case when (length(code)-i)%2=0 then 1 else 3 end)%10=0
    from generate_series(1,length(code)) i)
 else false end;
$$;
revoke all on function public.gtin_valide(text) from public;
grant execute on function public.gtin_valide(text) to anon,authenticated,service_role;

alter table public.produits
 add constraint produits_identite_non_vide check (btrim(nom)<>'' and btrim(ref_fabricant)<>''),
 add constraint produits_gtin_valide check (code_ean is null or public.gtin_valide(code_ean)),
 add constraint produits_verification_complete check (not catalogue_verifie or
   (btrim(marque)<>'' and code_ean is not null and source_catalogue is not null and catalogue_verifie_le is not null));
create unique index produits_identite_normalisee on public.produits(lower(btrim(marque)),lower(btrim(ref_fabricant)));
create unique index produits_gtin_unique on public.produits(lpad(code_ean,14,'0')) where code_ean is not null;
alter table public.produits_fournisseurs
 add constraint offres_reference_non_vide check (ref_fournisseur is null or btrim(ref_fournisseur)<>''),
 add constraint offres_verification_complete check (not reference_verifiee or
   (ref_fournisseur is not null and url_produit is not null and reference_verifiee_le is not null));
create unique index offres_reference_unique on public.produits_fournisseurs(fournisseur_id,lower(btrim(ref_fournisseur))) where ref_fournisseur is not null;
alter table public.categories add constraint categories_nom_non_vide check(btrim(nom)<>'');
create unique index categories_fratrie_unique on public.categories(parent_id,lower(btrim(nom))) nulls not distinct;
alter table public.fournisseurs add constraint fournisseurs_nom_non_vide check(btrim(nom)<>'');
create unique index fournisseurs_nom_normalise on public.fournisseurs(lower(btrim(nom)));

-- Retire le chevauchement SELECT de FOR ALL sans élargir les droits de lecture.
do $$
declare item record;
begin
 for item in select * from (values ('segments_clients','segments'),('categories','categories'),
   ('fournisseurs','fournisseurs'),('produits','produits'),('produits_fournisseurs','offres')) x(tbl,prefix) loop
  execute format('drop policy %I on public.%I',item.prefix||'_admin',item.tbl);
  execute format('create policy %I on public.%I for insert to authenticated with check ((select auth.jwt())->''app_metadata''->>''role''=''admin'')',item.prefix||'_admin_creation',item.tbl);
  execute format('create policy %I on public.%I for update to authenticated using ((select auth.jwt())->''app_metadata''->>''role''=''admin'') with check ((select auth.jwt())->''app_metadata''->>''role''=''admin'')',item.prefix||'_admin_modification',item.tbl);
  execute format('create policy %I on public.%I for delete to authenticated using ((select auth.jwt())->''app_metadata''->>''role''=''admin'')',item.prefix||'_admin_suppression',item.tbl);
 end loop;
end $$;

-- Historique des fiches publiques collectées. Aucun prix/cookie/HTML brut.
-- JSONB garde le contrat du collecteur et la provenance de chaque fournisseur.
create table public.collectes_catalogue (
 empreinte text primary key check(empreinte ~ '^[a-f0-9]{64}$'),
 donnees jsonb not null check(jsonb_typeof(donnees)='object' and octet_length(donnees::text)<=64000),
 statut text not null default 'pending' check(statut in ('pending','imported')),
 produit_id bigint references public.produits(id) on delete restrict,
 cree_le timestamptz not null default now(),
 valide_le timestamptz,
 check ((statut='pending' and produit_id is null and valide_le is null)
     or (statut='imported' and produit_id is not null and valide_le is not null))
);
create index collectes_catalogue_produit on public.collectes_catalogue(produit_id);
alter table public.collectes_catalogue enable row level security;
revoke all on public.collectes_catalogue from anon,authenticated;
grant select,insert,update,delete on public.collectes_catalogue to authenticated;
grant all on public.collectes_catalogue to service_role;
create policy collectes_admin on public.collectes_catalogue for all to authenticated
 using ((select auth.jwt())->'app_metadata'->>'role'='admin')
 with check ((select auth.jwt())->'app_metadata'->>'role'='admin');

-- Un appel = une fiche atomique. Le fichier SQL entoure le lot entier d'une transaction.
-- Les droits de l'appelant restent en vigueur, aucun SECURITY DEFINER.
create function public.importer_produit_collecte(fiche jsonb, approuver boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 champ text; offre jsonb; cat jsonb; host_pattern text; instant timestamptz;
 payload jsonb; digest text; collecte public.collectes_catalogue%rowtype;
 produit public.produits%rowtype; existante public.produits_fournisseurs%rowtype;
 fid bigint; fournisseurs_vus text[] := '{}';
begin
 if current_user not in ('postgres','service_role') and
    coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then
  raise exception 'Import réservé à un administrateur' using errcode='42501';
 end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or approuver is null then
  raise exception 'Fiche invalide' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_object_keys(fiche) k where k not in
   ('brand','reference','ean','name','categories','review_status','offers')) then
  raise exception 'Champs produit inconnus : ni prix ni données de compte acceptés';
 end if;
 foreach champ in array array['brand','reference','ean','name'] loop
  if jsonb_typeof(fiche->champ) is distinct from 'string' or btrim(fiche->>champ)='' or
    length(fiche->>champ)>(case champ when 'reference' then 100 when 'brand' then 200 when 'ean' then 14 else 1000 end) then
   raise exception 'Champ produit invalide : %',champ;
  end if;
 end loop;
 if not public.gtin_valide(fiche->>'ean') or coalesce(fiche->>'review_status','') not in ('pending','approved') then
  raise exception 'EAN ou statut de revue invalide';
 end if;
 if approuver and fiche->>'review_status'<>'approved' then
  raise exception 'Relire la fiche puis la marquer approved avant publication';
 end if;
 if jsonb_typeof(fiche->'categories') is distinct from 'array' then raise exception 'Catégories de découverte attendues'; end if;
 if jsonb_array_length(fiche->'categories')>20 then raise exception 'Trop de catégories'; end if;
 for cat in select value from jsonb_array_elements(fiche->'categories') loop
  if jsonb_typeof(cat)<>'string' or length(btrim(cat#>>'{}')) not between 1 and 200 then raise exception 'Catégorie invalide'; end if;
 end loop;
 if jsonb_typeof(fiche->'offers') is distinct from 'array' then raise exception 'Offres attendues'; end if;
 if jsonb_array_length(fiche->'offers') not between 1 and 2 then raise exception 'Une ou deux offres requises'; end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  if jsonb_typeof(offre)<>'object' then raise exception 'Offre invalide'; end if;
  if exists(select 1 from jsonb_object_keys(offre) k where k not in
    ('supplier','reference','url','pack','collected_at','page_sha256')) then raise exception 'Champs offre inconnus'; end if;
  foreach champ in array array['supplier','reference','url','collected_at','page_sha256'] loop
   if jsonb_typeof(offre->champ) is distinct from 'string' or btrim(offre->>champ)='' or
    length(offre->>champ)>(case champ when 'url' then 2000 else 100 end) then raise exception 'Champ offre invalide : %',champ; end if;
  end loop;
  if offre->>'supplier' not in ('Rexel','Sonepar') or (offre->>'supplier')=any(fournisseurs_vus) then raise exception 'Fournisseur inconnu ou répété'; end if;
  fournisseurs_vus := array_append(fournisseurs_vus,offre->>'supplier');
  host_pattern := case offre->>'supplier'
   when 'Rexel' then '^https://www[.]rexel[.]fr/frx/([^?#[:space:]]+/)?p/[0-9]+$'
   else '^https://www[.]sonepar[.]fr/catalog/fr-fr/products/[^/?#[:space:]]+$' end;
  if offre->>'url' !~ host_pattern then raise exception 'URL produit officielle requise'; end if;
  if offre ? 'pack' and offre->'pack'<>'null'::jsonb and
    (jsonb_typeof(offre->'pack')<>'string' or length(btrim(offre->>'pack')) not between 1 and 1000) then raise exception 'Conditionnement invalide'; end if;
  if offre->>'page_sha256' !~ '^[a-f0-9]{64}$' or offre->>'collected_at' !~
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'Provenance invalide'; end if;
  instant := (offre->>'collected_at')::timestamptz;
  if instant>now()+interval '5 minutes' then raise exception 'Collecte dans le futur'; end if;
 end loop;

 payload := fiche-'review_status';
 digest := encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 -- Verrou commun avant les verrous de lignes pour un ordre stable entre lots concurrents.
 perform pg_advisory_xact_lock(2042,1);
 insert into public.collectes_catalogue(empreinte,donnees) values(digest,payload) on conflict(empreinte) do nothing;
 select * into collecte from public.collectes_catalogue where empreinte=digest for update;
 if not approuver or collecte.statut='imported' then
  return jsonb_build_object('empreinte',digest,'statut',collecte.statut,'produit_id',collecte.produit_id);
 end if;

 select * into produit from public.produits p where lower(btrim(p.marque))=lower(btrim(fiche->>'brand'))
  and lower(btrim(p.ref_fabricant))=lower(btrim(fiche->>'reference')) for update;
 if found then
  if produit.code_ean is not null and lpad(produit.code_ean,14,'0')<>lpad(fiche->>'ean',14,'0') then raise exception 'Conflit EAN pour la référence fabricant'; end if;
  update public.produits set code_ean=coalesce(code_ean,fiche->>'ean'),catalogue_verifie=true,
   source_catalogue=coalesce(source_catalogue,fiche->'offers'->0->>'url'),
   catalogue_verifie_le=coalesce(catalogue_verifie_le,now()) where id=produit.id;
 else
  insert into public.produits(marque,ref_fabricant,code_ean,nom,catalogue_verifie,source_catalogue,catalogue_verifie_le)
   values(btrim(fiche->>'brand'),btrim(fiche->>'reference'),fiche->>'ean',btrim(fiche->>'name'),true,fiche->'offers'->0->>'url',now()) returning * into produit;
 end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  select id into fid from public.fournisseurs where lower(btrim(nom))=lower(offre->>'supplier');
  if not found then
   insert into public.fournisseurs(nom,site_web) values(offre->>'supplier',case offre->>'supplier' when 'Rexel' then 'https://www.rexel.fr' else 'https://www.sonepar.fr' end) returning id into fid;
  end if;
  select * into existante from public.produits_fournisseurs where produit_id=produit.id and fournisseur_id=fid for update;
  if found then
   if (existante.ref_fournisseur is not null and lower(btrim(existante.ref_fournisseur))<>lower(btrim(offre->>'reference')))
     or (existante.url_produit is not null and existante.url_produit<>offre->>'url') then
    raise exception 'Référence ou URL déjà associée différente : résolution manuelle nécessaire';
   end if;
   update public.produits_fournisseurs set ref_fournisseur=coalesce(ref_fournisseur,btrim(offre->>'reference')),
    url_produit=coalesce(url_produit,offre->>'url'),conditionnement=coalesce(conditionnement,offre->>'pack'),
    reference_verifiee=true,reference_verifiee_le=coalesce(reference_verifiee_le,now()) where id=existante.id;
  else
   insert into public.produits_fournisseurs(produit_id,fournisseur_id,ref_fournisseur,prix,nature_prix,conditionnement,url_produit,reference_verifiee,reference_verifiee_le)
    values(produit.id,fid,btrim(offre->>'reference'),null,'public',offre->>'pack',offre->>'url',true,now());
  end if;
 end loop;
 update public.collectes_catalogue set statut='imported',produit_id=produit.id,valide_le=now() where empreinte=digest;
 return jsonb_build_object('empreinte',digest,'statut','imported','produit_id',produit.id);
end;
$$;
revoke all on function public.importer_produit_collecte(jsonb,boolean) from public;
grant execute on function public.importer_produit_collecte(jsonb,boolean) to authenticated,service_role;

-- Même contrat pour le site ; l'EAN devient aussi une clé de recherche.
create or replace function public.rechercher_catalogue_personnel(terme text default '', page_num integer default 0)
returns table(id bigint, ref_fabricant text, nom text, marque text, image_url text, offres jsonb)
language sql stable security invoker set search_path='' as $$
 select p.id,p.ref_fabricant,p.nom,p.marque,p.image_url,
 coalesce((select jsonb_agg(jsonb_build_object(
  'id',pf.id,'fournisseur',f.nom,'prix',pf.prix,'nature_prix',pf.nature_prix,
  'ref_fournisseur',pf.ref_fournisseur,'reference_verifiee',pf.reference_verifiee,
  'conditionnement',pf.conditionnement,'date_verification',pf.date_verification,'url_produit',pf.url_produit)
  order by f.nom) from public.produits_fournisseurs pf join public.fournisseurs f on f.id=pf.fournisseur_id
  where pf.produit_id=p.id and pf.reference_verifiee),'[]'::jsonb)
 from public.produits p where p.catalogue_verifie
 and position(lower(left(coalesce(terme,''),100)) in lower(p.nom || ' ' || p.ref_fabricant || ' ' || p.marque || ' ' || coalesce(p.code_ean,'')))>0
 order by p.nom,p.id limit 24 offset (greatest(0,least(coalesce(page_num,0),100000))*24);
$$;


insert into supabase_migrations.schema_migrations(version,name,statements) values('20261012163203','catalogue_integrity_import',array[$migration_20261012163203$begin;

-- GTIN-8/12/13/14 : longueur ET clé de contrôle, références conservées en texte.
create function public.gtin_valide(code text) returns boolean
language sql immutable strict parallel safe security invoker set search_path='' as $$
 select case when code ~ '^([0-9]{8}|[0-9]{12,14})$' then
   (select sum(substring(code from i for 1)::int *
      case when (length(code)-i)%2=0 then 1 else 3 end)%10=0
    from generate_series(1,length(code)) i)
 else false end;
$$;
revoke all on function public.gtin_valide(text) from public;
grant execute on function public.gtin_valide(text) to anon,authenticated,service_role;

alter table public.produits
 add constraint produits_identite_non_vide check (btrim(nom)<>'' and btrim(ref_fabricant)<>''),
 add constraint produits_gtin_valide check (code_ean is null or public.gtin_valide(code_ean)),
 add constraint produits_verification_complete check (not catalogue_verifie or
   (btrim(marque)<>'' and code_ean is not null and source_catalogue is not null and catalogue_verifie_le is not null));
create unique index produits_identite_normalisee on public.produits(lower(btrim(marque)),lower(btrim(ref_fabricant)));
create unique index produits_gtin_unique on public.produits(lpad(code_ean,14,'0')) where code_ean is not null;
alter table public.produits_fournisseurs
 add constraint offres_reference_non_vide check (ref_fournisseur is null or btrim(ref_fournisseur)<>''),
 add constraint offres_verification_complete check (not reference_verifiee or
   (ref_fournisseur is not null and url_produit is not null and reference_verifiee_le is not null));
create unique index offres_reference_unique on public.produits_fournisseurs(fournisseur_id,lower(btrim(ref_fournisseur))) where ref_fournisseur is not null;
alter table public.categories add constraint categories_nom_non_vide check(btrim(nom)<>'');
create unique index categories_fratrie_unique on public.categories(parent_id,lower(btrim(nom))) nulls not distinct;
alter table public.fournisseurs add constraint fournisseurs_nom_non_vide check(btrim(nom)<>'');
create unique index fournisseurs_nom_normalise on public.fournisseurs(lower(btrim(nom)));

-- Retire le chevauchement SELECT de FOR ALL sans élargir les droits de lecture.
do $$
declare item record;
begin
 for item in select * from (values ('segments_clients','segments'),('categories','categories'),
   ('fournisseurs','fournisseurs'),('produits','produits'),('produits_fournisseurs','offres')) x(tbl,prefix) loop
  execute format('drop policy %I on public.%I',item.prefix||'_admin',item.tbl);
  execute format('create policy %I on public.%I for insert to authenticated with check ((select auth.jwt())->''app_metadata''->>''role''=''admin'')',item.prefix||'_admin_creation',item.tbl);
  execute format('create policy %I on public.%I for update to authenticated using ((select auth.jwt())->''app_metadata''->>''role''=''admin'') with check ((select auth.jwt())->''app_metadata''->>''role''=''admin'')',item.prefix||'_admin_modification',item.tbl);
  execute format('create policy %I on public.%I for delete to authenticated using ((select auth.jwt())->''app_metadata''->>''role''=''admin'')',item.prefix||'_admin_suppression',item.tbl);
 end loop;
end $$;

-- Historique des fiches publiques collectées. Aucun prix/cookie/HTML brut.
-- JSONB garde le contrat du collecteur et la provenance de chaque fournisseur.
create table public.collectes_catalogue (
 empreinte text primary key check(empreinte ~ '^[a-f0-9]{64}$'),
 donnees jsonb not null check(jsonb_typeof(donnees)='object' and octet_length(donnees::text)<=64000),
 statut text not null default 'pending' check(statut in ('pending','imported')),
 produit_id bigint references public.produits(id) on delete restrict,
 cree_le timestamptz not null default now(),
 valide_le timestamptz,
 check ((statut='pending' and produit_id is null and valide_le is null)
     or (statut='imported' and produit_id is not null and valide_le is not null))
);
create index collectes_catalogue_produit on public.collectes_catalogue(produit_id);
alter table public.collectes_catalogue enable row level security;
revoke all on public.collectes_catalogue from anon,authenticated;
grant select,insert,update,delete on public.collectes_catalogue to authenticated;
grant all on public.collectes_catalogue to service_role;
create policy collectes_admin on public.collectes_catalogue for all to authenticated
 using ((select auth.jwt())->'app_metadata'->>'role'='admin')
 with check ((select auth.jwt())->'app_metadata'->>'role'='admin');

-- Un appel = une fiche atomique. Le fichier SQL entoure le lot entier d'une transaction.
-- Les droits de l'appelant restent en vigueur, aucun SECURITY DEFINER.
create function public.importer_produit_collecte(fiche jsonb, approuver boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 champ text; offre jsonb; cat jsonb; host_pattern text; instant timestamptz;
 payload jsonb; digest text; collecte public.collectes_catalogue%rowtype;
 produit public.produits%rowtype; existante public.produits_fournisseurs%rowtype;
 fid bigint; fournisseurs_vus text[] := '{}';
begin
 if current_user not in ('postgres','service_role') and
    coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then
  raise exception 'Import réservé à un administrateur' using errcode='42501';
 end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or approuver is null then
  raise exception 'Fiche invalide' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_object_keys(fiche) k where k not in
   ('brand','reference','ean','name','categories','review_status','offers')) then
  raise exception 'Champs produit inconnus : ni prix ni données de compte acceptés';
 end if;
 foreach champ in array array['brand','reference','ean','name'] loop
  if jsonb_typeof(fiche->champ) is distinct from 'string' or btrim(fiche->>champ)='' or
    length(fiche->>champ)>(case champ when 'reference' then 100 when 'brand' then 200 when 'ean' then 14 else 1000 end) then
   raise exception 'Champ produit invalide : %',champ;
  end if;
 end loop;
 if not public.gtin_valide(fiche->>'ean') or coalesce(fiche->>'review_status','') not in ('pending','approved') then
  raise exception 'EAN ou statut de revue invalide';
 end if;
 if approuver and fiche->>'review_status'<>'approved' then
  raise exception 'Relire la fiche puis la marquer approved avant publication';
 end if;
 if jsonb_typeof(fiche->'categories') is distinct from 'array' then raise exception 'Catégories de découverte attendues'; end if;
 if jsonb_array_length(fiche->'categories')>20 then raise exception 'Trop de catégories'; end if;
 for cat in select value from jsonb_array_elements(fiche->'categories') loop
  if jsonb_typeof(cat)<>'string' or length(btrim(cat#>>'{}')) not between 1 and 200 then raise exception 'Catégorie invalide'; end if;
 end loop;
 if jsonb_typeof(fiche->'offers') is distinct from 'array' then raise exception 'Offres attendues'; end if;
 if jsonb_array_length(fiche->'offers') not between 1 and 2 then raise exception 'Une ou deux offres requises'; end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  if jsonb_typeof(offre)<>'object' then raise exception 'Offre invalide'; end if;
  if exists(select 1 from jsonb_object_keys(offre) k where k not in
    ('supplier','reference','url','pack','collected_at','page_sha256')) then raise exception 'Champs offre inconnus'; end if;
  foreach champ in array array['supplier','reference','url','collected_at','page_sha256'] loop
   if jsonb_typeof(offre->champ) is distinct from 'string' or btrim(offre->>champ)='' or
    length(offre->>champ)>(case champ when 'url' then 2000 else 100 end) then raise exception 'Champ offre invalide : %',champ; end if;
  end loop;
  if offre->>'supplier' not in ('Rexel','Sonepar') or (offre->>'supplier')=any(fournisseurs_vus) then raise exception 'Fournisseur inconnu ou répété'; end if;
  fournisseurs_vus := array_append(fournisseurs_vus,offre->>'supplier');
  host_pattern := case offre->>'supplier'
   when 'Rexel' then '^https://www[.]rexel[.]fr/frx/([^?#[:space:]]+/)?p/[0-9]+$'
   else '^https://www[.]sonepar[.]fr/catalog/fr-fr/products/[^/?#[:space:]]+$' end;
  if offre->>'url' !~ host_pattern then raise exception 'URL produit officielle requise'; end if;
  if offre ? 'pack' and offre->'pack'<>'null'::jsonb and
    (jsonb_typeof(offre->'pack')<>'string' or length(btrim(offre->>'pack')) not between 1 and 1000) then raise exception 'Conditionnement invalide'; end if;
  if offre->>'page_sha256' !~ '^[a-f0-9]{64}$' or offre->>'collected_at' !~
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'Provenance invalide'; end if;
  instant := (offre->>'collected_at')::timestamptz;
  if instant>now()+interval '5 minutes' then raise exception 'Collecte dans le futur'; end if;
 end loop;

 payload := fiche-'review_status';
 digest := encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 -- Verrou commun avant les verrous de lignes pour un ordre stable entre lots concurrents.
 perform pg_advisory_xact_lock(2042,1);
 insert into public.collectes_catalogue(empreinte,donnees) values(digest,payload) on conflict(empreinte) do nothing;
 select * into collecte from public.collectes_catalogue where empreinte=digest for update;
 if not approuver or collecte.statut='imported' then
  return jsonb_build_object('empreinte',digest,'statut',collecte.statut,'produit_id',collecte.produit_id);
 end if;

 select * into produit from public.produits p where lower(btrim(p.marque))=lower(btrim(fiche->>'brand'))
  and lower(btrim(p.ref_fabricant))=lower(btrim(fiche->>'reference')) for update;
 if found then
  if produit.code_ean is not null and lpad(produit.code_ean,14,'0')<>lpad(fiche->>'ean',14,'0') then raise exception 'Conflit EAN pour la référence fabricant'; end if;
  update public.produits set code_ean=coalesce(code_ean,fiche->>'ean'),catalogue_verifie=true,
   source_catalogue=coalesce(source_catalogue,fiche->'offers'->0->>'url'),
   catalogue_verifie_le=coalesce(catalogue_verifie_le,now()) where id=produit.id;
 else
  insert into public.produits(marque,ref_fabricant,code_ean,nom,catalogue_verifie,source_catalogue,catalogue_verifie_le)
   values(btrim(fiche->>'brand'),btrim(fiche->>'reference'),fiche->>'ean',btrim(fiche->>'name'),true,fiche->'offers'->0->>'url',now()) returning * into produit;
 end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  select id into fid from public.fournisseurs where lower(btrim(nom))=lower(offre->>'supplier');
  if not found then
   insert into public.fournisseurs(nom,site_web) values(offre->>'supplier',case offre->>'supplier' when 'Rexel' then 'https://www.rexel.fr' else 'https://www.sonepar.fr' end) returning id into fid;
  end if;
  select * into existante from public.produits_fournisseurs where produit_id=produit.id and fournisseur_id=fid for update;
  if found then
   if (existante.ref_fournisseur is not null and lower(btrim(existante.ref_fournisseur))<>lower(btrim(offre->>'reference')))
     or (existante.url_produit is not null and existante.url_produit<>offre->>'url') then
    raise exception 'Référence ou URL déjà associée différente : résolution manuelle nécessaire';
   end if;
   update public.produits_fournisseurs set ref_fournisseur=coalesce(ref_fournisseur,btrim(offre->>'reference')),
    url_produit=coalesce(url_produit,offre->>'url'),conditionnement=coalesce(conditionnement,offre->>'pack'),
    reference_verifiee=true,reference_verifiee_le=coalesce(reference_verifiee_le,now()) where id=existante.id;
  else
   insert into public.produits_fournisseurs(produit_id,fournisseur_id,ref_fournisseur,prix,nature_prix,conditionnement,url_produit,reference_verifiee,reference_verifiee_le)
    values(produit.id,fid,btrim(offre->>'reference'),null,'public',offre->>'pack',offre->>'url',true,now());
  end if;
 end loop;
 update public.collectes_catalogue set statut='imported',produit_id=produit.id,valide_le=now() where empreinte=digest;
 return jsonb_build_object('empreinte',digest,'statut','imported','produit_id',produit.id);
end;
$$;
revoke all on function public.importer_produit_collecte(jsonb,boolean) from public;
grant execute on function public.importer_produit_collecte(jsonb,boolean) to authenticated,service_role;

-- Même contrat pour le site ; l'EAN devient aussi une clé de recherche.
create or replace function public.rechercher_catalogue_personnel(terme text default '', page_num integer default 0)
returns table(id bigint, ref_fabricant text, nom text, marque text, image_url text, offres jsonb)
language sql stable security invoker set search_path='' as $$
 select p.id,p.ref_fabricant,p.nom,p.marque,p.image_url,
 coalesce((select jsonb_agg(jsonb_build_object(
  'id',pf.id,'fournisseur',f.nom,'prix',pf.prix,'nature_prix',pf.nature_prix,
  'ref_fournisseur',pf.ref_fournisseur,'reference_verifiee',pf.reference_verifiee,
  'conditionnement',pf.conditionnement,'date_verification',pf.date_verification,'url_produit',pf.url_produit)
  order by f.nom) from public.produits_fournisseurs pf join public.fournisseurs f on f.id=pf.fournisseur_id
  where pf.produit_id=p.id and pf.reference_verifiee),'[]'::jsonb)
 from public.produits p where p.catalogue_verifie
 and position(lower(left(coalesce(terme,''),100)) in lower(p.nom || ' ' || p.ref_fabricant || ' ' || p.marque || ' ' || coalesce(p.code_ean,'')))>0
 order by p.nom,p.id limit 24 offset (greatest(0,least(coalesce(page_num,0),100000))*24);
$$;

commit;
$migration_20261012163203$]);

-- 20261013131653_catalogue_images.sql
alter table public.produits add column image_source_url text
 check(image_source_url is null or image_source_url ~ '^https://www[.](rexel|sonepar)[.]fr/');
alter table public.produits add column image_verifiee_le timestamptz;

-- Routes média publiques observées dans les fiches officielles, pas des API privées.
create function public.image_catalogue_valide(lien text,fournisseur text) returns boolean
language sql immutable strict parallel safe security invoker set search_path='' as $$
 select length(lien)<=2000 and case fournisseur
  when 'Rexel' then lien ~ '^https://api[.]rexel[.]fr/media/api/fr/content/[0-9]+/[A-Z_]+$'
  when 'Sonepar' then lien ~ '^https://fra-connect[.]mo[.]cloudinary[.]net/PRODUCT/IMAGE/[0-9]+/[A-Za-z0-9_.-]+[.](jpg|jpeg|png|webp|JPG|JPEG|PNG|WEBP)([?](ts=[0-9]{1,20}(&type=(xsmall|small|medium|large))?|type=(xsmall|small|medium|large)(&ts=[0-9]{1,20})?))?$'
  else false end;
$$;
revoke all on function public.image_catalogue_valide(text,text) from public;
grant execute on function public.image_catalogue_valide(text,text) to anon,authenticated,service_role;

-- Extension additive du contrat : les anciennes collectes sans image restent valides.
create or replace function public.importer_produit_collecte(fiche jsonb, approuver boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 champ text; offre jsonb; cat jsonb; host_pattern text; instant timestamptz;
 payload jsonb; digest text; collecte public.collectes_catalogue%rowtype;
 produit public.produits%rowtype; existante public.produits_fournisseurs%rowtype;
 fid bigint; fournisseurs_vus text[] := '{}';
begin
 if current_user not in ('postgres','service_role') and
    coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then
  raise exception 'Import réservé à un administrateur' using errcode='42501';
 end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or approuver is null then
  raise exception 'Fiche invalide' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_object_keys(fiche) k where k not in
   ('brand','reference','ean','name','categories','review_status','offers')) then
  raise exception 'Champs produit inconnus : ni prix ni données de compte acceptés';
 end if;
 foreach champ in array array['brand','reference','ean','name'] loop
  if jsonb_typeof(fiche->champ) is distinct from 'string' or btrim(fiche->>champ)='' or
    length(fiche->>champ)>(case champ when 'reference' then 100 when 'brand' then 200 when 'ean' then 14 else 1000 end) then
   raise exception 'Champ produit invalide : %',champ;
  end if;
 end loop;
 if not public.gtin_valide(fiche->>'ean') or coalesce(fiche->>'review_status','') not in ('pending','approved') then
  raise exception 'EAN ou statut de revue invalide';
 end if;
 if approuver and fiche->>'review_status'<>'approved' then
  raise exception 'Relire la fiche puis la marquer approved avant publication';
 end if;
 if jsonb_typeof(fiche->'categories') is distinct from 'array' then raise exception 'Catégories de découverte attendues'; end if;
 if jsonb_array_length(fiche->'categories')>20 then raise exception 'Trop de catégories'; end if;
 for cat in select value from jsonb_array_elements(fiche->'categories') loop
  if jsonb_typeof(cat)<>'string' or length(btrim(cat#>>'{}')) not between 1 and 200 then raise exception 'Catégorie invalide'; end if;
 end loop;
 if jsonb_typeof(fiche->'offers') is distinct from 'array' then raise exception 'Offres attendues'; end if;
 if jsonb_array_length(fiche->'offers') not between 1 and 2 then raise exception 'Une ou deux offres requises'; end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  if jsonb_typeof(offre)<>'object' then raise exception 'Offre invalide'; end if;
  if exists(select 1 from jsonb_object_keys(offre) k where k not in
    ('supplier','reference','url','pack','collected_at','page_sha256','image_url')) then raise exception 'Champs offre inconnus'; end if;
  foreach champ in array array['supplier','reference','url','collected_at','page_sha256'] loop
   if jsonb_typeof(offre->champ) is distinct from 'string' or btrim(offre->>champ)='' or
    length(offre->>champ)>(case champ when 'url' then 2000 else 100 end) then raise exception 'Champ offre invalide : %',champ; end if;
  end loop;
  if offre->>'supplier' not in ('Rexel','Sonepar') or (offre->>'supplier')=any(fournisseurs_vus) then raise exception 'Fournisseur inconnu ou répété'; end if;
  fournisseurs_vus := array_append(fournisseurs_vus,offre->>'supplier');
  host_pattern := case offre->>'supplier'
   when 'Rexel' then '^https://www[.]rexel[.]fr/frx/([^?#[:space:]]+/)?p/[0-9]+$'
   else '^https://www[.]sonepar[.]fr/catalog/fr-fr/products/[^/?#[:space:]]+$' end;
  if offre->>'url' !~ host_pattern then raise exception 'URL produit officielle requise'; end if;
  if offre ? 'image_url' and offre->'image_url'<>'null'::jsonb and
    (jsonb_typeof(offre->'image_url')<>'string' or not public.image_catalogue_valide(offre->>'image_url',offre->>'supplier')) then
   raise exception 'Photo : média officiel du fournisseur attendu';
  end if;
  if offre->>'image_url' is not null and offre->>'supplier'='Rexel' and
   substring(offre->>'image_url' from '/content/([0-9]+)/') is distinct from substring(offre->>'url' from '/p/([0-9]+)$') then
   raise exception 'Photo Rexel associée à une autre fiche produit';
  end if;
  if offre ? 'pack' and offre->'pack'<>'null'::jsonb and
    (jsonb_typeof(offre->'pack')<>'string' or length(btrim(offre->>'pack')) not between 1 and 1000) then raise exception 'Conditionnement invalide'; end if;
  if offre->>'page_sha256' !~ '^[a-f0-9]{64}$' or offre->>'collected_at' !~
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'Provenance invalide'; end if;
  instant := (offre->>'collected_at')::timestamptz;
  if instant>now()+interval '5 minutes' then raise exception 'Collecte dans le futur'; end if;
 end loop;

 payload := fiche-'review_status';
 digest := encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 -- Verrou commun avant les verrous de lignes pour un ordre stable entre lots concurrents.
 perform pg_advisory_xact_lock(2042,1);
 insert into public.collectes_catalogue(empreinte,donnees) values(digest,payload) on conflict(empreinte) do nothing;
 select * into collecte from public.collectes_catalogue where empreinte=digest for update;
 if not approuver or collecte.statut='imported' then
  return jsonb_build_object('empreinte',digest,'statut',collecte.statut,'produit_id',collecte.produit_id);
 end if;

 select * into produit from public.produits p where lower(btrim(p.marque))=lower(btrim(fiche->>'brand'))
  and lower(btrim(p.ref_fabricant))=lower(btrim(fiche->>'reference')) for update;
 if found then
  if produit.code_ean is not null and lpad(produit.code_ean,14,'0')<>lpad(fiche->>'ean',14,'0') then raise exception 'Conflit EAN pour la référence fabricant'; end if;
  update public.produits set code_ean=coalesce(code_ean,fiche->>'ean'),catalogue_verifie=true,
   source_catalogue=coalesce(source_catalogue,fiche->'offers'->0->>'url'),
   catalogue_verifie_le=coalesce(catalogue_verifie_le,now()) where id=produit.id;
 else
  insert into public.produits(marque,ref_fabricant,code_ean,nom,catalogue_verifie,source_catalogue,catalogue_verifie_le)
   values(btrim(fiche->>'brand'),btrim(fiche->>'reference'),fiche->>'ean',btrim(fiche->>'name'),true,fiche->'offers'->0->>'url',now()) returning * into produit;
 end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  select id into fid from public.fournisseurs where lower(btrim(nom))=lower(offre->>'supplier');
  if not found then
   insert into public.fournisseurs(nom,site_web) values(offre->>'supplier',case offre->>'supplier' when 'Rexel' then 'https://www.rexel.fr' else 'https://www.sonepar.fr' end) returning id into fid;
  end if;
  select * into existante from public.produits_fournisseurs where produit_id=produit.id and fournisseur_id=fid for update;
  if found then
   if (existante.ref_fournisseur is not null and lower(btrim(existante.ref_fournisseur))<>lower(btrim(offre->>'reference')))
     or (existante.url_produit is not null and existante.url_produit<>offre->>'url') then
    raise exception 'Référence ou URL déjà associée différente : résolution manuelle nécessaire';
   end if;
   update public.produits_fournisseurs set ref_fournisseur=coalesce(ref_fournisseur,btrim(offre->>'reference')),
    url_produit=coalesce(url_produit,offre->>'url'),conditionnement=coalesce(conditionnement,offre->>'pack'),
    reference_verifiee=true,reference_verifiee_le=coalesce(reference_verifiee_le,now()) where id=existante.id;
  else
   insert into public.produits_fournisseurs(produit_id,fournisseur_id,ref_fournisseur,prix,nature_prix,conditionnement,url_produit,reference_verifiee,reference_verifiee_le)
    values(produit.id,fid,btrim(offre->>'reference'),null,'public',offre->>'pack',offre->>'url',true,now());
  end if;
  if offre->>'image_url' is not null then
   update public.produits set image_url=coalesce(image_url,offre->>'image_url'),
    image_source_url=coalesce(image_source_url,offre->>'url'),image_verifiee_le=coalesce(image_verifiee_le,now())
    where id=produit.id and (image_url is null or (image_url=offre->>'image_url' and image_source_url is null));
  end if;
 end loop;
 update public.collectes_catalogue set statut='imported',produit_id=produit.id,valide_le=now() where empreinte=digest;
 return jsonb_build_object('empreinte',digest,'statut','imported','produit_id',produit.id);
end;
$$;


insert into supabase_migrations.schema_migrations(version,name,statements) values('20261013131653','catalogue_images',array[$migration_20261013131653$begin;
alter table public.produits add column image_source_url text
 check(image_source_url is null or image_source_url ~ '^https://www[.](rexel|sonepar)[.]fr/');
alter table public.produits add column image_verifiee_le timestamptz;

-- Routes média publiques observées dans les fiches officielles, pas des API privées.
create function public.image_catalogue_valide(lien text,fournisseur text) returns boolean
language sql immutable strict parallel safe security invoker set search_path='' as $$
 select length(lien)<=2000 and case fournisseur
  when 'Rexel' then lien ~ '^https://api[.]rexel[.]fr/media/api/fr/content/[0-9]+/[A-Z_]+$'
  when 'Sonepar' then lien ~ '^https://fra-connect[.]mo[.]cloudinary[.]net/PRODUCT/IMAGE/[0-9]+/[A-Za-z0-9_.-]+[.](jpg|jpeg|png|webp|JPG|JPEG|PNG|WEBP)([?](ts=[0-9]{1,20}(&type=(xsmall|small|medium|large))?|type=(xsmall|small|medium|large)(&ts=[0-9]{1,20})?))?$'
  else false end;
$$;
revoke all on function public.image_catalogue_valide(text,text) from public;
grant execute on function public.image_catalogue_valide(text,text) to anon,authenticated,service_role;

-- Extension additive du contrat : les anciennes collectes sans image restent valides.
create or replace function public.importer_produit_collecte(fiche jsonb, approuver boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 champ text; offre jsonb; cat jsonb; host_pattern text; instant timestamptz;
 payload jsonb; digest text; collecte public.collectes_catalogue%rowtype;
 produit public.produits%rowtype; existante public.produits_fournisseurs%rowtype;
 fid bigint; fournisseurs_vus text[] := '{}';
begin
 if current_user not in ('postgres','service_role') and
    coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin' then
  raise exception 'Import réservé à un administrateur' using errcode='42501';
 end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or approuver is null then
  raise exception 'Fiche invalide' using errcode='22023';
 end if;
 if exists(select 1 from jsonb_object_keys(fiche) k where k not in
   ('brand','reference','ean','name','categories','review_status','offers')) then
  raise exception 'Champs produit inconnus : ni prix ni données de compte acceptés';
 end if;
 foreach champ in array array['brand','reference','ean','name'] loop
  if jsonb_typeof(fiche->champ) is distinct from 'string' or btrim(fiche->>champ)='' or
    length(fiche->>champ)>(case champ when 'reference' then 100 when 'brand' then 200 when 'ean' then 14 else 1000 end) then
   raise exception 'Champ produit invalide : %',champ;
  end if;
 end loop;
 if not public.gtin_valide(fiche->>'ean') or coalesce(fiche->>'review_status','') not in ('pending','approved') then
  raise exception 'EAN ou statut de revue invalide';
 end if;
 if approuver and fiche->>'review_status'<>'approved' then
  raise exception 'Relire la fiche puis la marquer approved avant publication';
 end if;
 if jsonb_typeof(fiche->'categories') is distinct from 'array' then raise exception 'Catégories de découverte attendues'; end if;
 if jsonb_array_length(fiche->'categories')>20 then raise exception 'Trop de catégories'; end if;
 for cat in select value from jsonb_array_elements(fiche->'categories') loop
  if jsonb_typeof(cat)<>'string' or length(btrim(cat#>>'{}')) not between 1 and 200 then raise exception 'Catégorie invalide'; end if;
 end loop;
 if jsonb_typeof(fiche->'offers') is distinct from 'array' then raise exception 'Offres attendues'; end if;
 if jsonb_array_length(fiche->'offers') not between 1 and 2 then raise exception 'Une ou deux offres requises'; end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  if jsonb_typeof(offre)<>'object' then raise exception 'Offre invalide'; end if;
  if exists(select 1 from jsonb_object_keys(offre) k where k not in
    ('supplier','reference','url','pack','collected_at','page_sha256','image_url')) then raise exception 'Champs offre inconnus'; end if;
  foreach champ in array array['supplier','reference','url','collected_at','page_sha256'] loop
   if jsonb_typeof(offre->champ) is distinct from 'string' or btrim(offre->>champ)='' or
    length(offre->>champ)>(case champ when 'url' then 2000 else 100 end) then raise exception 'Champ offre invalide : %',champ; end if;
  end loop;
  if offre->>'supplier' not in ('Rexel','Sonepar') or (offre->>'supplier')=any(fournisseurs_vus) then raise exception 'Fournisseur inconnu ou répété'; end if;
  fournisseurs_vus := array_append(fournisseurs_vus,offre->>'supplier');
  host_pattern := case offre->>'supplier'
   when 'Rexel' then '^https://www[.]rexel[.]fr/frx/([^?#[:space:]]+/)?p/[0-9]+$'
   else '^https://www[.]sonepar[.]fr/catalog/fr-fr/products/[^/?#[:space:]]+$' end;
  if offre->>'url' !~ host_pattern then raise exception 'URL produit officielle requise'; end if;
  if offre ? 'image_url' and offre->'image_url'<>'null'::jsonb and
    (jsonb_typeof(offre->'image_url')<>'string' or not public.image_catalogue_valide(offre->>'image_url',offre->>'supplier')) then
   raise exception 'Photo : média officiel du fournisseur attendu';
  end if;
  if offre->>'image_url' is not null and offre->>'supplier'='Rexel' and
   substring(offre->>'image_url' from '/content/([0-9]+)/') is distinct from substring(offre->>'url' from '/p/([0-9]+)$') then
   raise exception 'Photo Rexel associée à une autre fiche produit';
  end if;
  if offre ? 'pack' and offre->'pack'<>'null'::jsonb and
    (jsonb_typeof(offre->'pack')<>'string' or length(btrim(offre->>'pack')) not between 1 and 1000) then raise exception 'Conditionnement invalide'; end if;
  if offre->>'page_sha256' !~ '^[a-f0-9]{64}$' or offre->>'collected_at' !~
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'Provenance invalide'; end if;
  instant := (offre->>'collected_at')::timestamptz;
  if instant>now()+interval '5 minutes' then raise exception 'Collecte dans le futur'; end if;
 end loop;

 payload := fiche-'review_status';
 digest := encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 -- Verrou commun avant les verrous de lignes pour un ordre stable entre lots concurrents.
 perform pg_advisory_xact_lock(2042,1);
 insert into public.collectes_catalogue(empreinte,donnees) values(digest,payload) on conflict(empreinte) do nothing;
 select * into collecte from public.collectes_catalogue where empreinte=digest for update;
 if not approuver or collecte.statut='imported' then
  return jsonb_build_object('empreinte',digest,'statut',collecte.statut,'produit_id',collecte.produit_id);
 end if;

 select * into produit from public.produits p where lower(btrim(p.marque))=lower(btrim(fiche->>'brand'))
  and lower(btrim(p.ref_fabricant))=lower(btrim(fiche->>'reference')) for update;
 if found then
  if produit.code_ean is not null and lpad(produit.code_ean,14,'0')<>lpad(fiche->>'ean',14,'0') then raise exception 'Conflit EAN pour la référence fabricant'; end if;
  update public.produits set code_ean=coalesce(code_ean,fiche->>'ean'),catalogue_verifie=true,
   source_catalogue=coalesce(source_catalogue,fiche->'offers'->0->>'url'),
   catalogue_verifie_le=coalesce(catalogue_verifie_le,now()) where id=produit.id;
 else
  insert into public.produits(marque,ref_fabricant,code_ean,nom,catalogue_verifie,source_catalogue,catalogue_verifie_le)
   values(btrim(fiche->>'brand'),btrim(fiche->>'reference'),fiche->>'ean',btrim(fiche->>'name'),true,fiche->'offers'->0->>'url',now()) returning * into produit;
 end if;
 for offre in select value from jsonb_array_elements(fiche->'offers') loop
  select id into fid from public.fournisseurs where lower(btrim(nom))=lower(offre->>'supplier');
  if not found then
   insert into public.fournisseurs(nom,site_web) values(offre->>'supplier',case offre->>'supplier' when 'Rexel' then 'https://www.rexel.fr' else 'https://www.sonepar.fr' end) returning id into fid;
  end if;
  select * into existante from public.produits_fournisseurs where produit_id=produit.id and fournisseur_id=fid for update;
  if found then
   if (existante.ref_fournisseur is not null and lower(btrim(existante.ref_fournisseur))<>lower(btrim(offre->>'reference')))
     or (existante.url_produit is not null and existante.url_produit<>offre->>'url') then
    raise exception 'Référence ou URL déjà associée différente : résolution manuelle nécessaire';
   end if;
   update public.produits_fournisseurs set ref_fournisseur=coalesce(ref_fournisseur,btrim(offre->>'reference')),
    url_produit=coalesce(url_produit,offre->>'url'),conditionnement=coalesce(conditionnement,offre->>'pack'),
    reference_verifiee=true,reference_verifiee_le=coalesce(reference_verifiee_le,now()) where id=existante.id;
  else
   insert into public.produits_fournisseurs(produit_id,fournisseur_id,ref_fournisseur,prix,nature_prix,conditionnement,url_produit,reference_verifiee,reference_verifiee_le)
    values(produit.id,fid,btrim(offre->>'reference'),null,'public',offre->>'pack',offre->>'url',true,now());
  end if;
  if offre->>'image_url' is not null then
   update public.produits set image_url=coalesce(image_url,offre->>'image_url'),
    image_source_url=coalesce(image_source_url,offre->>'url'),image_verifiee_le=coalesce(image_verifiee_le,now())
    where id=produit.id and (image_url is null or (image_url=offre->>'image_url' and image_source_url is null));
  end if;
 end loop;
 update public.collectes_catalogue set statut='imported',produit_id=produit.id,valide_le=now() where empreinte=digest;
 return jsonb_build_object('empreinte',digest,'statut','imported','produit_id',produit.id);
end;
$$;

commit;
$migration_20261013131653$]);

-- 20261015130122_catalogue_facets.sql
-- Stable category codes, with a tree that cannot contain indirect cycles.
alter table public.categories add column code text unique,
 add column ordre integer not null default 0,
 add column actif boolean not null default true;
update public.categories set code='historique-'||id where code is null;
alter table public.categories alter column code set not null;
alter table public.categories add constraint categories_code_format check(code ~ '^[a-z][a-z0-9-]{0,79}$');
create function public.verrouiller_categories() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 -- Serialize taxonomy mutations, including multi-row UPDATEs. Concurrent movers
 -- may get a deadlock/serialization error and must retry the whole transaction.
 lock table public.categories in share row exclusive mode;
 return null;
end $$;
create trigger categories_verrou before insert or update or delete on public.categories
 for each statement execute function public.verrouiller_categories();
create function public.verifier_arbre_categories() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(with recursive chemin as (
   select id,parent_id,array[id] vus,false cycle from public.categories where id=new.id
   union all select c.id,c.parent_id,ch.vus||c.id,c.id=any(ch.vus)
   from chemin ch join public.categories c on c.id=ch.parent_id where not ch.cycle
 ) select 1 from chemin where cycle) then raise exception 'Cycle de catégories interdit'; end if;
 return null;
end $$;
create constraint trigger categories_sans_cycle after insert or update on public.categories
 deferrable initially immediate for each row execute function public.verifier_arbre_categories();

create table public.marques(id bigint generated by default as identity primary key, nom text not null check(length(btrim(nom)) between 1 and 200));
create unique index marques_nom on public.marques(lower(btrim(nom)));
create table public.gammes(id bigint generated by default as identity primary key,
 marque_id bigint not null references public.marques(id), nom text not null check(length(btrim(nom)) between 1 and 200), unique(id,marque_id));
create unique index gammes_marque_nom on public.gammes(marque_id,lower(btrim(nom)));
alter table public.produits add column marque_id bigint references public.marques(id),
 add column gamme_id bigint, add column gamme_nom text,
 add constraint produit_gamme_marque foreign key(gamme_id,marque_id) references public.gammes(id,marque_id),
 add constraint produit_gamme_complete check(gamme_id is null or marque_id is not null),
 add column sources_catalogue jsonb not null default '[]',
 add column references_fournisseurs text[] not null default '{}';
create index produits_marque on public.produits(marque_id);
create index produits_gamme_marque on public.produits(gamme_id,marque_id);
create index produits_refs_fournisseurs on public.produits using gin(references_fournisseurs);
create index produits_reference_recherche on public.produits(lower(btrim(ref_fabricant)));

create table public.attributs(
 code text primary key check(code ~ '^[a-z][a-z0-9_]{0,59}$'),
 nom text not null, type text not null check(type in ('text','number','boolean')),
 unite text not null default '', ordre integer not null default 0,
 unique(code,type), check(type='number' or unite='')
);
create table public.categorie_attributs(
 categorie_id bigint not null references public.categories(id) on delete cascade,
 attribut_code text not null references public.attributs(code),
 filtrable boolean not null default true, ordre integer not null default 0,
 primary key(categorie_id,attribut_code)
);
create index categorie_attribut_code on public.categorie_attributs(attribut_code);
create table public.produit_attributs(
 produit_id bigint not null references public.produits(id) on delete cascade,
 attribut_code text not null, type text not null,
 valeur_texte text, valeur_nombre numeric, valeur_booleen boolean,
 source_url text not null check(source_url ~ '^https://www[.](rexel|sonepar)[.]fr/'),
 observe_le timestamptz not null, libelle_source text not null, valeur_source text not null,
 primary key(produit_id,attribut_code),
 foreign key(attribut_code,type) references public.attributs(code,type),
 check((type='text' and valeur_texte is not null and length(btrim(valeur_texte)) between 1 and 1000 and valeur_nombre is null and valeur_booleen is null)
    or (type='number' and valeur_texte is null and valeur_nombre is not null and valeur_nombre between 0 and 1000000000 and valeur_booleen is null)
    or (type='boolean' and valeur_texte is null and valeur_nombre is null and valeur_booleen is not null))
);
create index produit_attribut_texte on public.produit_attributs(attribut_code,valeur_texte,produit_id) where type='text';
create index produit_attribut_nombre on public.produit_attributs(attribut_code,valeur_nombre,produit_id) where type='number';
create index produit_attribut_booleen on public.produit_attributs(attribut_code,valeur_booleen,produit_id) where type='boolean';
create table public.categories_fournisseurs(
 fournisseur_id bigint not null references public.fournisseurs(id), code text not null,
 nom text not null, url text not null, categorie_id bigint references public.categories(id),
 correspondance_verifiee boolean not null default false,
 primary key(fournisseur_id,code), check(not correspondance_verifiee or categorie_id is not null)
);
create index categories_fournisseurs_categorie on public.categories_fournisseurs(categorie_id);

-- Explicit selling rules; NULL means unknown. They are not inferred from a pack label.
alter table public.produits_fournisseurs add column unite_vente text check(unite_vente in ('piece','m','kg')),
 add column minimum_vente numeric check(minimum_vente>0),
 add column multiple_vente numeric check(multiple_vente>0),
 add column regles_vente_verifiees_le timestamptz,
 add constraint regles_vente_completes check(regles_vente_verifiees_le is null or
   (unite_vente is not null and minimum_vente is not null and multiple_vente is not null));

-- A deterministic French accent fold makes expression indexes reproducible.
create function public.texte_catalogue(t text) returns text language sql immutable parallel safe security invoker set search_path='' as $$
 select translate(lower(coalesce(t,'')),'àâäáãåçéèêëíìîïñóòôöõúùûüýÿ','aaaaaaceeeeiiiinooooouuuuyy');
$$;
alter table public.produits add column recherche tsvector generated always as (
 setweight(to_tsvector('pg_catalog.french',public.texte_catalogue(nom)),'A') ||
 setweight(to_tsvector('pg_catalog.french',public.texte_catalogue(marque||' '||coalesce(gamme_nom,''))),'B') ||
 setweight(to_tsvector('pg_catalog.simple',public.texte_catalogue(ref_fabricant)),'A')
) stored;
create index produits_recherche_gin on public.produits using gin(recherche) where catalogue_verifie;

create function public.synchroniser_marque_produit() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if btrim(new.marque)<>'' then
  insert into public.marques(nom) values(btrim(new.marque)) on conflict do nothing;
  select id,nom into new.marque_id,new.marque from public.marques where lower(btrim(nom))=lower(btrim(new.marque));
 end if;
 if new.gamme_id is not null then
  select nom into new.gamme_nom from public.gammes where id=new.gamme_id and marque_id=new.marque_id;
  if not found then raise exception 'Gamme incompatible avec la marque'; end if;
 else new.gamme_nom:=null; end if;
 return new;
end $$;
create trigger produit_marque before insert or update of marque,marque_id,gamme_id on public.produits
 for each row execute function public.synchroniser_marque_produit();
update public.produits set marque=marque;
create function public.actualiser_identites_catalogue() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_table_name='marques' then update public.produits set marque=new.nom where marque_id=new.id;
 else update public.produits set gamme_id=new.id where gamme_id=new.id; end if;
 return null;
end $$;
create trigger marque_renommee after update of nom on public.marques for each row execute function public.actualiser_identites_catalogue();
create trigger gamme_renommee after update of nom,marque_id on public.gammes for each row execute function public.actualiser_identites_catalogue();

-- Public references contain no prices, customer information or credentials.
create function public.actualiser_sources_produit() returns trigger language plpgsql security invoker set search_path='' as $$
declare pid bigint;
begin
 for pid in select distinct x from unnest(case when tg_op='INSERT' then array[new.produit_id]
   when tg_op='DELETE' then array[old.produit_id] else array[old.produit_id,new.produit_id] end) x loop
  update public.produits p set sources_catalogue=coalesce((select jsonb_agg(jsonb_build_object(
   'fournisseur',f.nom,'reference',o.ref_fournisseur,'url',o.url_produit) order by f.nom)
   from public.produits_fournisseurs o join public.fournisseurs f on f.id=o.fournisseur_id
   where o.produit_id=pid and o.reference_verifiee),'[]'),
   references_fournisseurs=coalesce((select array_agg(lower(btrim(o.ref_fournisseur))) from public.produits_fournisseurs o
    where o.produit_id=pid and o.reference_verifiee),'{}') where p.id=pid;
 end loop;
 return null;
end $$;
create trigger sources_produit after insert or update or delete on public.produits_fournisseurs
 for each row execute function public.actualiser_sources_produit();
update public.produits_fournisseurs set reference_verifiee=reference_verifiee;

-- Same publication boundary for direct table reads and every catalogue RPC.
drop policy produits_lecture on public.produits;
create policy produits_lecture on public.produits for select using(catalogue_verifie or (select auth.jwt())->'app_metadata'->>'role'='admin');
drop policy offres_lecture on public.produits_fournisseurs;
create policy offres_lecture on public.produits_fournisseurs for select to authenticated using(
 (select auth.uid()) is not null and not coalesce(((select auth.jwt())->>'is_anonymous')::boolean,false) and
 ((reference_verifiee and exists(select 1 from public.produits p where p.id=produit_id and p.catalogue_verifie))
  or (select auth.jwt())->'app_metadata'->>'role'='admin'));
create function public.verifier_offre_panier() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.produits_fournisseurs o join public.produits p on p.id=o.produit_id
  where o.id=new.offre_id and o.reference_verifiee and p.catalogue_verifie) then raise exception 'Offre indisponible ou non publiée'; end if;
 return new;
end $$;
create trigger panier_offre_publiee before insert or update on public.articles_panier
 for each row execute function public.verifier_offre_panier();

-- Typed attribute values are only valid for the product's category.
create function public.verifier_attribut_produit() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.produits p join public.categorie_attributs ca on ca.categorie_id=p.categorie_id
   where p.id=new.produit_id and ca.attribut_code=new.attribut_code) then raise exception 'Attribut non applicable à cette catégorie'; end if;
 return new;
end $$;
create trigger attribut_applicable before insert or update on public.produit_attributs
 for each row execute function public.verifier_attribut_produit();
create function public.verifier_reclassement_produit() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.produit_attributs pa where pa.produit_id=new.id and not exists(
  select 1 from public.categorie_attributs ca where ca.categorie_id=new.categorie_id and ca.attribut_code=pa.attribut_code))
 then raise exception 'Retirer ou réviser les attributs avant de reclasser le produit'; end if;
 return new;
end $$;
create trigger reclassement_produit before update of categorie_id on public.produits
 for each row execute function public.verifier_reclassement_produit();

create function public.verifier_applicabilite_catalogue() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.produit_attributs pa join public.produits p on p.id=pa.produit_id
   where not exists(select 1 from public.categorie_attributs ca where ca.categorie_id=p.categorie_id and ca.attribut_code=pa.attribut_code))
 then raise exception 'Des produits utilisent encore cet attribut dans cette catégorie'; end if;
 return null;
end $$;
create trigger applicabilite_catalogue after delete or update on public.categorie_attributs
 for each statement execute function public.verifier_applicabilite_catalogue();
revoke all on function public.verifier_applicabilite_catalogue() from public;
create index produit_attribut_definition on public.produit_attributs(attribut_code,type);

-- Public reference tables, administrative writes only.
do $$ declare t text; begin
 foreach t in array array['marques','gammes','attributs','categorie_attributs','categories_fournisseurs','produit_attributs'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('grant select on public.%I to anon,authenticated',t);
  execute format('grant insert,update,delete on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
  if t='produit_attributs' then
   execute format('create policy lecture on public.%I for select using(exists(select 1 from public.produits p where p.id=produit_id))',t);
  else execute format('create policy lecture on public.%I for select using(true)',t); end if;
  execute format('create policy creation_admin on public.%I for insert to authenticated with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy modification_admin on public.%I for update to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'') with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy suppression_admin on public.%I for delete to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
 end loop;
end $$;
grant usage,select on sequence public.marques_id_seq,public.gammes_id_seq to authenticated,service_role;

-- Initial family vocabulary, editable by administrators; no synthetic products.
insert into public.categories(code,nom,ordre) values
 ('appareillage','Appareillage',10),('protection','Protection et distribution',20),
 ('cables','Fils et câbles',30),('raccordement','Raccordement',40),('eclairage','Éclairage',50),('outillage','Outillage',60);
insert into public.categories(code,nom,parent_id,ordre)
 select v.code,v.nom,p.id,v.ordre from (values
 ('prises','Prises','appareillage',10),('interrupteurs','Interrupteurs','appareillage',20),
 ('appareillage-composable','Appareillage composable','appareillage',30),('plaques','Plaques et enjoliveurs','appareillage',40),('boites','Boîtes d’encastrement','appareillage',50),
 ('disjoncteurs','Disjoncteurs','protection',10),('differentiels','Interrupteurs différentiels','protection',20),('disjoncteurs-differentiels','Disjoncteurs différentiels','protection',30),('coffrets','Coffrets et tableaux','protection',40),
 ('fils','Fils électriques','cables',10),('cables-installation','Câbles d’installation','cables',20),
 ('bornes','Bornes et connecteurs','raccordement',10),('luminaires','Luminaires','eclairage',10),('lampes','Lampes et sources','eclairage',20),('outils','Outils et accessoires','outillage',10)
 ) v(code,nom,parent,ordre) join public.categories p on p.code=v.parent;
insert into public.attributs(code,nom,type,unite,ordre) values
 ('couleur','Couleur','text','',10),('materiau','Matériau','text','',20),('pose','Mode de pose','text','',30),
 ('fixation','Fixation','text','',40),('connexion','Connexion','text','',50),('ip','Indice IP','text','',60),
 ('sans_halogene','Sans halogène','boolean','',70),('courant','Courant nominal','number','A',80),
 ('tension','Tension nominale','number','V',90),('modules','Nombre de modules','number','',100),
 ('poles','Nombre de pôles','number','',110),('poles_proteges','Pôles protégés','number','',120),('courbe','Courbe de déclenchement','text','',130),
 ('section','Section du conducteur','number','mm²',140),('conducteurs','Nombre de conducteurs','number','',150),
 ('longueur','Longueur','number','m',160),('puissance','Puissance nominale','number','W',170),
 ('type_tension','Type de tension','text','',135),('icn_230','Pouvoir de coupure Icn (230 V, EN 60898)','number','kA',136),('icu_230','Pouvoir de coupure Icu (230 V, IEC 60947-2)','number','kA',137),
 ('flux','Flux lumineux','number','lm',180),('temperature','Température de couleur','number','K',190);
insert into public.categorie_attributs(categorie_id,attribut_code,ordre)
 select c.id,a.code,a.ordre from public.categories c cross join public.attributs a
 where not exists(select 1 from public.categories child where child.parent_id=c.id)
 and (a.code in ('couleur','materiau','pose','fixation','connexion','ip','sans_halogene','courant','tension','modules')
 or (c.code in ('disjoncteurs','differentiels','disjoncteurs-differentiels') and a.code in ('poles','poles_proteges','courbe','type_tension','icn_230','icu_230'))
 or (c.code in ('fils','cables-installation','bornes') and a.code in ('section','conducteurs','longueur'))
 or (c.code in ('luminaires','lampes') and a.code in ('puissance','flux','temperature')));

-- Full v2 documents remain private until reviewed. Base identity validation is
-- reused; no credentials, prices, arbitrary HTML or arbitrary JSON fields enter.
create function public.importer_catalogue_v2(fiche jsonb, approuver boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
<<v2>>
declare
 base jsonb; resultat jsonb; o jsonb; a jsonb; r jsonb; c jsonb; spec public.attributs%rowtype;
 pid bigint; cid bigint; mid bigint; gid bigint; fid bigint; empreinte text; source jsonb;
 codes text[]:='{}';
begin
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Import réservé à un administrateur' using errcode='42501'; end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or approuver is null
  or fiche->'schema_version' is distinct from '2'::jsonb then raise exception 'Fiche v2 invalide'; end if;
 if exists(select 1 from jsonb_object_keys(fiche) k where k not in
 ('brand','reference','ean','name','categories','review_status','offers','schema_version','category_code','range','attributes','attribute_conflicts'))
 then raise exception 'Champs produit inconnus'; end if;
 if fiche->>'category_code' is not null and (jsonb_typeof(fiche->'category_code')<>'string' or fiche->>'category_code' !~ '^[a-z][a-z0-9-]{0,79}$')
 then raise exception 'Code catégorie invalide'; end if;
 if fiche->>'range' is not null and (jsonb_typeof(fiche->'range')<>'string' or length(btrim(fiche->>'range')) not between 1 and 200)
 then raise exception 'Gamme invalide'; end if;
 if jsonb_typeof(fiche->'offers') is distinct from 'array' then raise exception 'Offres attendues'; end if;
 base:=fiche-array['schema_version','category_code','range','attributes','attribute_conflicts'];
 base:=jsonb_set(base,'{offers}','[]');
 for o in select value from jsonb_array_elements(fiche->'offers') loop
  if jsonb_typeof(o)<>'object' or exists(select 1 from jsonb_object_keys(o) k where k not in
   ('supplier','reference','url','pack','collected_at','page_sha256','image_url','raw_attributes','category_path','description','range'))
  then raise exception 'Champs offre inconnus'; end if;
  if jsonb_typeof(o->'raw_attributes') is distinct from 'array' or jsonb_typeof(o->'category_path') is distinct from 'array'
  then raise exception 'Attributs et catégories sources attendus'; end if;
  if jsonb_array_length(o->'raw_attributes')>150 or jsonb_array_length(o->'category_path')>10 then raise exception 'Trop de données sources'; end if;
  if o->>'description' is not null and (jsonb_typeof(o->'description')<>'string' or length(o->>'description')>4000) then raise exception 'Description invalide'; end if;
  if o->>'range' is not null and (jsonb_typeof(o->'range')<>'string' or length(btrim(o->>'range')) not between 1 and 200) then raise exception 'Gamme source invalide'; end if;
  for r in select value from jsonb_array_elements(o->'raw_attributes') loop
   if jsonb_typeof(r)<>'object' or not (r ?& array['label','value']) or exists(select 1 from jsonb_object_keys(r) k where k not in ('label','value'))
    or jsonb_typeof(r->'label') is distinct from 'string' or jsonb_typeof(r->'value') is distinct from 'string'
    or length(btrim(r->>'label')) not between 1 and 200 or length(btrim(r->>'value')) not between 1 and 1000
   then raise exception 'Attribut source invalide'; end if;
  end loop;
  for c in select value from jsonb_array_elements(o->'category_path') loop
   if jsonb_typeof(c)<>'object' or not(c ?& array['code','label','url']) or exists(select 1 from jsonb_object_keys(c) k where k not in ('code','label','url'))
    or jsonb_typeof(c->'code') is distinct from 'string' or jsonb_typeof(c->'label') is distinct from 'string' or jsonb_typeof(c->'url') is distinct from 'string'
    or c->>'code' !~ '^[A-Za-z0-9_-]{1,80}$' or length(btrim(c->>'label')) not between 1 and 200 or length(c->>'url')>2000
   then raise exception 'Catégorie source invalide'; end if;
   if (o->>'supplier'='Rexel' and (c->>'url' !~ '^https://www[.]rexel[.]fr/frx/([^?#[:space:]]+/)?c/[A-Za-z0-9_-]+$'
      or split_part(c->>'url','/c/',2)<>c->>'code'))
    or (o->>'supplier'='Sonepar' and (c->>'url' !~ '^https://www[.]sonepar[.]fr/catalog/fr-fr/category/[^/?#[:space:]]+$'
      or right(c->>'url',length(c->>'code')+1)<>'-'||(c->>'code'))) then raise exception 'URL/catégorie source incohérente'; end if;
  end loop;
  base:=jsonb_set(base,'{offers}',(base->'offers')||jsonb_build_array(o-array['raw_attributes','category_path','description','range']));
 end loop;
 if fiche->>'range' is not null and not exists(select 1 from jsonb_array_elements(fiche->'offers') x where x->>'range'=fiche->>'range')
 then raise exception 'Gamme sans source'; end if;
 if jsonb_typeof(fiche->'attributes') is distinct from 'array' or jsonb_typeof(fiche->'attribute_conflicts') is distinct from 'array'
 then raise exception 'Attributs et conflits attendus'; end if;
 if jsonb_array_length(fiche->'attributes')>100 or jsonb_array_length(fiche->'attribute_conflicts')>100 then raise exception 'Trop d’attributs'; end if;
 for r in select value from jsonb_array_elements(fiche->'attribute_conflicts') loop
  if jsonb_typeof(r)<>'string' or r#>>'{}' !~ '^[a-z][a-z0-9_]{0,59}$' then raise exception 'Conflit invalide'; end if;
 end loop;
 select id into cid from public.categories where code=fiche->>'category_code' and actif;
 if approuver and (cid is null or exists(select 1 from public.categories where parent_id=cid)
   or jsonb_array_length(fiche->'attribute_conflicts')>0) then raise exception 'Catégorie finale vérifiée et conflits résolus requis'; end if;
 for a in select value from jsonb_array_elements(fiche->'attributes') loop
  if jsonb_typeof(a)<>'object' or not(a ?& array['code','type','value','unit','supplier','raw_label','raw_value'])
   or exists(select 1 from jsonb_object_keys(a) k where k not in ('code','type','value','unit','supplier','raw_label','raw_value'))
  then raise exception 'Attribut normalisé invalide'; end if;
  select * into spec from public.attributs where code=a->>'code';
  if not found or (a->>'code')=any(codes) or a->>'type' is distinct from spec.type or a->>'unit' is distinct from spec.unite
  then raise exception 'Code, type ou unité d’attribut incohérent'; end if;
  codes:=array_append(codes,a->>'code');
  if jsonb_typeof(a->'value') is distinct from (case spec.type when 'text' then 'string' else spec.type end)
  then raise exception 'Type de valeur incorrect'; end if;
  if spec.type='number' and ((a->>'value')::numeric<0 or (a->>'value')::numeric>1000000000) then raise exception 'Nombre hors limites'; end if;
  if spec.type='text' and length(btrim(a->>'value')) not between 1 and 1000 then raise exception 'Texte vide'; end if;
  select x into source from jsonb_array_elements(fiche->'offers') x where x->>'supplier'=a->>'supplier';
  if source is null or not (source->'raw_attributes' @> jsonb_build_array(jsonb_build_object('label',a->'raw_label','value',a->'raw_value')))
  then raise exception 'Attribut sans provenance'; end if;
  if approuver and not exists(select 1 from public.categorie_attributs where categorie_id=cid and attribut_code=spec.code)
  then raise exception 'Attribut % non applicable à cette catégorie',spec.code; end if;
 end loop;
 -- Base importer validates official URLs, hashes, dates, GTIN and review_status;
 -- exceptions roll back the whole call including both staging documents.
 resultat:=public.importer_produit_collecte(base,approuver);
 empreinte:=encode(sha256(convert_to((fiche-'review_status')::text,'UTF8')),'hex');
 insert into public.collectes_catalogue(empreinte,donnees) values(empreinte,fiche-'review_status') on conflict do nothing;
 if not approuver then return (select jsonb_build_object('empreinte',cc.empreinte,'statut',cc.statut,'produit_id',cc.produit_id) from public.collectes_catalogue cc where cc.empreinte=v2.empreinte); end if;
 pid:=(resultat->>'produit_id')::bigint;
 select marque_id into mid from public.produits where id=pid;
 if fiche->>'range' is not null then
  insert into public.gammes(marque_id,nom) values(mid,btrim(fiche->>'range')) on conflict do nothing;
  select id into gid from public.gammes where marque_id=mid and lower(btrim(nom))=lower(btrim(fiche->>'range'));
 end if;
 delete from public.produit_attributs where produit_id=pid;
 update public.produits set categorie_id=cid,gamme_id=gid,
  description=coalesce((select nullif(x->>'description','') from jsonb_array_elements(fiche->'offers') x where nullif(x->>'description','') is not null limit 1),description) where id=pid;
 for a in select value from jsonb_array_elements(fiche->'attributes') loop
  select x into source from jsonb_array_elements(fiche->'offers') x where x->>'supplier'=a->>'supplier';
  insert into public.produit_attributs(produit_id,attribut_code,type,valeur_texte,valeur_nombre,valeur_booleen,source_url,observe_le,libelle_source,valeur_source)
  values(pid,a->>'code',a->>'type',case when a->>'type'='text' then a->>'value' end,
   case when a->>'type'='number' then (a->>'value')::numeric end,case when a->>'type'='boolean' then (a->>'value')::boolean end,
   source->>'url',(source->>'collected_at')::timestamptz,a->>'raw_label',a->>'raw_value');
 end loop;
 for o in select value from jsonb_array_elements(fiche->'offers') loop
  select id into fid from public.fournisseurs where lower(nom)=lower(o->>'supplier');
  for c in select value from jsonb_array_elements(o->'category_path') loop
   insert into public.categories_fournisseurs(fournisseur_id,code,nom,url) values(fid,c->>'code',c->>'label',c->>'url')
   on conflict(fournisseur_id,code) do update set nom=excluded.nom,url=excluded.url;
  end loop;
 end loop;
 update public.collectes_catalogue cc set statut='imported',produit_id=pid,valide_le=now() where cc.empreinte=v2.empreinte;
 return jsonb_build_object('empreinte',empreinte,'statut','imported','produit_id',pid);
end $$;
revoke all on function public.importer_catalogue_v2(jsonb,boolean) from public;
grant execute on function public.importer_catalogue_v2(jsonb,boolean) to authenticated,service_role;

-- OR within a facet, AND across facets. Numeric ranges use canonical units.
create function public.filtres_correspondent(dimensions jsonb, filtres jsonb, sauf text default null)
returns boolean language plpgsql immutable parallel safe security invoker set search_path='' as $$
declare f record; v text; n numeric;
begin
 for f in select * from jsonb_each(filtres) loop
  if f.key=sauf then continue; end if;
  if jsonb_typeof(f.value)='array' then
   if jsonb_array_length(f.value)>0 and not exists(
    select 1 from jsonb_array_elements_text(f.value) selected
    where coalesce(dimensions->f.key,'[]') @> jsonb_build_array(selected)) then return false; end if;
  else
   v:=dimensions->f.key->>0;
   if v is null then return false; end if;
   n:=v::numeric;
   if (f.value ? 'min' and n<(f.value->>'min')::numeric) or (f.value ? 'max' and n>(f.value->>'max')::numeric) then return false; end if;
  end if;
 end loop;
 return true;
end $$;
revoke all on function public.filtres_correspondent(jsonb,jsonb,text) from public;
grant execute on function public.filtres_correspondent(jsonb,jsonb,text) to anon,authenticated,service_role;

create function public.rechercher_catalogue_v2(terme text default '', filtres jsonb default '{}', page_num integer default 0)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare q text:=lower(btrim(left(coalesce(terme,''),100))); filtre record; v jsonb;
 tq tsquery:=plainto_tsquery('pg_catalog.french',public.texte_catalogue(left(coalesce(terme,''),100)));
 page integer:=greatest(0,least(coalesce(page_num,0),100000)); resultat jsonb;
begin
 if filtres is null or jsonb_typeof(filtres)<>'object' or octet_length(filtres::text)>12000 then raise exception 'Filtres invalides'; end if;
 if (select count(*) from jsonb_object_keys(filtres))>24 then raise exception 'Trop de filtres'; end if;
 for filtre in select * from jsonb_each(filtres) loop
  if filtre.key not in ('categorie','marque','gamme','fournisseur') and not exists(select 1 from public.attributs where 'a:'||code=filtre.key)
  then raise exception 'Filtre inconnu'; end if;
  if jsonb_typeof(filtre.value)='array' then
   if jsonb_array_length(filtre.value)>30 then raise exception 'Trop de valeurs'; end if;
   for v in select value from jsonb_array_elements(filtre.value) loop
    if jsonb_typeof(v)<>'string' or length(v#>>'{}')>1000 then raise exception 'Valeur de filtre invalide'; end if;
   end loop;
  elsif jsonb_typeof(filtre.value)='object' and exists(select 1 from public.attributs where 'a:'||code=filtre.key and type='number') then
   if filtre.value='{}' or exists(select 1 from jsonb_each(filtre.value) x where x.key not in ('min','max') or jsonb_typeof(x.value)<>'number')
    or (filtre.value->>'min')::numeric>(filtre.value->>'max')::numeric then raise exception 'Intervalle invalide'; end if;
  else raise exception 'Liste de valeurs ou intervalle numérique requis'; end if;
 end loop;
 with recursive chemins as (
  select id feuille,id,parent_id,code,nom from public.categories
  union all select ch.feuille,c.id,c.parent_id,c.code,c.nom from chemins ch join public.categories c on c.id=ch.parent_id
 ), base as materialized (
  select p.*,case when lower(btrim(p.ref_fabricant))=q or (q ~ '^([0-9]{8}|[0-9]{12,14})$' and p.code_ean is not null and lpad(p.code_ean,14,'0')=lpad(q,14,'0'))
    or p.references_fournisseurs @> array[q] then 2 else 0 end + ts_rank(p.recherche,tq) score
  from public.produits p where p.catalogue_verifie
   and not exists(select 1 from chemins ch join public.categories cat on cat.id=ch.id where ch.feuille=p.categorie_id and not cat.actif)
   and (q='' or p.recherche @@ tq
   or lower(btrim(p.ref_fabricant))=q or (q ~ '^([0-9]{8}|[0-9]{12,14})$' and p.code_ean is not null and lpad(p.code_ean,14,'0')=lpad(q,14,'0'))
   or p.references_fournisseurs @> array[q])
 ), dims as materialized (
  select b.id,b.nom,b.score,jsonb_build_object(
   'marque',case when b.marque_id is null then '[]'::jsonb else jsonb_build_array(b.marque_id::text) end,
   'gamme',case when b.gamme_id is null then '[]'::jsonb else jsonb_build_array(b.gamme_id::text) end,
   'categorie',coalesce((select jsonb_agg(ch.code) from chemins ch where ch.feuille=b.categorie_id),'[]'),
   'fournisseur',coalesce((select jsonb_agg(x->>'fournisseur') from jsonb_array_elements(b.sources_catalogue) x),'[]'))
   || coalesce((select jsonb_object_agg('a:'||pa.attribut_code,jsonb_build_array(coalesce(pa.valeur_texte,pa.valeur_nombre::text,pa.valeur_booleen::text)))
     from public.produit_attributs pa join public.categorie_attributs ca on ca.categorie_id=b.categorie_id and ca.attribut_code=pa.attribut_code
     where pa.produit_id=b.id and ca.filtrable),'{}') dimensions
  from base b
 ), matches as materialized (
  select * from dims d where public.filtres_correspondent(d.dimensions,filtres)
 ), pagines as (
  select b.* from base b join matches m on m.id=b.id order by b.score desc,b.nom,b.id limit 24 offset page*24
 ), comptes as (
  select e.key,k.value,count(*) nombre from dims d cross join lateral jsonb_each(d.dimensions) e
   cross join lateral jsonb_array_elements_text(e.value) k
   where public.filtres_correspondent(d.dimensions,filtres,e.key) group by e.key,k.value
 ), facettes as (
  select c.key,coalesce(a.nom,case c.key when 'categorie' then 'Catégorie' when 'marque' then 'Marque' when 'gamme' then 'Gamme' when 'fournisseur' then 'Fournisseur' end) label,
   coalesce(a.type,'text') type,coalesce(a.unite,'') unit,coalesce(a.ordre,0) ordre,
   jsonb_agg(jsonb_build_object('value',c.value,'count',c.nombre,'label',
    case c.key when 'marque' then (select nom from public.marques where id=c.value::bigint)
     when 'gamme' then (select g.nom||' · '||m.nom from public.gammes g join public.marques m on m.id=g.marque_id where g.id=c.value::bigint)
     when 'categorie' then (select nom from public.categories where code=c.value)
     else case when a.type='boolean' then case c.value when 'true' then 'Oui' else 'Non' end else c.value end end)
    order by case when a.type='number' then c.value::numeric end,c.value) valeurs
  from comptes c left join public.attributs a on 'a:'||a.code=c.key group by c.key,a.nom,a.type,a.unite,a.ordre
 )
 select jsonb_build_object('total',(select count(*) from matches),'page',page,'page_size',24,
 'items',coalesce((select jsonb_agg(jsonb_build_object(
   'id',p.id,'ref_fabricant',p.ref_fabricant,'code_ean',p.code_ean,'nom',p.nom,'marque',p.marque,'gamme',p.gamme_nom,
   'image_url',p.image_url,'description',p.description,'categorie',(select nom from public.categories where id=p.categorie_id),
   'sources',p.sources_catalogue,'attributs',coalesce((select jsonb_agg(jsonb_build_object('code',a.code,'nom',a.nom,'type',a.type,'unite',a.unite,
      'valeur',coalesce(to_jsonb(pa.valeur_texte),to_jsonb(pa.valeur_nombre),to_jsonb(pa.valeur_booleen)),'source_url',pa.source_url) order by a.ordre,a.code)
      from public.produit_attributs pa join public.attributs a on a.code=pa.attribut_code where pa.produit_id=p.id),'[]'),
   'offres',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'fournisseur',f.nom,'prix',o.prix,'nature_prix',o.nature_prix,
      'ref_fournisseur',o.ref_fournisseur,'reference_verifiee',o.reference_verifiee,'conditionnement',o.conditionnement,
      'date_verification',o.date_verification,'url_produit',o.url_produit) order by f.nom)
      from public.produits_fournisseurs o join public.fournisseurs f on f.id=o.fournisseur_id where o.produit_id=p.id and o.reference_verifiee),'[]'))
    order by p.score desc,p.nom,p.id) from pagines p),'[]'),
 'facets',coalesce((select jsonb_agg(jsonb_build_object('key',key,'label',label,'type',type,'unit',unit,'values',valeurs) order by ordre,key) from facettes),'[]'),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'code',code,'nom',nom,'parent_id',parent_id,'ordre',ordre) order by ordre,nom) from public.categories where actif),'[]')
 ) into resultat;
 return resultat;
end $$;
revoke all on function public.rechercher_catalogue_v2(text,jsonb,integer) from public;
grant execute on function public.rechercher_catalogue_v2(text,jsonb,integer) to anon,authenticated,service_role;
revoke all on function public.texte_catalogue(text) from public;
grant execute on function public.texte_catalogue(text) to anon,authenticated,service_role;
-- Trigger functions cannot be called as RPCs; no direct execution grants needed.
revoke all on function public.verrouiller_categories(),public.verifier_arbre_categories(),
 public.synchroniser_marque_produit(),public.actualiser_identites_catalogue(),public.actualiser_sources_produit(),
 public.verifier_offre_panier(),public.verifier_attribut_produit(),public.verifier_reclassement_produit() from public;

insert into supabase_migrations.schema_migrations(version,name,statements) values('20261015130122','catalogue_facets',array[$migration_20261015130122$begin;

-- Stable category codes, with a tree that cannot contain indirect cycles.
alter table public.categories add column code text unique,
 add column ordre integer not null default 0,
 add column actif boolean not null default true;
update public.categories set code='historique-'||id where code is null;
alter table public.categories alter column code set not null;
alter table public.categories add constraint categories_code_format check(code ~ '^[a-z][a-z0-9-]{0,79}$');
create function public.verrouiller_categories() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 -- Serialize taxonomy mutations, including multi-row UPDATEs. Concurrent movers
 -- may get a deadlock/serialization error and must retry the whole transaction.
 lock table public.categories in share row exclusive mode;
 return null;
end $$;
create trigger categories_verrou before insert or update or delete on public.categories
 for each statement execute function public.verrouiller_categories();
create function public.verifier_arbre_categories() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(with recursive chemin as (
   select id,parent_id,array[id] vus,false cycle from public.categories where id=new.id
   union all select c.id,c.parent_id,ch.vus||c.id,c.id=any(ch.vus)
   from chemin ch join public.categories c on c.id=ch.parent_id where not ch.cycle
 ) select 1 from chemin where cycle) then raise exception 'Cycle de catégories interdit'; end if;
 return null;
end $$;
create constraint trigger categories_sans_cycle after insert or update on public.categories
 deferrable initially immediate for each row execute function public.verifier_arbre_categories();

create table public.marques(id bigint generated by default as identity primary key, nom text not null check(length(btrim(nom)) between 1 and 200));
create unique index marques_nom on public.marques(lower(btrim(nom)));
create table public.gammes(id bigint generated by default as identity primary key,
 marque_id bigint not null references public.marques(id), nom text not null check(length(btrim(nom)) between 1 and 200), unique(id,marque_id));
create unique index gammes_marque_nom on public.gammes(marque_id,lower(btrim(nom)));
alter table public.produits add column marque_id bigint references public.marques(id),
 add column gamme_id bigint, add column gamme_nom text,
 add constraint produit_gamme_marque foreign key(gamme_id,marque_id) references public.gammes(id,marque_id),
 add constraint produit_gamme_complete check(gamme_id is null or marque_id is not null),
 add column sources_catalogue jsonb not null default '[]',
 add column references_fournisseurs text[] not null default '{}';
create index produits_marque on public.produits(marque_id);
create index produits_gamme_marque on public.produits(gamme_id,marque_id);
create index produits_refs_fournisseurs on public.produits using gin(references_fournisseurs);
create index produits_reference_recherche on public.produits(lower(btrim(ref_fabricant)));

create table public.attributs(
 code text primary key check(code ~ '^[a-z][a-z0-9_]{0,59}$'),
 nom text not null, type text not null check(type in ('text','number','boolean')),
 unite text not null default '', ordre integer not null default 0,
 unique(code,type), check(type='number' or unite='')
);
create table public.categorie_attributs(
 categorie_id bigint not null references public.categories(id) on delete cascade,
 attribut_code text not null references public.attributs(code),
 filtrable boolean not null default true, ordre integer not null default 0,
 primary key(categorie_id,attribut_code)
);
create index categorie_attribut_code on public.categorie_attributs(attribut_code);
create table public.produit_attributs(
 produit_id bigint not null references public.produits(id) on delete cascade,
 attribut_code text not null, type text not null,
 valeur_texte text, valeur_nombre numeric, valeur_booleen boolean,
 source_url text not null check(source_url ~ '^https://www[.](rexel|sonepar)[.]fr/'),
 observe_le timestamptz not null, libelle_source text not null, valeur_source text not null,
 primary key(produit_id,attribut_code),
 foreign key(attribut_code,type) references public.attributs(code,type),
 check((type='text' and valeur_texte is not null and length(btrim(valeur_texte)) between 1 and 1000 and valeur_nombre is null and valeur_booleen is null)
    or (type='number' and valeur_texte is null and valeur_nombre is not null and valeur_nombre between 0 and 1000000000 and valeur_booleen is null)
    or (type='boolean' and valeur_texte is null and valeur_nombre is null and valeur_booleen is not null))
);
create index produit_attribut_texte on public.produit_attributs(attribut_code,valeur_texte,produit_id) where type='text';
create index produit_attribut_nombre on public.produit_attributs(attribut_code,valeur_nombre,produit_id) where type='number';
create index produit_attribut_booleen on public.produit_attributs(attribut_code,valeur_booleen,produit_id) where type='boolean';
create table public.categories_fournisseurs(
 fournisseur_id bigint not null references public.fournisseurs(id), code text not null,
 nom text not null, url text not null, categorie_id bigint references public.categories(id),
 correspondance_verifiee boolean not null default false,
 primary key(fournisseur_id,code), check(not correspondance_verifiee or categorie_id is not null)
);
create index categories_fournisseurs_categorie on public.categories_fournisseurs(categorie_id);

-- Explicit selling rules; NULL means unknown. They are not inferred from a pack label.
alter table public.produits_fournisseurs add column unite_vente text check(unite_vente in ('piece','m','kg')),
 add column minimum_vente numeric check(minimum_vente>0),
 add column multiple_vente numeric check(multiple_vente>0),
 add column regles_vente_verifiees_le timestamptz,
 add constraint regles_vente_completes check(regles_vente_verifiees_le is null or
   (unite_vente is not null and minimum_vente is not null and multiple_vente is not null));

-- A deterministic French accent fold makes expression indexes reproducible.
create function public.texte_catalogue(t text) returns text language sql immutable parallel safe security invoker set search_path='' as $$
 select translate(lower(coalesce(t,'')),'àâäáãåçéèêëíìîïñóòôöõúùûüýÿ','aaaaaaceeeeiiiinooooouuuuyy');
$$;
alter table public.produits add column recherche tsvector generated always as (
 setweight(to_tsvector('pg_catalog.french',public.texte_catalogue(nom)),'A') ||
 setweight(to_tsvector('pg_catalog.french',public.texte_catalogue(marque||' '||coalesce(gamme_nom,''))),'B') ||
 setweight(to_tsvector('pg_catalog.simple',public.texte_catalogue(ref_fabricant)),'A')
) stored;
create index produits_recherche_gin on public.produits using gin(recherche) where catalogue_verifie;

create function public.synchroniser_marque_produit() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if btrim(new.marque)<>'' then
  insert into public.marques(nom) values(btrim(new.marque)) on conflict do nothing;
  select id,nom into new.marque_id,new.marque from public.marques where lower(btrim(nom))=lower(btrim(new.marque));
 end if;
 if new.gamme_id is not null then
  select nom into new.gamme_nom from public.gammes where id=new.gamme_id and marque_id=new.marque_id;
  if not found then raise exception 'Gamme incompatible avec la marque'; end if;
 else new.gamme_nom:=null; end if;
 return new;
end $$;
create trigger produit_marque before insert or update of marque,marque_id,gamme_id on public.produits
 for each row execute function public.synchroniser_marque_produit();
update public.produits set marque=marque;
create function public.actualiser_identites_catalogue() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_table_name='marques' then update public.produits set marque=new.nom where marque_id=new.id;
 else update public.produits set gamme_id=new.id where gamme_id=new.id; end if;
 return null;
end $$;
create trigger marque_renommee after update of nom on public.marques for each row execute function public.actualiser_identites_catalogue();
create trigger gamme_renommee after update of nom,marque_id on public.gammes for each row execute function public.actualiser_identites_catalogue();

-- Public references contain no prices, customer information or credentials.
create function public.actualiser_sources_produit() returns trigger language plpgsql security invoker set search_path='' as $$
declare pid bigint;
begin
 for pid in select distinct x from unnest(case when tg_op='INSERT' then array[new.produit_id]
   when tg_op='DELETE' then array[old.produit_id] else array[old.produit_id,new.produit_id] end) x loop
  update public.produits p set sources_catalogue=coalesce((select jsonb_agg(jsonb_build_object(
   'fournisseur',f.nom,'reference',o.ref_fournisseur,'url',o.url_produit) order by f.nom)
   from public.produits_fournisseurs o join public.fournisseurs f on f.id=o.fournisseur_id
   where o.produit_id=pid and o.reference_verifiee),'[]'),
   references_fournisseurs=coalesce((select array_agg(lower(btrim(o.ref_fournisseur))) from public.produits_fournisseurs o
    where o.produit_id=pid and o.reference_verifiee),'{}') where p.id=pid;
 end loop;
 return null;
end $$;
create trigger sources_produit after insert or update or delete on public.produits_fournisseurs
 for each row execute function public.actualiser_sources_produit();
update public.produits_fournisseurs set reference_verifiee=reference_verifiee;

-- Same publication boundary for direct table reads and every catalogue RPC.
drop policy produits_lecture on public.produits;
create policy produits_lecture on public.produits for select using(catalogue_verifie or (select auth.jwt())->'app_metadata'->>'role'='admin');
drop policy offres_lecture on public.produits_fournisseurs;
create policy offres_lecture on public.produits_fournisseurs for select to authenticated using(
 (select auth.uid()) is not null and not coalesce(((select auth.jwt())->>'is_anonymous')::boolean,false) and
 ((reference_verifiee and exists(select 1 from public.produits p where p.id=produit_id and p.catalogue_verifie))
  or (select auth.jwt())->'app_metadata'->>'role'='admin'));
create function public.verifier_offre_panier() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.produits_fournisseurs o join public.produits p on p.id=o.produit_id
  where o.id=new.offre_id and o.reference_verifiee and p.catalogue_verifie) then raise exception 'Offre indisponible ou non publiée'; end if;
 return new;
end $$;
create trigger panier_offre_publiee before insert or update on public.articles_panier
 for each row execute function public.verifier_offre_panier();

-- Typed attribute values are only valid for the product's category.
create function public.verifier_attribut_produit() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.produits p join public.categorie_attributs ca on ca.categorie_id=p.categorie_id
   where p.id=new.produit_id and ca.attribut_code=new.attribut_code) then raise exception 'Attribut non applicable à cette catégorie'; end if;
 return new;
end $$;
create trigger attribut_applicable before insert or update on public.produit_attributs
 for each row execute function public.verifier_attribut_produit();
create function public.verifier_reclassement_produit() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.produit_attributs pa where pa.produit_id=new.id and not exists(
  select 1 from public.categorie_attributs ca where ca.categorie_id=new.categorie_id and ca.attribut_code=pa.attribut_code))
 then raise exception 'Retirer ou réviser les attributs avant de reclasser le produit'; end if;
 return new;
end $$;
create trigger reclassement_produit before update of categorie_id on public.produits
 for each row execute function public.verifier_reclassement_produit();

create function public.verifier_applicabilite_catalogue() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.produit_attributs pa join public.produits p on p.id=pa.produit_id
   where not exists(select 1 from public.categorie_attributs ca where ca.categorie_id=p.categorie_id and ca.attribut_code=pa.attribut_code))
 then raise exception 'Des produits utilisent encore cet attribut dans cette catégorie'; end if;
 return null;
end $$;
create trigger applicabilite_catalogue after delete or update on public.categorie_attributs
 for each statement execute function public.verifier_applicabilite_catalogue();
revoke all on function public.verifier_applicabilite_catalogue() from public;
create index produit_attribut_definition on public.produit_attributs(attribut_code,type);

-- Public reference tables, administrative writes only.
do $$ declare t text; begin
 foreach t in array array['marques','gammes','attributs','categorie_attributs','categories_fournisseurs','produit_attributs'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('grant select on public.%I to anon,authenticated',t);
  execute format('grant insert,update,delete on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
  if t='produit_attributs' then
   execute format('create policy lecture on public.%I for select using(exists(select 1 from public.produits p where p.id=produit_id))',t);
  else execute format('create policy lecture on public.%I for select using(true)',t); end if;
  execute format('create policy creation_admin on public.%I for insert to authenticated with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy modification_admin on public.%I for update to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'') with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy suppression_admin on public.%I for delete to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
 end loop;
end $$;
grant usage,select on sequence public.marques_id_seq,public.gammes_id_seq to authenticated,service_role;

-- Initial family vocabulary, editable by administrators; no synthetic products.
insert into public.categories(code,nom,ordre) values
 ('appareillage','Appareillage',10),('protection','Protection et distribution',20),
 ('cables','Fils et câbles',30),('raccordement','Raccordement',40),('eclairage','Éclairage',50),('outillage','Outillage',60);
insert into public.categories(code,nom,parent_id,ordre)
 select v.code,v.nom,p.id,v.ordre from (values
 ('prises','Prises','appareillage',10),('interrupteurs','Interrupteurs','appareillage',20),
 ('appareillage-composable','Appareillage composable','appareillage',30),('plaques','Plaques et enjoliveurs','appareillage',40),('boites','Boîtes d’encastrement','appareillage',50),
 ('disjoncteurs','Disjoncteurs','protection',10),('differentiels','Interrupteurs différentiels','protection',20),('disjoncteurs-differentiels','Disjoncteurs différentiels','protection',30),('coffrets','Coffrets et tableaux','protection',40),
 ('fils','Fils électriques','cables',10),('cables-installation','Câbles d’installation','cables',20),
 ('bornes','Bornes et connecteurs','raccordement',10),('luminaires','Luminaires','eclairage',10),('lampes','Lampes et sources','eclairage',20),('outils','Outils et accessoires','outillage',10)
 ) v(code,nom,parent,ordre) join public.categories p on p.code=v.parent;
insert into public.attributs(code,nom,type,unite,ordre) values
 ('couleur','Couleur','text','',10),('materiau','Matériau','text','',20),('pose','Mode de pose','text','',30),
 ('fixation','Fixation','text','',40),('connexion','Connexion','text','',50),('ip','Indice IP','text','',60),
 ('sans_halogene','Sans halogène','boolean','',70),('courant','Courant nominal','number','A',80),
 ('tension','Tension nominale','number','V',90),('modules','Nombre de modules','number','',100),
 ('poles','Nombre de pôles','number','',110),('poles_proteges','Pôles protégés','number','',120),('courbe','Courbe de déclenchement','text','',130),
 ('section','Section du conducteur','number','mm²',140),('conducteurs','Nombre de conducteurs','number','',150),
 ('longueur','Longueur','number','m',160),('puissance','Puissance nominale','number','W',170),
 ('type_tension','Type de tension','text','',135),('icn_230','Pouvoir de coupure Icn (230 V, EN 60898)','number','kA',136),('icu_230','Pouvoir de coupure Icu (230 V, IEC 60947-2)','number','kA',137),
 ('flux','Flux lumineux','number','lm',180),('temperature','Température de couleur','number','K',190);
insert into public.categorie_attributs(categorie_id,attribut_code,ordre)
 select c.id,a.code,a.ordre from public.categories c cross join public.attributs a
 where not exists(select 1 from public.categories child where child.parent_id=c.id)
 and (a.code in ('couleur','materiau','pose','fixation','connexion','ip','sans_halogene','courant','tension','modules')
 or (c.code in ('disjoncteurs','differentiels','disjoncteurs-differentiels') and a.code in ('poles','poles_proteges','courbe','type_tension','icn_230','icu_230'))
 or (c.code in ('fils','cables-installation','bornes') and a.code in ('section','conducteurs','longueur'))
 or (c.code in ('luminaires','lampes') and a.code in ('puissance','flux','temperature')));

-- Full v2 documents remain private until reviewed. Base identity validation is
-- reused; no credentials, prices, arbitrary HTML or arbitrary JSON fields enter.
create function public.importer_catalogue_v2(fiche jsonb, approuver boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
<<v2>>
declare
 base jsonb; resultat jsonb; o jsonb; a jsonb; r jsonb; c jsonb; spec public.attributs%rowtype;
 pid bigint; cid bigint; mid bigint; gid bigint; fid bigint; empreinte text; source jsonb;
 codes text[]:='{}';
begin
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Import réservé à un administrateur' using errcode='42501'; end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or approuver is null
  or fiche->'schema_version' is distinct from '2'::jsonb then raise exception 'Fiche v2 invalide'; end if;
 if exists(select 1 from jsonb_object_keys(fiche) k where k not in
 ('brand','reference','ean','name','categories','review_status','offers','schema_version','category_code','range','attributes','attribute_conflicts'))
 then raise exception 'Champs produit inconnus'; end if;
 if fiche->>'category_code' is not null and (jsonb_typeof(fiche->'category_code')<>'string' or fiche->>'category_code' !~ '^[a-z][a-z0-9-]{0,79}$')
 then raise exception 'Code catégorie invalide'; end if;
 if fiche->>'range' is not null and (jsonb_typeof(fiche->'range')<>'string' or length(btrim(fiche->>'range')) not between 1 and 200)
 then raise exception 'Gamme invalide'; end if;
 if jsonb_typeof(fiche->'offers') is distinct from 'array' then raise exception 'Offres attendues'; end if;
 base:=fiche-array['schema_version','category_code','range','attributes','attribute_conflicts'];
 base:=jsonb_set(base,'{offers}','[]');
 for o in select value from jsonb_array_elements(fiche->'offers') loop
  if jsonb_typeof(o)<>'object' or exists(select 1 from jsonb_object_keys(o) k where k not in
   ('supplier','reference','url','pack','collected_at','page_sha256','image_url','raw_attributes','category_path','description','range'))
  then raise exception 'Champs offre inconnus'; end if;
  if jsonb_typeof(o->'raw_attributes') is distinct from 'array' or jsonb_typeof(o->'category_path') is distinct from 'array'
  then raise exception 'Attributs et catégories sources attendus'; end if;
  if jsonb_array_length(o->'raw_attributes')>150 or jsonb_array_length(o->'category_path')>10 then raise exception 'Trop de données sources'; end if;
  if o->>'description' is not null and (jsonb_typeof(o->'description')<>'string' or length(o->>'description')>4000) then raise exception 'Description invalide'; end if;
  if o->>'range' is not null and (jsonb_typeof(o->'range')<>'string' or length(btrim(o->>'range')) not between 1 and 200) then raise exception 'Gamme source invalide'; end if;
  for r in select value from jsonb_array_elements(o->'raw_attributes') loop
   if jsonb_typeof(r)<>'object' or not (r ?& array['label','value']) or exists(select 1 from jsonb_object_keys(r) k where k not in ('label','value'))
    or jsonb_typeof(r->'label') is distinct from 'string' or jsonb_typeof(r->'value') is distinct from 'string'
    or length(btrim(r->>'label')) not between 1 and 200 or length(btrim(r->>'value')) not between 1 and 1000
   then raise exception 'Attribut source invalide'; end if;
  end loop;
  for c in select value from jsonb_array_elements(o->'category_path') loop
   if jsonb_typeof(c)<>'object' or not(c ?& array['code','label','url']) or exists(select 1 from jsonb_object_keys(c) k where k not in ('code','label','url'))
    or jsonb_typeof(c->'code') is distinct from 'string' or jsonb_typeof(c->'label') is distinct from 'string' or jsonb_typeof(c->'url') is distinct from 'string'
    or c->>'code' !~ '^[A-Za-z0-9_-]{1,80}$' or length(btrim(c->>'label')) not between 1 and 200 or length(c->>'url')>2000
   then raise exception 'Catégorie source invalide'; end if;
   if (o->>'supplier'='Rexel' and (c->>'url' !~ '^https://www[.]rexel[.]fr/frx/([^?#[:space:]]+/)?c/[A-Za-z0-9_-]+$'
      or split_part(c->>'url','/c/',2)<>c->>'code'))
    or (o->>'supplier'='Sonepar' and (c->>'url' !~ '^https://www[.]sonepar[.]fr/catalog/fr-fr/category/[^/?#[:space:]]+$'
      or right(c->>'url',length(c->>'code')+1)<>'-'||(c->>'code'))) then raise exception 'URL/catégorie source incohérente'; end if;
  end loop;
  base:=jsonb_set(base,'{offers}',(base->'offers')||jsonb_build_array(o-array['raw_attributes','category_path','description','range']));
 end loop;
 if fiche->>'range' is not null and not exists(select 1 from jsonb_array_elements(fiche->'offers') x where x->>'range'=fiche->>'range')
 then raise exception 'Gamme sans source'; end if;
 if jsonb_typeof(fiche->'attributes') is distinct from 'array' or jsonb_typeof(fiche->'attribute_conflicts') is distinct from 'array'
 then raise exception 'Attributs et conflits attendus'; end if;
 if jsonb_array_length(fiche->'attributes')>100 or jsonb_array_length(fiche->'attribute_conflicts')>100 then raise exception 'Trop d’attributs'; end if;
 for r in select value from jsonb_array_elements(fiche->'attribute_conflicts') loop
  if jsonb_typeof(r)<>'string' or r#>>'{}' !~ '^[a-z][a-z0-9_]{0,59}$' then raise exception 'Conflit invalide'; end if;
 end loop;
 select id into cid from public.categories where code=fiche->>'category_code' and actif;
 if approuver and (cid is null or exists(select 1 from public.categories where parent_id=cid)
   or jsonb_array_length(fiche->'attribute_conflicts')>0) then raise exception 'Catégorie finale vérifiée et conflits résolus requis'; end if;
 for a in select value from jsonb_array_elements(fiche->'attributes') loop
  if jsonb_typeof(a)<>'object' or not(a ?& array['code','type','value','unit','supplier','raw_label','raw_value'])
   or exists(select 1 from jsonb_object_keys(a) k where k not in ('code','type','value','unit','supplier','raw_label','raw_value'))
  then raise exception 'Attribut normalisé invalide'; end if;
  select * into spec from public.attributs where code=a->>'code';
  if not found or (a->>'code')=any(codes) or a->>'type' is distinct from spec.type or a->>'unit' is distinct from spec.unite
  then raise exception 'Code, type ou unité d’attribut incohérent'; end if;
  codes:=array_append(codes,a->>'code');
  if jsonb_typeof(a->'value') is distinct from (case spec.type when 'text' then 'string' else spec.type end)
  then raise exception 'Type de valeur incorrect'; end if;
  if spec.type='number' and ((a->>'value')::numeric<0 or (a->>'value')::numeric>1000000000) then raise exception 'Nombre hors limites'; end if;
  if spec.type='text' and length(btrim(a->>'value')) not between 1 and 1000 then raise exception 'Texte vide'; end if;
  select x into source from jsonb_array_elements(fiche->'offers') x where x->>'supplier'=a->>'supplier';
  if source is null or not (source->'raw_attributes' @> jsonb_build_array(jsonb_build_object('label',a->'raw_label','value',a->'raw_value')))
  then raise exception 'Attribut sans provenance'; end if;
  if approuver and not exists(select 1 from public.categorie_attributs where categorie_id=cid and attribut_code=spec.code)
  then raise exception 'Attribut % non applicable à cette catégorie',spec.code; end if;
 end loop;
 -- Base importer validates official URLs, hashes, dates, GTIN and review_status;
 -- exceptions roll back the whole call including both staging documents.
 resultat:=public.importer_produit_collecte(base,approuver);
 empreinte:=encode(sha256(convert_to((fiche-'review_status')::text,'UTF8')),'hex');
 insert into public.collectes_catalogue(empreinte,donnees) values(empreinte,fiche-'review_status') on conflict do nothing;
 if not approuver then return (select jsonb_build_object('empreinte',cc.empreinte,'statut',cc.statut,'produit_id',cc.produit_id) from public.collectes_catalogue cc where cc.empreinte=v2.empreinte); end if;
 pid:=(resultat->>'produit_id')::bigint;
 select marque_id into mid from public.produits where id=pid;
 if fiche->>'range' is not null then
  insert into public.gammes(marque_id,nom) values(mid,btrim(fiche->>'range')) on conflict do nothing;
  select id into gid from public.gammes where marque_id=mid and lower(btrim(nom))=lower(btrim(fiche->>'range'));
 end if;
 delete from public.produit_attributs where produit_id=pid;
 update public.produits set categorie_id=cid,gamme_id=gid,
  description=coalesce((select nullif(x->>'description','') from jsonb_array_elements(fiche->'offers') x where nullif(x->>'description','') is not null limit 1),description) where id=pid;
 for a in select value from jsonb_array_elements(fiche->'attributes') loop
  select x into source from jsonb_array_elements(fiche->'offers') x where x->>'supplier'=a->>'supplier';
  insert into public.produit_attributs(produit_id,attribut_code,type,valeur_texte,valeur_nombre,valeur_booleen,source_url,observe_le,libelle_source,valeur_source)
  values(pid,a->>'code',a->>'type',case when a->>'type'='text' then a->>'value' end,
   case when a->>'type'='number' then (a->>'value')::numeric end,case when a->>'type'='boolean' then (a->>'value')::boolean end,
   source->>'url',(source->>'collected_at')::timestamptz,a->>'raw_label',a->>'raw_value');
 end loop;
 for o in select value from jsonb_array_elements(fiche->'offers') loop
  select id into fid from public.fournisseurs where lower(nom)=lower(o->>'supplier');
  for c in select value from jsonb_array_elements(o->'category_path') loop
   insert into public.categories_fournisseurs(fournisseur_id,code,nom,url) values(fid,c->>'code',c->>'label',c->>'url')
   on conflict(fournisseur_id,code) do update set nom=excluded.nom,url=excluded.url;
  end loop;
 end loop;
 update public.collectes_catalogue cc set statut='imported',produit_id=pid,valide_le=now() where cc.empreinte=v2.empreinte;
 return jsonb_build_object('empreinte',empreinte,'statut','imported','produit_id',pid);
end $$;
revoke all on function public.importer_catalogue_v2(jsonb,boolean) from public;
grant execute on function public.importer_catalogue_v2(jsonb,boolean) to authenticated,service_role;

-- OR within a facet, AND across facets. Numeric ranges use canonical units.
create function public.filtres_correspondent(dimensions jsonb, filtres jsonb, sauf text default null)
returns boolean language plpgsql immutable parallel safe security invoker set search_path='' as $$
declare f record; v text; n numeric;
begin
 for f in select * from jsonb_each(filtres) loop
  if f.key=sauf then continue; end if;
  if jsonb_typeof(f.value)='array' then
   if jsonb_array_length(f.value)>0 and not exists(
    select 1 from jsonb_array_elements_text(f.value) selected
    where coalesce(dimensions->f.key,'[]') @> jsonb_build_array(selected)) then return false; end if;
  else
   v:=dimensions->f.key->>0;
   if v is null then return false; end if;
   n:=v::numeric;
   if (f.value ? 'min' and n<(f.value->>'min')::numeric) or (f.value ? 'max' and n>(f.value->>'max')::numeric) then return false; end if;
  end if;
 end loop;
 return true;
end $$;
revoke all on function public.filtres_correspondent(jsonb,jsonb,text) from public;
grant execute on function public.filtres_correspondent(jsonb,jsonb,text) to anon,authenticated,service_role;

create function public.rechercher_catalogue_v2(terme text default '', filtres jsonb default '{}', page_num integer default 0)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare q text:=lower(btrim(left(coalesce(terme,''),100))); filtre record; v jsonb;
 tq tsquery:=plainto_tsquery('pg_catalog.french',public.texte_catalogue(left(coalesce(terme,''),100)));
 page integer:=greatest(0,least(coalesce(page_num,0),100000)); resultat jsonb;
begin
 if filtres is null or jsonb_typeof(filtres)<>'object' or octet_length(filtres::text)>12000 then raise exception 'Filtres invalides'; end if;
 if (select count(*) from jsonb_object_keys(filtres))>24 then raise exception 'Trop de filtres'; end if;
 for filtre in select * from jsonb_each(filtres) loop
  if filtre.key not in ('categorie','marque','gamme','fournisseur') and not exists(select 1 from public.attributs where 'a:'||code=filtre.key)
  then raise exception 'Filtre inconnu'; end if;
  if jsonb_typeof(filtre.value)='array' then
   if jsonb_array_length(filtre.value)>30 then raise exception 'Trop de valeurs'; end if;
   for v in select value from jsonb_array_elements(filtre.value) loop
    if jsonb_typeof(v)<>'string' or length(v#>>'{}')>1000 then raise exception 'Valeur de filtre invalide'; end if;
   end loop;
  elsif jsonb_typeof(filtre.value)='object' and exists(select 1 from public.attributs where 'a:'||code=filtre.key and type='number') then
   if filtre.value='{}' or exists(select 1 from jsonb_each(filtre.value) x where x.key not in ('min','max') or jsonb_typeof(x.value)<>'number')
    or (filtre.value->>'min')::numeric>(filtre.value->>'max')::numeric then raise exception 'Intervalle invalide'; end if;
  else raise exception 'Liste de valeurs ou intervalle numérique requis'; end if;
 end loop;
 with recursive chemins as (
  select id feuille,id,parent_id,code,nom from public.categories
  union all select ch.feuille,c.id,c.parent_id,c.code,c.nom from chemins ch join public.categories c on c.id=ch.parent_id
 ), base as materialized (
  select p.*,case when lower(btrim(p.ref_fabricant))=q or (q ~ '^([0-9]{8}|[0-9]{12,14})$' and p.code_ean is not null and lpad(p.code_ean,14,'0')=lpad(q,14,'0'))
    or p.references_fournisseurs @> array[q] then 2 else 0 end + ts_rank(p.recherche,tq) score
  from public.produits p where p.catalogue_verifie
   and not exists(select 1 from chemins ch join public.categories cat on cat.id=ch.id where ch.feuille=p.categorie_id and not cat.actif)
   and (q='' or p.recherche @@ tq
   or lower(btrim(p.ref_fabricant))=q or (q ~ '^([0-9]{8}|[0-9]{12,14})$' and p.code_ean is not null and lpad(p.code_ean,14,'0')=lpad(q,14,'0'))
   or p.references_fournisseurs @> array[q])
 ), dims as materialized (
  select b.id,b.nom,b.score,jsonb_build_object(
   'marque',case when b.marque_id is null then '[]'::jsonb else jsonb_build_array(b.marque_id::text) end,
   'gamme',case when b.gamme_id is null then '[]'::jsonb else jsonb_build_array(b.gamme_id::text) end,
   'categorie',coalesce((select jsonb_agg(ch.code) from chemins ch where ch.feuille=b.categorie_id),'[]'),
   'fournisseur',coalesce((select jsonb_agg(x->>'fournisseur') from jsonb_array_elements(b.sources_catalogue) x),'[]'))
   || coalesce((select jsonb_object_agg('a:'||pa.attribut_code,jsonb_build_array(coalesce(pa.valeur_texte,pa.valeur_nombre::text,pa.valeur_booleen::text)))
     from public.produit_attributs pa join public.categorie_attributs ca on ca.categorie_id=b.categorie_id and ca.attribut_code=pa.attribut_code
     where pa.produit_id=b.id and ca.filtrable),'{}') dimensions
  from base b
 ), matches as materialized (
  select * from dims d where public.filtres_correspondent(d.dimensions,filtres)
 ), pagines as (
  select b.* from base b join matches m on m.id=b.id order by b.score desc,b.nom,b.id limit 24 offset page*24
 ), comptes as (
  select e.key,k.value,count(*) nombre from dims d cross join lateral jsonb_each(d.dimensions) e
   cross join lateral jsonb_array_elements_text(e.value) k
   where public.filtres_correspondent(d.dimensions,filtres,e.key) group by e.key,k.value
 ), facettes as (
  select c.key,coalesce(a.nom,case c.key when 'categorie' then 'Catégorie' when 'marque' then 'Marque' when 'gamme' then 'Gamme' when 'fournisseur' then 'Fournisseur' end) label,
   coalesce(a.type,'text') type,coalesce(a.unite,'') unit,coalesce(a.ordre,0) ordre,
   jsonb_agg(jsonb_build_object('value',c.value,'count',c.nombre,'label',
    case c.key when 'marque' then (select nom from public.marques where id=c.value::bigint)
     when 'gamme' then (select g.nom||' · '||m.nom from public.gammes g join public.marques m on m.id=g.marque_id where g.id=c.value::bigint)
     when 'categorie' then (select nom from public.categories where code=c.value)
     else case when a.type='boolean' then case c.value when 'true' then 'Oui' else 'Non' end else c.value end end)
    order by case when a.type='number' then c.value::numeric end,c.value) valeurs
  from comptes c left join public.attributs a on 'a:'||a.code=c.key group by c.key,a.nom,a.type,a.unite,a.ordre
 )
 select jsonb_build_object('total',(select count(*) from matches),'page',page,'page_size',24,
 'items',coalesce((select jsonb_agg(jsonb_build_object(
   'id',p.id,'ref_fabricant',p.ref_fabricant,'code_ean',p.code_ean,'nom',p.nom,'marque',p.marque,'gamme',p.gamme_nom,
   'image_url',p.image_url,'description',p.description,'categorie',(select nom from public.categories where id=p.categorie_id),
   'sources',p.sources_catalogue,'attributs',coalesce((select jsonb_agg(jsonb_build_object('code',a.code,'nom',a.nom,'type',a.type,'unite',a.unite,
      'valeur',coalesce(to_jsonb(pa.valeur_texte),to_jsonb(pa.valeur_nombre),to_jsonb(pa.valeur_booleen)),'source_url',pa.source_url) order by a.ordre,a.code)
      from public.produit_attributs pa join public.attributs a on a.code=pa.attribut_code where pa.produit_id=p.id),'[]'),
   'offres',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'fournisseur',f.nom,'prix',o.prix,'nature_prix',o.nature_prix,
      'ref_fournisseur',o.ref_fournisseur,'reference_verifiee',o.reference_verifiee,'conditionnement',o.conditionnement,
      'date_verification',o.date_verification,'url_produit',o.url_produit) order by f.nom)
      from public.produits_fournisseurs o join public.fournisseurs f on f.id=o.fournisseur_id where o.produit_id=p.id and o.reference_verifiee),'[]'))
    order by p.score desc,p.nom,p.id) from pagines p),'[]'),
 'facets',coalesce((select jsonb_agg(jsonb_build_object('key',key,'label',label,'type',type,'unit',unit,'values',valeurs) order by ordre,key) from facettes),'[]'),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'code',code,'nom',nom,'parent_id',parent_id,'ordre',ordre) order by ordre,nom) from public.categories where actif),'[]')
 ) into resultat;
 return resultat;
end $$;
revoke all on function public.rechercher_catalogue_v2(text,jsonb,integer) from public;
grant execute on function public.rechercher_catalogue_v2(text,jsonb,integer) to anon,authenticated,service_role;
revoke all on function public.texte_catalogue(text) from public;
grant execute on function public.texte_catalogue(text) to anon,authenticated,service_role;
-- Trigger functions cannot be called as RPCs; no direct execution grants needed.
revoke all on function public.verrouiller_categories(),public.verifier_arbre_categories(),
 public.synchroniser_marque_produit(),public.actualiser_identites_catalogue(),public.actualiser_sources_produit(),
 public.verifier_offre_panier(),public.verifier_attribut_produit(),public.verifier_reclassement_produit() from public;
commit;
$migration_20261015130122$]);

notify pgrst, 'reload schema';
commit;
select (select count(*) from public.produits) produits,(select count(*) from public.produits_fournisseurs) offres,(select count(*) from public.clients) comptes,(select count(*) from public.paniers) paniers,(select count(*) from public.categories) categories,(select count(*) from public.attributs) attributs;


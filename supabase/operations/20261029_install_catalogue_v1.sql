-- 2HBC / gueuqeqyshhhmxbsiuxg. Empty catalogue installation; no DELETE/TRUNCATE.
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


-- 20261012163203_catalogue_integrity_import.sql
-- Existing objects also inherited broad Supabase default privileges.
-- Keep nextval for authenticated inserts, but forbid setval and anonymous access.
revoke all on sequence public.segments_clients_id_seq,public.categories_id_seq,
 public.fournisseurs_id_seq,public.produits_id_seq,public.produits_fournisseurs_id_seq,
 public.paniers_id_seq,public.articles_panier_id_seq,public.besoins_clients_id_seq
 from public,anon,authenticated;
grant usage,select on sequence public.segments_clients_id_seq,public.categories_id_seq,
 public.fournisseurs_id_seq,public.produits_id_seq,public.produits_fournisseurs_id_seq,
 public.paniers_id_seq,public.articles_panier_id_seq,public.besoins_clients_id_seq
 to authenticated,service_role;
revoke execute on function public.ajouter_au_panier(bigint,integer) from public,anon;

-- GTIN-8/12/13/14 : longueur ET clé de contrôle, références conservées en texte.
create function public.gtin_valide(code text) returns boolean
language sql immutable strict parallel safe security invoker set search_path='' as $$
 select case when code ~ '^([0-9]{8}|[0-9]{12,14})$' then
   (select sum(substring(code from i for 1)::int *
      case when (length(code)-i)%2=0 then 1 else 3 end)%10=0
    from generate_series(1,length(code)) i)
 else false end;
$$;
revoke all on function public.gtin_valide(text) from public,anon,authenticated;
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
revoke all on public.collectes_catalogue from public,anon,authenticated;
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
revoke all on function public.importer_produit_collecte(jsonb,boolean) from public,anon,authenticated;
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

insert into supabase_migrations.schema_migrations(version,name,statements) values('20261012163203','catalogue_integrity_import',array[$migration_20261012163203$-- Existing objects also inherited broad Supabase default privileges.
-- Keep nextval for authenticated inserts, but forbid setval and anonymous access.
revoke all on sequence public.segments_clients_id_seq,public.categories_id_seq,
 public.fournisseurs_id_seq,public.produits_id_seq,public.produits_fournisseurs_id_seq,
 public.paniers_id_seq,public.articles_panier_id_seq,public.besoins_clients_id_seq
 from public,anon,authenticated;
grant usage,select on sequence public.segments_clients_id_seq,public.categories_id_seq,
 public.fournisseurs_id_seq,public.produits_id_seq,public.produits_fournisseurs_id_seq,
 public.paniers_id_seq,public.articles_panier_id_seq,public.besoins_clients_id_seq
 to authenticated,service_role;
revoke execute on function public.ajouter_au_panier(bigint,integer) from public,anon;

-- GTIN-8/12/13/14 : longueur ET clé de contrôle, références conservées en texte.
create function public.gtin_valide(code text) returns boolean
language sql immutable strict parallel safe security invoker set search_path='' as $$
 select case when code ~ '^([0-9]{8}|[0-9]{12,14})$' then
   (select sum(substring(code from i for 1)::int *
      case when (length(code)-i)%2=0 then 1 else 3 end)%10=0
    from generate_series(1,length(code)) i)
 else false end;
$$;
revoke all on function public.gtin_valide(text) from public,anon,authenticated;
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
revoke all on public.collectes_catalogue from public,anon,authenticated;
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
revoke all on function public.importer_produit_collecte(jsonb,boolean) from public,anon,authenticated;
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
$$;$migration_20261012163203$]);

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
revoke all on function public.image_catalogue_valide(text,text) from public,anon,authenticated;
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

insert into supabase_migrations.schema_migrations(version,name,statements) values('20261013131653','catalogue_images',array[$migration_20261013131653$alter table public.produits add column image_source_url text
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
revoke all on function public.image_catalogue_valide(text,text) from public,anon,authenticated;
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
$$;$migration_20261013131653$]);

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
alter table public.marques enable row level security;
create unique index marques_nom on public.marques(lower(btrim(nom)));
create table public.gammes(id bigint generated by default as identity primary key,
 marque_id bigint not null references public.marques(id), nom text not null check(length(btrim(nom)) between 1 and 200), unique(id,marque_id));
alter table public.gammes enable row level security;
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
alter table public.attributs enable row level security;
create table public.categorie_attributs(
 categorie_id bigint not null references public.categories(id) on delete cascade,
 attribut_code text not null references public.attributs(code),
 filtrable boolean not null default true, ordre integer not null default 0,
 primary key(categorie_id,attribut_code)
);
alter table public.categorie_attributs enable row level security;
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
alter table public.produit_attributs enable row level security;
create index produit_attribut_texte on public.produit_attributs(attribut_code,valeur_texte,produit_id) where type='text';
create index produit_attribut_nombre on public.produit_attributs(attribut_code,valeur_nombre,produit_id) where type='number';
create index produit_attribut_booleen on public.produit_attributs(attribut_code,valeur_booleen,produit_id) where type='boolean';
create table public.categories_fournisseurs(
 fournisseur_id bigint not null references public.fournisseurs(id), code text not null,
 nom text not null, url text not null, categorie_id bigint references public.categories(id),
 correspondance_verifiee boolean not null default false,
 primary key(fournisseur_id,code), check(not correspondance_verifiee or categorie_id is not null)
);
alter table public.categories_fournisseurs enable row level security;
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
-- Backfill only products with a brand to normalize; no global UPDATE.
update public.produits set marque=marque where nullif(btrim(marque),'') is not null;
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
-- Only verified references belong in the new public projection.
update public.produits_fournisseurs set reference_verifiee=reference_verifiee where reference_verifiee;

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
revoke all on function public.verifier_applicabilite_catalogue() from public,anon,authenticated;
create index produit_attribut_definition on public.produit_attributs(attribut_code,type);

-- Public reference tables, administrative writes only.
do $$ declare t text; begin
 foreach t in array array['marques','gammes','attributs','categorie_attributs','categories_fournisseurs','produit_attributs'] loop
  -- Remove inherited Supabase defaults, including TRUNCATE (not covered by RLS).
  execute format('revoke all on public.%I from public,anon,authenticated',t);
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
revoke all on sequence public.marques_id_seq,public.gammes_id_seq from public,anon,authenticated;
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
revoke all on function public.importer_catalogue_v2(jsonb,boolean) from public,anon,authenticated;
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
revoke all on function public.filtres_correspondent(jsonb,jsonb,text) from public,anon,authenticated;
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
revoke all on function public.rechercher_catalogue_v2(text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.rechercher_catalogue_v2(text,jsonb,integer) to anon,authenticated,service_role;
revoke all on function public.texte_catalogue(text) from public,anon,authenticated;
grant execute on function public.texte_catalogue(text) to anon,authenticated,service_role;
-- Trigger functions cannot be called as RPCs; no direct execution grants needed.
revoke all on function public.verrouiller_categories(),public.verifier_arbre_categories(),
 public.synchroniser_marque_produit(),public.actualiser_identites_catalogue(),public.actualiser_sources_produit(),
 public.verifier_offre_panier(),public.verifier_attribut_produit(),public.verifier_reclassement_produit() from public,anon,authenticated;

insert into supabase_migrations.schema_migrations(version,name,statements) values('20261015130122','catalogue_facets',array[$migration_20261015130122$-- Stable category codes, with a tree that cannot contain indirect cycles.
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
alter table public.marques enable row level security;
create unique index marques_nom on public.marques(lower(btrim(nom)));
create table public.gammes(id bigint generated by default as identity primary key,
 marque_id bigint not null references public.marques(id), nom text not null check(length(btrim(nom)) between 1 and 200), unique(id,marque_id));
alter table public.gammes enable row level security;
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
alter table public.attributs enable row level security;
create table public.categorie_attributs(
 categorie_id bigint not null references public.categories(id) on delete cascade,
 attribut_code text not null references public.attributs(code),
 filtrable boolean not null default true, ordre integer not null default 0,
 primary key(categorie_id,attribut_code)
);
alter table public.categorie_attributs enable row level security;
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
alter table public.produit_attributs enable row level security;
create index produit_attribut_texte on public.produit_attributs(attribut_code,valeur_texte,produit_id) where type='text';
create index produit_attribut_nombre on public.produit_attributs(attribut_code,valeur_nombre,produit_id) where type='number';
create index produit_attribut_booleen on public.produit_attributs(attribut_code,valeur_booleen,produit_id) where type='boolean';
create table public.categories_fournisseurs(
 fournisseur_id bigint not null references public.fournisseurs(id), code text not null,
 nom text not null, url text not null, categorie_id bigint references public.categories(id),
 correspondance_verifiee boolean not null default false,
 primary key(fournisseur_id,code), check(not correspondance_verifiee or categorie_id is not null)
);
alter table public.categories_fournisseurs enable row level security;
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
-- Backfill only products with a brand to normalize; no global UPDATE.
update public.produits set marque=marque where nullif(btrim(marque),'') is not null;
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
-- Only verified references belong in the new public projection.
update public.produits_fournisseurs set reference_verifiee=reference_verifiee where reference_verifiee;

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
revoke all on function public.verifier_applicabilite_catalogue() from public,anon,authenticated;
create index produit_attribut_definition on public.produit_attributs(attribut_code,type);

-- Public reference tables, administrative writes only.
do $$ declare t text; begin
 foreach t in array array['marques','gammes','attributs','categorie_attributs','categories_fournisseurs','produit_attributs'] loop
  -- Remove inherited Supabase defaults, including TRUNCATE (not covered by RLS).
  execute format('revoke all on public.%I from public,anon,authenticated',t);
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
revoke all on sequence public.marques_id_seq,public.gammes_id_seq from public,anon,authenticated;
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
revoke all on function public.importer_catalogue_v2(jsonb,boolean) from public,anon,authenticated;
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
revoke all on function public.filtres_correspondent(jsonb,jsonb,text) from public,anon,authenticated;
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
revoke all on function public.rechercher_catalogue_v2(text,jsonb,integer) from public,anon,authenticated;
grant execute on function public.rechercher_catalogue_v2(text,jsonb,integer) to anon,authenticated,service_role;
revoke all on function public.texte_catalogue(text) from public,anon,authenticated;
grant execute on function public.texte_catalogue(text) to anon,authenticated,service_role;
-- Trigger functions cannot be called as RPCs; no direct execution grants needed.
revoke all on function public.verrouiller_categories(),public.verifier_arbre_categories(),
 public.synchroniser_marque_produit(),public.actualiser_identites_catalogue(),public.actualiser_sources_produit(),
 public.verifier_offre_panier(),public.verifier_attribut_produit(),public.verifier_reclassement_produit() from public,anon,authenticated;$migration_20261015130122$]);

-- 20261029161909_catalogue_modele_metier_v1.sql
-- Catalogue métier v1. Additive: no product, account or cart deletion.
alter table public.attributs add column format_valeur text not null default 'text'
 check(format_valeur in ('text','number','boolean','choice','set','range')),
 add column entier boolean not null default false,
 add column contexte_requis jsonb not null default '{}' check(jsonb_typeof(contexte_requis)='object'),
 add column actif boolean not null default false;
alter table public.categorie_attributs add column essentiel boolean not null default false,
 add column actif boolean not null default false;
alter table public.produits add column statut_qualification text not null default 'collecte'
 check(statut_qualification in ('collecte','a_revoir','publie')),
 add column qualification_le timestamptz;
create index produits_publication on public.produits(categorie_id,id)
 where catalogue_verifie and statut_qualification='publie';

create table public.attribut_valeurs(
 attribut_code text not null references public.attributs(code),
 code text not null check(length(code) between 1 and 100),
 libelle text not null check(length(btrim(libelle)) between 1 and 200),
 primary key(attribut_code,code)
);
alter table public.attribut_valeurs enable row level security;
create table public.categorie_exigences(
 categorie_id bigint not null references public.categories(id),
 code text not null check(code in ('gamme','compatibilite','gamme_ou_compatibilite','entraxe_multiposte','coupure','sections')),
 primary key(categorie_id,code)
);
alter table public.categorie_exigences enable row level security;
create table public.observations_attributs(
 id bigint generated by default as identity primary key,
 produit_id bigint not null references public.produits(id),
 attribut_code text not null references public.attributs(code),
 valeur jsonb, unite text not null default '',
 contexte jsonb not null default '{}' check(jsonb_typeof(contexte)='object' and octet_length(contexte::text)<=2000),
 libelle_source text not null check(length(btrim(libelle_source)) between 1 and 200),
 valeur_source text not null check(length(btrim(valeur_source)) between 1 and 4000),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/' and length(source_url)<=2000),
 observe_le timestamptz not null, regle_version text not null check(length(btrim(regle_version)) between 1 and 100),
 statut text not null default 'observee' check(statut in ('observee','validee','conflit','rejetee')),
 motif_revue text check(length(motif_revue)<=2000),
 cree_le timestamptz not null default now(),
 unique(id,produit_id,attribut_code),
 check(octet_length(coalesce(valeur::text,''))<=8000),
 check(statut not in ('conflit','rejetee') or (motif_revue is not null and length(btrim(motif_revue))>0))
);
alter table public.observations_attributs enable row level security;
create index observations_produit_attribut on public.observations_attributs(produit_id,attribut_code);
create index observations_attribut on public.observations_attributs(attribut_code);
create table public.valeurs_catalogue(
 produit_id bigint not null references public.produits(id),
 attribut_code text not null references public.attributs(code),
 contexte jsonb not null default '{}' check(jsonb_typeof(contexte)='object' and octet_length(contexte::text)<=2000),
 valeur jsonb, observation_id bigint,
 statut text not null default 'valide' check(statut in ('valide','non_applicable')),
 motif text, source_exception text,
 valide_le timestamptz not null default now(),
 primary key(produit_id,attribut_code,contexte),
 foreign key(observation_id,produit_id,attribut_code) references public.observations_attributs(id,produit_id,attribut_code),
 check((statut='valide' and observation_id is not null and valeur is not null and valeur<>'null'::jsonb and motif is null and source_exception is null)
   or (statut='non_applicable' and observation_id is null and valeur is null
    and motif is not null and source_exception is not null and length(btrim(motif)) between 10 and 2000 and source_exception ~ '^https://[^/@?#[:space:]]+/'))
);
alter table public.valeurs_catalogue enable row level security;
create index valeurs_observation on public.valeurs_catalogue(observation_id,produit_id,attribut_code);
create index valeurs_attribut on public.valeurs_catalogue(attribut_code);
create index valeurs_json on public.valeurs_catalogue using gin(valeur jsonb_path_ops) where statut='valide';
create table public.compatibilites_produits(
 id bigint generated by default as identity primary key,
 produit_id bigint not null references public.produits(id),
 cible_produit_id bigint references public.produits(id),
 systeme text, version_systeme text,
 role_relation text not null check(role_relation in ('accessoire_pour','compatible_avec')),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/' and length(source_url)<=2000),
 observe_le timestamptz not null,
 statut text not null default 'a_revoir' check(statut in ('a_revoir','valide','rejete')),
 preuve text not null check(length(btrim(preuve)) between 10 and 4000),
 check(cible_produit_id is distinct from produit_id),
 check((cible_produit_id is not null and systeme is null and version_systeme is null)
    or (cible_produit_id is null and systeme is not null and version_systeme is not null
        and length(btrim(systeme)) between 1 and 200 and length(btrim(version_systeme)) between 1 and 100))
);
alter table public.compatibilites_produits enable row level security;
create index compatibilites_produit on public.compatibilites_produits(produit_id);
create index compatibilites_cible on public.compatibilites_produits(cible_produit_id);
create unique index compatibilites_uniques on public.compatibilites_produits(produit_id,cible_produit_id,systeme,version_systeme,role_relation) nulls not distinct;
create table public.regles_categories_fournisseurs(
 id bigint generated by default as identity primary key,
 fournisseur_id bigint not null, code_source text not null,
 categorie_id bigint not null references public.categories(id),
 conditions jsonb not null check(jsonb_typeof(conditions)='object' and octet_length(conditions::text)<=8000),
 version text not null check(length(btrim(version)) between 1 and 100),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/'),
 preuve text not null check(length(btrim(preuve)) between 10 and 4000),
 valide_le timestamptz, actif boolean not null default false,
 foreign key(fournisseur_id,code_source) references public.categories_fournisseurs(fournisseur_id,code),
 check(not actif or valide_le is not null),
 unique(fournisseur_id,code_source,categorie_id,version)
);
alter table public.regles_categories_fournisseurs enable row level security;
create index regles_categorie on public.regles_categories_fournisseurs(categorie_id);
create table public.alias_attributs(
 fournisseur_id bigint not null references public.fournisseurs(id),
 categorie_id bigint not null references public.categories(id),
 libelle_source text not null check(length(btrim(libelle_source)) between 1 and 200),
 attribut_code text not null references public.attributs(code),
 contexte jsonb not null default '{}' check(jsonb_typeof(contexte)='object'),
 regle_version text not null check(length(btrim(regle_version)) between 1 and 100),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/'),
 valide_le timestamptz,
 primary key(fournisseur_id,categorie_id,libelle_source,regle_version)
);
alter table public.alias_attributs enable row level security;
create index alias_categorie on public.alias_attributs(categorie_id);
create index alias_attribut on public.alias_attributs(attribut_code);

create function public.controler_compatibilite() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.observe_le>now()+interval '5 minutes' then raise exception 'Compatibilité dans le futur'; end if;
 return new;
end $$;
create trigger compatibilite_controle before insert or update on public.compatibilites_produits for each row execute function public.controler_compatibilite();

-- Every business write is serialized with the import lock, including publication.
create function public.verrou_catalogue_metier() returns trigger language plpgsql security invoker set search_path='' as $$
begin perform pg_advisory_xact_lock(2042,1); return null; end $$;
do $$ declare t text; begin
 foreach t in array array['produits','produits_fournisseurs','attributs','attribut_valeurs','categories','categorie_attributs',
  'categorie_exigences','observations_attributs','valeurs_catalogue','compatibilites_produits','produit_attributs'] loop
  execute format('create trigger a_verrou_metier before insert or update or delete on public.%I for each statement execute function public.verrou_catalogue_metier()',t);
 end loop;
end $$;

create function public.valeur_metier_valide(code_attribut text,v jsonb,u text,ctx jsonb)
returns boolean language plpgsql stable security invoker set search_path='' as $$
declare a public.attributs%rowtype; x jsonb; n numeric;
begin
 select * into a from public.attributs where code=code_attribut and actif;
 if not found or v is null or v='null'::jsonb or u is distinct from a.unite
  or jsonb_typeof(ctx) is distinct from 'object' or not(ctx @> a.contexte_requis) then return false; end if;
 if a.format_valeur='number' then
  if jsonb_typeof(v)<>'number' then return false; end if;
  n:=(v#>>'{}')::numeric; return n between 0 and 1000000000 and (not a.entier or n=trunc(n));
 elsif a.format_valeur='boolean' then return jsonb_typeof(v)='boolean';
 elsif a.format_valeur='text' then
  if jsonb_typeof(v)<>'string' or length(btrim(v#>>'{}')) not between 1 and 1000 then return false; end if;
  if a.code='ip' then return coalesce((v#>>'{}') ~ '^IP[0-6X][0-9X][A-D]?[HMSW]?$' and jsonb_typeof(ctx->'assemblage')='string' and length(btrim(ctx->>'assemblage'))>0,false); end if;
  if a.code='ik' then return (v#>>'{}') ~ '^IK(0[0-9]|10|11)$'; end if;
  return true;
 elsif a.format_valeur='choice' then
  return jsonb_typeof(v)='string' and exists(select 1 from public.attribut_valeurs where attribut_code=a.code and code=v#>>'{}');
 elsif a.format_valeur='set' then
  if jsonb_typeof(v)<>'array' then return false; end if;
  if jsonb_array_length(v) not between 1 and 30 then return false; end if;
  if (select count(*)<>count(distinct value) from jsonb_array_elements(v)) then return false; end if;
  for x in select value from jsonb_array_elements(v) loop
   if jsonb_typeof(x)<>'string' or not exists(select 1 from public.attribut_valeurs where attribut_code=a.code and code=x#>>'{}') then return false; end if;
  end loop; return true;
 elsif a.format_valeur='range' then
  if jsonb_typeof(v)<>'object' then return false; end if;
  if not(v ?& array['min','max']) or exists(select 1 from jsonb_object_keys(v) k where k not in ('min','max'))
   or jsonb_typeof(v->'min') is distinct from 'number' or jsonb_typeof(v->'max') is distinct from 'number'
  then return false; end if;
  return (v->>'min')::numeric>=0 and (v->>'max')::numeric<1000000000 and (v->>'min')::numeric<=(v->>'max')::numeric;
 end if; return false;
exception when invalid_text_representation then return false;
end $$;

create function public.controler_observation() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op<>'INSERT' and exists(select 1 from public.valeurs_catalogue where observation_id=old.id) then
  raise exception 'Observation retenue immuable : retirer la sélection avant de la réviser'; end if;
 if tg_op='DELETE' then return old; end if;
 if new.observe_le>now()+interval '5 minutes' then raise exception 'Observation dans le futur'; end if;
 if new.statut='validee' and public.valeur_metier_valide(new.attribut_code,new.valeur,new.unite,new.contexte) is not true
 then raise exception 'Valeur, unité, vocabulaire ou contexte invalide'; end if;
 if new.statut in ('conflit','rejetee') and nullif(btrim(new.motif_revue),'') is null then raise exception 'Motif de revue requis'; end if;
 return new;
end $$;
create trigger observation_controle before insert or update or delete on public.observations_attributs for each row execute function public.controler_observation();
create function public.controler_valeur_catalogue() returns trigger language plpgsql security invoker set search_path='' as $$
declare o public.observations_attributs%rowtype;
begin
 if not exists(select 1 from public.produits p join public.categorie_attributs ca on ca.categorie_id=p.categorie_id
  where p.id=new.produit_id and ca.attribut_code=new.attribut_code and ca.actif)
 then raise exception 'Attribut non applicable à cette famille'; end if;
 if new.valide_le>now()+interval '5 minutes' then raise exception 'Validation dans le futur'; end if;
 if new.statut='valide' then
  select * into o from public.observations_attributs where id=new.observation_id and produit_id=new.produit_id and attribut_code=new.attribut_code;
  if not found or o.statut<>'validee' or o.valeur is distinct from new.valeur or o.contexte is distinct from new.contexte
   or public.valeur_metier_valide(new.attribut_code,new.valeur,o.unite,new.contexte) is not true
  then raise exception 'Valeur sans observation validée correspondante'; end if;
 elsif new.valeur is not null or new.observation_id is not null or new.motif is null or length(btrim(new.motif))<10
   or new.source_exception is null or new.source_exception !~ '^https://[^/@?#[:space:]]+/'
 then raise exception 'Non applicable : motif et source requis'; end if;
 return new;
end $$;
create trigger valeur_catalogue_controle before insert or update on public.valeurs_catalogue for each row execute function public.controler_valeur_catalogue();

-- Useful to the later search API: a value must be INSIDE a documented interval.
create function public.intervalle_catalogue_contient(plage jsonb,n numeric) returns boolean
language sql immutable security invoker set search_path='' as $$
 select coalesce(jsonb_typeof(plage)='object' and jsonb_typeof(plage->'min')='number' and jsonb_typeof(plage->'max')='number'
 and n between (plage->>'min')::numeric and (plage->>'max')::numeric,false);
$$;

create function public.diagnostic_publication(pid bigint) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare p public.produits%rowtype; erreurs text[]:='{}'; r record; type_cond text; cle text;
begin
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Diagnostic réservé à un administrateur' using errcode='42501'; end if;
 select * into p from public.produits where id=pid;
 if not found then raise exception 'Produit inconnu'; end if;
 if not p.catalogue_verifie or p.code_ean is null or not public.gtin_valide(p.code_ean)
  or p.source_catalogue is null or p.catalogue_verifie_le is null or nullif(btrim(p.marque),'') is null
 then erreurs:=array_append(erreurs,'identite_non_verifiee'); end if;
 if not exists(select 1 from public.categories c where c.id=p.categorie_id and c.actif and
   not exists(select 1 from public.categories e where e.parent_id=c.id))
  or exists(with recursive arbre as(select id,parent_id,actif from public.categories where id=p.categorie_id
   union all select c.id,c.parent_id,c.actif from public.categories c join arbre a on c.id=a.parent_id)
   select 1 from arbre where not actif)
 then erreurs:=array_append(erreurs,'categorie_finale_inactive_ou_absente'); end if;
 if not exists(select 1 from public.produits_fournisseurs where produit_id=pid and reference_verifiee)
 then erreurs:=array_append(erreurs,'offre_verifiee_absente'); end if;
 for r in select ca.attribut_code from public.categorie_attributs ca where ca.categorie_id=p.categorie_id and ca.essentiel and ca.actif loop
  if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code=r.attribut_code)
  then erreurs:=array_append(erreurs,'manquant:'||r.attribut_code); end if;
 end loop;
 if exists(select 1 from public.valeurs_catalogue v where v.produit_id=pid and not exists(
   select 1 from public.categorie_attributs ca where ca.categorie_id=p.categorie_id and ca.attribut_code=v.attribut_code and ca.actif))
 then erreurs:=array_append(erreurs,'attribut_incompatible'); end if;
 -- Recheck retained values against the current dictionary, even when they were
 -- selected before an administrative vocabulary change.
 if exists(select 1 from public.valeurs_catalogue v left join public.observations_attributs o on o.id=v.observation_id
  where v.produit_id=pid and v.statut='valide' and (o.statut is distinct from 'validee'
   or o.produit_id is distinct from v.produit_id or o.attribut_code is distinct from v.attribut_code
   or o.valeur is distinct from v.valeur or o.contexte is distinct from v.contexte
   or public.valeur_metier_valide(v.attribut_code,v.valeur,o.unite,v.contexte) is not true))
 then erreurs:=array_append(erreurs,'valeur_retenue_invalide'); end if;
 -- An observation explicitly in conflict, or disagreeing candidates in the SAME
 -- context, cannot silently be suppressed by selecting one candidate.
 if exists(select 1 from public.observations_attributs where produit_id=pid and statut='conflit')
 or exists(select 1 from public.observations_attributs o join public.attributs a on a.code=o.attribut_code
  where o.produit_id=pid and o.statut in ('observee','validee') and o.valeur is not null
  group by o.attribut_code,o.contexte having count(distinct
   case when a.format_valeur='set' and jsonb_typeof(o.valeur)='array'
    then (select jsonb_agg(e.value order by e.value) from jsonb_array_elements(o.valeur) e)
    else o.valeur end)>1)
 then erreurs:=array_append(erreurs,'conflit_non_resolu'); end if;
 for r in select code from public.categorie_exigences where categorie_id=p.categorie_id loop
  if r.code='gamme' and p.gamme_id is null then erreurs:=array_append(erreurs,'gamme_absente');
  elsif r.code in ('compatibilite','gamme_ou_compatibilite') then
   if (r.code='compatibilite' or p.gamme_id is null) and not exists(select 1 from public.compatibilites_produits where produit_id=pid and statut='valide')
   then erreurs:=array_append(erreurs,'compatibilite_absente'); end if;
  elsif r.code='entraxe_multiposte' then
   if exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code='postes' and statut='valide' and (valeur#>>'{}')::numeric>1)
    and not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code='entraxe')
   then erreurs:=array_append(erreurs,'entraxe_absent'); end if;
  elsif r.code='coupure' then
   if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code in ('icn_230','icn_400','icn_61009_230','icn_61009_400','icu_230','icu_400') and statut='valide')
   then erreurs:=array_append(erreurs,'coupure_qualifiee_absente'); end if;
  elsif r.code='sections' then
   if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code like 'section_%' and statut='valide')
   then erreurs:=array_append(erreurs,'plages_sections_absentes'); end if;
   for type_cond in select jsonb_array_elements_text(valeur) from public.valeurs_catalogue where produit_id=pid and attribut_code='types_conducteurs' and statut='valide' loop
    cle:=case type_cond when 'massif' then 'section_rigide' when 'multifilaire_rigide' then 'section_multifilaire' else 'section_souple' end;
    if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and statut='valide' and
      (attribut_code=cle or (cle='section_souple' and attribut_code in ('section_souple_sans_embout','section_souple_avec_embout'))))
    then erreurs:=array_append(erreurs,'plage_manquante:'||type_cond); end if;
   end loop;
  end if;
 end loop;
 return jsonb_build_object('produit_id',pid,'publiable',cardinality(erreurs)=0,'erreurs',to_jsonb(erreurs));
end $$;

create function public.controler_publication_metier() returns trigger language plpgsql security invoker set search_path='' as $$
declare diagnostic jsonb;
begin
 if tg_op='INSERT' and new.statut_qualification='publie' then raise exception 'Créer la fiche puis qualifier avant publication'; end if;
 if tg_op='UPDATE' and new.statut_qualification='publie' and
  row(new.categorie_id,new.gamme_id,new.marque,new.ref_fabricant,new.code_ean,new.catalogue_verifie,new.source_catalogue)
  is distinct from row(old.categorie_id,old.gamme_id,old.marque,old.ref_fabricant,old.code_ean,old.catalogue_verifie,old.source_catalogue)
 then new.statut_qualification:='a_revoir'; new.qualification_le:=null; end if;
 if new.statut_qualification='publie' then
  diagnostic:=public.diagnostic_publication(new.id);
  if not (diagnostic->>'publiable')::boolean then raise exception 'Publication refusée : %',diagnostic->'erreurs'; end if;
  new.qualification_le:=now();
 else new.qualification_le:=null; end if;
 return new;
end $$;
create trigger z_publication_metier before insert or update on public.produits for each row execute function public.controler_publication_metier();
create function public.invalider_qualification() returns trigger language plpgsql security invoker set search_path='' as $$
declare ids bigint[];
begin
 ids:=case when tg_op='INSERT' then array[new.produit_id] when tg_op='DELETE' then array[old.produit_id] else array[old.produit_id,new.produit_id] end;
 update public.produits set statut_qualification='a_revoir',qualification_le=null where id=any(ids) and statut_qualification='publie';
 return null;
end $$;
do $$ declare t text; begin
 foreach t in array array['observations_attributs','valeurs_catalogue','compatibilites_produits','produits_fournisseurs','produit_attributs'] loop
  execute format('create trigger a_invalider_qualification after insert or update or delete on public.%I for each row execute function public.invalider_qualification()',t);
 end loop;
end $$;
-- Administrative dictionary changes require a deliberate unpublication first.
create function public.proteger_referentiel_publie() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.produits where statut_qualification='publie') then
  raise exception 'Dépublier les fiches avant de modifier le référentiel'; end if;
 return null;
end $$;
do $$ declare t text; begin
 foreach t in array array['attributs','attribut_valeurs','categorie_attributs','categorie_exigences','categories'] loop
  execute format('create trigger proteger_referentiel before insert or update or delete on public.%I for each statement execute function public.proteger_referentiel_publie()',t);
 end loop;
end $$;
create function public.publier_produit_catalogue(pid bigint) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(2042,1);
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Publication réservée à un administrateur' using errcode='42501'; end if;
 perform 1 from public.produits where id=pid for update;
 if not found then raise exception 'Produit inconnu'; end if;
 update public.produits set statut_qualification='publie' where id=pid;
 return public.diagnostic_publication(pid);
end $$;

-- Publication is enforced on every public read, including legacy RPCs.
drop policy produits_lecture on public.produits;
create policy produits_lecture on public.produits for select to anon,authenticated using(
 (catalogue_verifie and statut_qualification='publie') or (select auth.jwt())->'app_metadata'->>'role'='admin');
drop policy offres_lecture on public.produits_fournisseurs;
create policy offres_lecture on public.produits_fournisseurs for select to authenticated using(
 (select auth.uid()) is not null and not coalesce(((select auth.jwt())->>'is_anonymous')::boolean,false) and
 ((reference_verifiee and exists(select 1 from public.produits p where p.id=produit_id and p.statut_qualification='publie'))
 or (select auth.jwt())->'app_metadata'->>'role'='admin'));
create or replace function public.verifier_offre_panier() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.produits_fournisseurs o join public.produits p on p.id=o.produit_id
  where o.id=new.offre_id and o.reference_verifiee and p.catalogue_verifie and p.statut_qualification='publie')
 then raise exception 'Offre indisponible ou non publiée'; end if;
 return new;
end $$;

-- Explicit least privilege, including Supabase's inherited TRUNCATE grants.
do $$ declare t text; begin
 foreach t in array array['attribut_valeurs','categorie_exigences','observations_attributs','valeurs_catalogue',
  'compatibilites_produits','regles_categories_fournisseurs','alias_attributs'] loop
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select,insert,update,delete on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
  if t in ('attribut_valeurs','categorie_exigences') then
   execute format('grant select on public.%I to anon',t);
   execute format('create policy lecture on public.%I for select to anon,authenticated using(true)',t);
  elsif t='valeurs_catalogue' then
   execute format('grant select on public.%I to anon',t);
   execute format('create policy lecture on public.%I for select to anon,authenticated using((statut=''valide'' and exists(select 1 from public.produits p where p.id=produit_id and p.statut_qualification=''publie'')) or (select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  elsif t='compatibilites_produits' then
   execute format('grant select on public.%I to anon',t);
   execute format('create policy lecture on public.%I for select to anon,authenticated using((statut=''valide'' and exists(select 1 from public.produits p where p.id=produit_id and p.statut_qualification=''publie'') and (cible_produit_id is null or exists(select 1 from public.produits p where p.id=cible_produit_id and p.statut_qualification=''publie''))) or (select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  else
   execute format('create policy lecture on public.%I for select to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  end if;
  execute format('create policy creation_admin on public.%I for insert to authenticated with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy modification_admin on public.%I for update to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'') with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy suppression_admin on public.%I for delete to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
 end loop;
end $$;
revoke all on sequence public.observations_attributs_id_seq,public.compatibilites_produits_id_seq,public.regles_categories_fournisseurs_id_seq from public,anon,authenticated;
grant usage,select on sequence public.observations_attributs_id_seq,public.compatibilites_produits_id_seq,public.regles_categories_fournisseurs_id_seq to authenticated,service_role;
revoke all on function public.verrou_catalogue_metier(),public.valeur_metier_valide(text,jsonb,text,jsonb),public.controler_observation(),
 public.controler_valeur_catalogue(),public.intervalle_catalogue_contient(jsonb,numeric),public.diagnostic_publication(bigint),
 public.controler_publication_metier(),public.invalider_qualification(),public.proteger_referentiel_publie(),public.publier_produit_catalogue(bigint),public.controler_compatibilite()
 from public,anon,authenticated;
grant execute on function public.valeur_metier_valide(text,jsonb,text,jsonb),public.diagnostic_publication(bigint),public.publier_produit_catalogue(bigint) to authenticated,service_role;
grant execute on function public.intervalle_catalogue_contient(jsonb,numeric) to anon,authenticated,service_role;

-- Navigation exposes only branches with published products; respects caller RLS.
create view public.categories_catalogue with (security_invoker=true) as
 with recursive branches as (
  select c.id,c.parent_id from public.categories c where c.actif and exists(
   select 1 from public.produits p where p.categorie_id=c.id and p.catalogue_verifie and p.statut_qualification='publie')
  union select c.id,c.parent_id from public.categories c join branches b on b.parent_id=c.id where c.actif
 ) select c.* from public.categories c where c.id in(select id from branches);
revoke all on public.categories_catalogue from public,anon,authenticated;
grant select on public.categories_catalogue to anon,authenticated,service_role;

do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='public' loop
  execute format('revoke truncate,references,trigger on public.%I from public,anon,authenticated',t.tablename);
 end loop;
end $$;

-- Generated from catalog/model/referentiel_v1.json.
do $seed$
declare data jsonb := $vocabulary${"version":"1.0.0","roots":{"appareillage":"Appareillage mural et boîtes","protection":"Protections et distribution modulaire","raccordement":"Connexion et raccordement"},"attributes":[{"code":"couleur","label":"Couleur","format":"choice","unit":"","integer":false,"values":["blanc","noir","gris","anthracite","beige","transparent","incolore","rouge","bleu","vert","jaune","orange","marron"],"context":{}},{"code":"couleur_secondaire","label":"Couleur secondaire","format":"choice","unit":"","integer":false,"values":["blanc","noir","gris","anthracite","transparent","rouge","bleu","vert","jaune","orange"],"context":{}},{"code":"finition","label":"Finition","format":"choice","unit":"","integer":false,"values":["mat","brillant","satine"],"context":{}},{"code":"materiau","label":"Matériau","format":"choice","unit":"","integer":false,"values":["plastique","metal","bois","verre","ceramique"],"context":{}},{"code":"pose","label":"Mode de pose","format":"set","unit":"","integer":false,"values":["encastre","saillie","rail_din","support_modulaire","montage_direct"],"context":{}},{"code":"fixation","label":"Fixation","format":"set","unit":"","integer":false,"values":["vis","griffes","clips"],"context":{}},{"code":"composition","label":"Composition","format":"choice","unit":"","integer":false,"values":["mecanisme_seul","mecanisme_enjoliveur","ensemble_complet","finition_seule","support_seul","boitier_seul"],"context":{}},{"code":"type_tension","label":"Type de tension","format":"choice","unit":"","integer":false,"values":["AC","DC","AC_DC"],"context":{}},{"code":"connexion","label":"Raccordement","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"standard_prise","label":"Standard de prise","format":"choice","unit":"","integer":false,"values":["franco_belge","schuko","universel"],"context":{}},{"code":"configuration_contacts","label":"Configuration des contacts","format":"choice","unit":"","integer":false,"values":["2P","2P_T"],"context":{}},{"code":"fonction_commande","label":"Fonction de commande","format":"choice","unit":"","integer":false,"values":["simple_allumage","va_et_vient","permutateur","double_allumage","double_va_et_vient"],"context":{}},{"code":"fonction_voyant","label":"Fonction du voyant","format":"choice","unit":"","integer":false,"values":["reperage","temoin"],"context":{}},{"code":"orientation","label":"Orientation","format":"set","unit":"","integer":false,"values":["horizontal","vertical"],"context":{}},{"code":"parois_admises","label":"Parois admises","format":"set","unit":"","integer":false,"values":["cloison_creuse","maconnerie","beton"],"context":{}},{"code":"forme","label":"Forme","format":"choice","unit":"","integer":false,"values":["ronde","carree","rectangulaire","ovale"],"context":{}},{"code":"configuration_poles","label":"Configuration des pôles","format":"choice","unit":"","integer":false,"values":["1P","1P_N","2P","3P","3P_N","4P"],"context":{}},{"code":"courbe","label":"Courbe","format":"choice","unit":"","integer":false,"values":["B","C","D","K","Z"],"context":{}},{"code":"type_differentiel","label":"Type différentiel","format":"choice","unit":"","integer":false,"values":["AC","A","F","B"],"context":{}},{"code":"actionnement","label":"Actionnement","format":"choice","unit":"","integer":false,"values":["levier","insertion_directe","vis"],"context":{}},{"code":"types_conducteurs","label":"Conducteurs admis","format":"set","unit":"","integer":false,"values":["massif","multifilaire_rigide","souple"],"context":{}},{"code":"fonction_borne","label":"Fonction de borne","format":"choice","unit":"","integer":false,"values":["passage","neutre","PE"],"context":{}},{"code":"rail_compatible","label":"Rail compatible","format":"choice","unit":"","integer":false,"values":["DIN_35","DIN_15","DIN_32"],"context":{}},{"code":"type_accessoire","label":"Type d’accessoire","format":"choice","unit":"","integer":false,"values":["support","pontage","plaque_extremite","reperage"],"context":{}},{"code":"nature_capacite_peigne","label":"Nature de capacité du peigne","format":"choice","unit":"","integer":false,"values":["voies","appareils","modules"],"context":{}},{"code":"connexion_amont","label":"Connexion amont","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"connexion_aval","label":"Connexion aval","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"connexion_cote_1","label":"Connexion cote 1","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"connexion_cote_2","label":"Connexion cote 2","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"ip","label":"Indice IP","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"ik","label":"Indice IK","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"marquage_calibre","label":"Marquage du calibre","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"fonction_associee","label":"Fonction associée","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"format_appareillage","label":"Format de l’appareillage","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"geometrie_montage","label":"Géométrie de montage","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"systeme_modulaire","label":"Système modulaire","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"taille_accessoire","label":"Taille ou capacité de l’accessoire","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"plaque_fournie","label":"Plaque fournie","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"support_fourni","label":"Support fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"enjoliveur_fourni","label":"Enjoliveur fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"boitier_fourni","label":"Boitier fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"eclairable","label":"Eclairable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"source_lumineuse_fournie","label":"Source lumineuse fournie","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"etanche_air","label":"Etanche air","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"serre_cable","label":"Serre cable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"neutre_sectionne","label":"Neutre sectionne","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"selectif","label":"Selectif","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"retard_courte_duree","label":"Retard courte duree","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"porte_fournie","label":"Porte fournie","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"bornier_terre_fourni","label":"Bornier terre fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"bornier_neutre_fourni","label":"Bornier neutre fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"decoupable","label":"Decoupable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"sans_halogene","label":"Sans halogene","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"volet","label":"Volet","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"separable","label":"Separable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"plaque_extremite_requise","label":"Plaque extremite requise","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"nombre_prises","label":"Nombre prises","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"nombre_commandes","label":"Nombre commandes","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"contacts_no","label":"Contacts no","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"contacts_nc","label":"Contacts nc","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"contacts_inverseurs","label":"Contacts inverseurs","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"postes","label":"Postes","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"poles","label":"Poles","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"poles_proteges","label":"Poles proteges","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"rangees","label":"Rangees","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"modules_par_rangee","label":"Modules par rangee","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"modules_total","label":"Modules total","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"points_connexion","label":"Points connexion","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"potentiels_independants","label":"Potentiels independants","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"etages","label":"Etages","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"points_par_etage","label":"Points par etage","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"points_par_circuit","label":"Points par circuit","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"courant","label":"Courant nominal","format":"number","unit":"A","integer":false,"values":[],"context":{}},{"code":"tension","label":"Tension assignée","format":"number","unit":"V","integer":false,"values":[],"context":{}},{"code":"sensibilite","label":"Sensibilité différentielle","format":"number","unit":"mA","integer":false,"values":[],"context":{}},{"code":"modules_din","label":"Largeur DIN","format":"number","unit":"","integer":false,"values":[],"context":{}},{"code":"modules_appareillage","label":"Modules d’appareillage","format":"number","unit":"","integer":false,"values":[],"context":{}},{"code":"capacite_peigne","label":"Capacité du peigne","format":"number","unit":"","integer":false,"values":[],"context":{}},{"code":"entraxe","label":"Entraxe","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"profondeur_utile","label":"Profondeur utile","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"diametre_percage","label":"Diamètre de perçage","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"largeur","label":"Largeur","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"hauteur","label":"Hauteur","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"profondeur","label":"Profondeur","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"pas_peigne","label":"Pas du peigne","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"longueur_peigne","label":"Longueur du peigne","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"longueur_denudage","label":"Longueur de dénudage","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"section_rigide","label":"Section rigide","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_multifilaire","label":"Section multifilaire","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_souple","label":"Section souple","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_souple_sans_embout","label":"Section souple sans embout","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_souple_avec_embout","label":"Section souple avec embout","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"diametre_cable","label":"Diamètre du câble","format":"range","unit":"mm","integer":false,"values":[],"context":{}},{"code":"icn_230","label":"ICN 230 V — EN 60898","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 60898","tension_v":230}},{"code":"icn_400","label":"ICN 400 V — EN 60898","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 60898","tension_v":400}},{"code":"icn_61009_230","label":"ICN_61009 230 V — EN 61009","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 61009","tension_v":230}},{"code":"icn_61009_400","label":"ICN_61009 400 V — EN 61009","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 61009","tension_v":400}},{"code":"icu_230","label":"ICU 230 V — IEC/EN 60947-2","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"IEC/EN 60947-2","tension_v":230}},{"code":"icu_400","label":"ICU 400 V — IEC/EN 60947-2","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"IEC/EN 60947-2","tension_v":400}}],"families":[{"code":"prises","label":"Prises de courant","parent":"appareillage","essential":["composition","standard_prise","configuration_contacts","courant","couleur","pose"],"optional":["fixation","connexion","tension","ip","ik","finition","materiau","largeur","hauteur","profondeur","sans_halogene","nombre_prises","volet","modules_appareillage","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme"]},{"code":"interrupteurs","label":"Interrupteurs et va-et-vient","parent":"appareillage","essential":["fonction_commande","nombre_commandes","composition","courant","marquage_calibre","couleur"],"optional":["fixation","connexion","tension","ip","ik","finition","materiau","largeur","hauteur","profondeur","sans_halogene","pose","eclairable","source_lumineuse_fournie","fonction_voyant","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme"]},{"code":"poussoirs","label":"Boutons-poussoirs","parent":"appareillage","essential":["contacts_no","contacts_nc","contacts_inverseurs","nombre_commandes","composition","courant","couleur"],"optional":["fixation","connexion","tension","ip","ik","finition","materiau","largeur","hauteur","profondeur","sans_halogene","pose","eclairable","source_lumineuse_fournie","fonction_voyant","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme"]},{"code":"plaques","label":"Plaques de finition","parent":"appareillage","essential":["postes","orientation","couleur"],"optional":["entraxe","finition","materiau","largeur","hauteur","profondeur","modules_appareillage","ip"],"special":["compatibilite","entraxe_multiposte"]},{"code":"enjoliveurs","label":"Enjoliveurs et touches","parent":"appareillage","essential":["fonction_associee","format_appareillage","couleur"],"optional":["finition","materiau","largeur","hauteur","profondeur","nombre_commandes","modules_appareillage"],"special":["compatibilite"]},{"code":"supports","label":"Supports de fixation","parent":"appareillage","essential":["postes","modules_appareillage","fixation"],"optional":["entraxe","orientation","materiau","largeur","hauteur","profondeur"],"special":["compatibilite","entraxe_multiposte"]},{"code":"boites","label":"Boîtes d’encastrement","parent":"appareillage","essential":["parois_admises","postes","profondeur_utile","geometrie_montage"],"optional":["diametre_percage","entraxe","etanche_air","fixation","largeur","hauteur","profondeur","ip","forme"],"special":[]},{"code":"boitiers-saillie","label":"Boîtiers et cadres en saillie","parent":"appareillage","essential":["postes","modules_appareillage","profondeur_utile"],"optional":["orientation","couleur","largeur","hauteur","profondeur","ip"],"special":["compatibilite"]},{"code":"boites-derivation","label":"Boîtes de dérivation","parent":"appareillage","essential":["pose","forme","largeur","hauteur","profondeur","ip"],"optional":["materiau","fixation","ik","couleur"],"special":[]},{"code":"sorties-cable","label":"Sorties de câble","parent":"appareillage","essential":["composition","serre_cable","couleur"],"optional":["diametre_cable","courant","connexion","pose","fixation","ip","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme_ou_compatibilite"]},{"code":"disjoncteurs","label":"Disjoncteurs modulaires","parent":"protection","essential":["courant","configuration_poles","courbe","tension","type_tension","modules_din"],"optional":["connexion_amont","connexion_aval","poles_proteges","neutre_sectionne","profondeur","icn_230","icn_400","icu_230","icu_400"],"special":["coupure"]},{"code":"differentiels","label":"Interrupteurs différentiels","parent":"protection","essential":["courant","sensibilite","type_differentiel","poles","tension","type_tension","modules_din"],"optional":["connexion_amont","connexion_aval","selectif","retard_courte_duree","profondeur"],"special":[]},{"code":"disjoncteurs-differentiels","label":"Disjoncteurs différentiels","parent":"protection","essential":["courant","sensibilite","type_differentiel","configuration_poles","courbe","tension","type_tension","modules_din"],"optional":["connexion_amont","connexion_aval","poles_proteges","neutre_sectionne","profondeur","icn_230","icn_400","icn_61009_230","icn_61009_400","icu_230","icu_400","selectif","retard_courte_duree"],"special":["coupure"]},{"code":"coffrets","label":"Coffrets modulaires à équiper","parent":"protection","essential":["rangees","modules_par_rangee","modules_total","pose","largeur","hauteur","profondeur","ip"],"optional":["porte_fournie","bornier_terre_fourni","bornier_neutre_fourni","materiau","ik","couleur"],"special":[]},{"code":"peignes","label":"Peignes d’alimentation","parent":"protection","essential":["configuration_poles","connexion","pas_peigne","longueur_peigne","capacite_peigne","nature_capacite_peigne","courant"],"optional":["decoupable","tension"],"special":["compatibilite"]},{"code":"bornes","label":"Bornes de connexion rapide","parent":"raccordement","essential":["actionnement","points_connexion","potentiels_independants","types_conducteurs"],"optional":["section_rigide","section_multifilaire","section_souple","section_souple_sans_embout","section_souple_avec_embout","courant","tension","longueur_denudage","largeur","hauteur","profondeur","couleur","couleur_secondaire"],"special":["sections"]},{"code":"barrettes-vis","label":"Barrettes de raccordement à vis","parent":"raccordement","essential":["potentiels_independants","points_par_circuit","connexion_cote_1","connexion_cote_2","types_conducteurs"],"optional":["section_rigide","section_multifilaire","section_souple","section_souple_sans_embout","section_souple_avec_embout","courant","tension","separable","materiau","largeur","hauteur","profondeur","entraxe"],"special":["sections"]},{"code":"bornes-rail","label":"Bornes pour rail DIN","parent":"raccordement","essential":["fonction_borne","rail_compatible","etages","potentiels_independants","points_par_etage","connexion_cote_1","connexion_cote_2","types_conducteurs"],"optional":["section_rigide","section_multifilaire","section_souple","section_souple_sans_embout","section_souple_avec_embout","courant","tension","couleur","largeur","hauteur","profondeur","plaque_extremite_requise"],"special":["sections"]},{"code":"accessoires-bornes","label":"Accessoires de bornes","parent":"raccordement","essential":["type_accessoire","taille_accessoire"],"optional":["points_connexion","fixation","couleur","largeur","hauteur","profondeur"],"special":["compatibilite"]}]}$vocabulary$; r record; f jsonb; a jsonb; v text; cid bigint; i integer; k text;
begin
 update public.categories set actif=false where actif;
 update public.attributs set actif=false where actif;
 update public.categorie_attributs set filtrable=false where filtrable;
 for r in select * from jsonb_each_text(data->'roots') loop
  insert into public.categories(code,nom,ordre,actif) values(r.key,r.value,0,true)
   on conflict(code) do update set nom=excluded.nom,actif=true;
 end loop;
 for a in select value from jsonb_array_elements(data->'attributes') loop
  insert into public.attributs(code,nom,type,unite,ordre,format_valeur,entier,contexte_requis,actif)
   values(a->>'code',a->>'label',case when a->>'format' in ('number','range') then 'number' when a->>'format'='boolean' then 'boolean' else 'text' end,
   a->>'unit',0,a->>'format',(a->>'integer')::boolean,a->'context',true)
   on conflict(code) do update set nom=excluded.nom,format_valeur=excluded.format_valeur,entier=excluded.entier,contexte_requis=excluded.contexte_requis,actif=true;
  for v in select jsonb_array_elements_text(a->'values') loop
   insert into public.attribut_valeurs(attribut_code,code,libelle) values(a->>'code',v,replace(v,'_',' ')) on conflict do nothing;
  end loop;
 end loop;
 i:=0;
 for f in select value from jsonb_array_elements(data->'families') loop
  insert into public.categories(code,nom,parent_id,ordre,actif)
   select f->>'code',f->>'label',id,i,true from public.categories where code=f->>'parent'
   on conflict(code) do update set nom=excluded.nom,parent_id=excluded.parent_id,ordre=excluded.ordre,actif=true returning id into cid;
  i:=i+10;
  for r in select value,ordinality from jsonb_array_elements_text((f->'essential')||(f->'optional')) with ordinality loop
   insert into public.categorie_attributs(categorie_id,attribut_code,filtrable,ordre,essentiel,actif)
    values(cid,r.value,true,r.ordinality::int*10,(f->'essential') ? r.value,true)
    on conflict(categorie_id,attribut_code) do update set filtrable=true,ordre=excluded.ordre,essentiel=excluded.essentiel,actif=true;
  end loop;
  for k in select jsonb_array_elements_text(f->'special') loop
   insert into public.categorie_exigences(categorie_id,code) values(cid,k);
  end loop;
 end loop;
end $seed$;

create or replace function public.rechercher_catalogue_v2(terme text default '', filtres jsonb default '{}', page_num integer default 0)
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
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'code',code,'nom',nom,'parent_id',parent_id,'ordre',ordre) order by ordre,nom) from public.categories_catalogue where actif),'[]')
 ) into resultat;
 return resultat;
end $$;

insert into supabase_migrations.schema_migrations(version,name,statements) values('20261029161909','catalogue_modele_metier_v1',array[$migration_20261029161909$-- Catalogue métier v1. Additive: no product, account or cart deletion.
alter table public.attributs add column format_valeur text not null default 'text'
 check(format_valeur in ('text','number','boolean','choice','set','range')),
 add column entier boolean not null default false,
 add column contexte_requis jsonb not null default '{}' check(jsonb_typeof(contexte_requis)='object'),
 add column actif boolean not null default false;
alter table public.categorie_attributs add column essentiel boolean not null default false,
 add column actif boolean not null default false;
alter table public.produits add column statut_qualification text not null default 'collecte'
 check(statut_qualification in ('collecte','a_revoir','publie')),
 add column qualification_le timestamptz;
create index produits_publication on public.produits(categorie_id,id)
 where catalogue_verifie and statut_qualification='publie';

create table public.attribut_valeurs(
 attribut_code text not null references public.attributs(code),
 code text not null check(length(code) between 1 and 100),
 libelle text not null check(length(btrim(libelle)) between 1 and 200),
 primary key(attribut_code,code)
);
alter table public.attribut_valeurs enable row level security;
create table public.categorie_exigences(
 categorie_id bigint not null references public.categories(id),
 code text not null check(code in ('gamme','compatibilite','gamme_ou_compatibilite','entraxe_multiposte','coupure','sections')),
 primary key(categorie_id,code)
);
alter table public.categorie_exigences enable row level security;
create table public.observations_attributs(
 id bigint generated by default as identity primary key,
 produit_id bigint not null references public.produits(id),
 attribut_code text not null references public.attributs(code),
 valeur jsonb, unite text not null default '',
 contexte jsonb not null default '{}' check(jsonb_typeof(contexte)='object' and octet_length(contexte::text)<=2000),
 libelle_source text not null check(length(btrim(libelle_source)) between 1 and 200),
 valeur_source text not null check(length(btrim(valeur_source)) between 1 and 4000),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/' and length(source_url)<=2000),
 observe_le timestamptz not null, regle_version text not null check(length(btrim(regle_version)) between 1 and 100),
 statut text not null default 'observee' check(statut in ('observee','validee','conflit','rejetee')),
 motif_revue text check(length(motif_revue)<=2000),
 cree_le timestamptz not null default now(),
 unique(id,produit_id,attribut_code),
 check(octet_length(coalesce(valeur::text,''))<=8000),
 check(statut not in ('conflit','rejetee') or (motif_revue is not null and length(btrim(motif_revue))>0))
);
alter table public.observations_attributs enable row level security;
create index observations_produit_attribut on public.observations_attributs(produit_id,attribut_code);
create index observations_attribut on public.observations_attributs(attribut_code);
create table public.valeurs_catalogue(
 produit_id bigint not null references public.produits(id),
 attribut_code text not null references public.attributs(code),
 contexte jsonb not null default '{}' check(jsonb_typeof(contexte)='object' and octet_length(contexte::text)<=2000),
 valeur jsonb, observation_id bigint,
 statut text not null default 'valide' check(statut in ('valide','non_applicable')),
 motif text, source_exception text,
 valide_le timestamptz not null default now(),
 primary key(produit_id,attribut_code,contexte),
 foreign key(observation_id,produit_id,attribut_code) references public.observations_attributs(id,produit_id,attribut_code),
 check((statut='valide' and observation_id is not null and valeur is not null and valeur<>'null'::jsonb and motif is null and source_exception is null)
   or (statut='non_applicable' and observation_id is null and valeur is null
    and motif is not null and source_exception is not null and length(btrim(motif)) between 10 and 2000 and source_exception ~ '^https://[^/@?#[:space:]]+/'))
);
alter table public.valeurs_catalogue enable row level security;
create index valeurs_observation on public.valeurs_catalogue(observation_id,produit_id,attribut_code);
create index valeurs_attribut on public.valeurs_catalogue(attribut_code);
create index valeurs_json on public.valeurs_catalogue using gin(valeur jsonb_path_ops) where statut='valide';
create table public.compatibilites_produits(
 id bigint generated by default as identity primary key,
 produit_id bigint not null references public.produits(id),
 cible_produit_id bigint references public.produits(id),
 systeme text, version_systeme text,
 role_relation text not null check(role_relation in ('accessoire_pour','compatible_avec')),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/' and length(source_url)<=2000),
 observe_le timestamptz not null,
 statut text not null default 'a_revoir' check(statut in ('a_revoir','valide','rejete')),
 preuve text not null check(length(btrim(preuve)) between 10 and 4000),
 check(cible_produit_id is distinct from produit_id),
 check((cible_produit_id is not null and systeme is null and version_systeme is null)
    or (cible_produit_id is null and systeme is not null and version_systeme is not null
        and length(btrim(systeme)) between 1 and 200 and length(btrim(version_systeme)) between 1 and 100))
);
alter table public.compatibilites_produits enable row level security;
create index compatibilites_produit on public.compatibilites_produits(produit_id);
create index compatibilites_cible on public.compatibilites_produits(cible_produit_id);
create unique index compatibilites_uniques on public.compatibilites_produits(produit_id,cible_produit_id,systeme,version_systeme,role_relation) nulls not distinct;
create table public.regles_categories_fournisseurs(
 id bigint generated by default as identity primary key,
 fournisseur_id bigint not null, code_source text not null,
 categorie_id bigint not null references public.categories(id),
 conditions jsonb not null check(jsonb_typeof(conditions)='object' and octet_length(conditions::text)<=8000),
 version text not null check(length(btrim(version)) between 1 and 100),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/'),
 preuve text not null check(length(btrim(preuve)) between 10 and 4000),
 valide_le timestamptz, actif boolean not null default false,
 foreign key(fournisseur_id,code_source) references public.categories_fournisseurs(fournisseur_id,code),
 check(not actif or valide_le is not null),
 unique(fournisseur_id,code_source,categorie_id,version)
);
alter table public.regles_categories_fournisseurs enable row level security;
create index regles_categorie on public.regles_categories_fournisseurs(categorie_id);
create table public.alias_attributs(
 fournisseur_id bigint not null references public.fournisseurs(id),
 categorie_id bigint not null references public.categories(id),
 libelle_source text not null check(length(btrim(libelle_source)) between 1 and 200),
 attribut_code text not null references public.attributs(code),
 contexte jsonb not null default '{}' check(jsonb_typeof(contexte)='object'),
 regle_version text not null check(length(btrim(regle_version)) between 1 and 100),
 source_url text not null check(source_url ~ '^https://[^/@?#[:space:]]+/'),
 valide_le timestamptz,
 primary key(fournisseur_id,categorie_id,libelle_source,regle_version)
);
alter table public.alias_attributs enable row level security;
create index alias_categorie on public.alias_attributs(categorie_id);
create index alias_attribut on public.alias_attributs(attribut_code);

create function public.controler_compatibilite() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.observe_le>now()+interval '5 minutes' then raise exception 'Compatibilité dans le futur'; end if;
 return new;
end $$;
create trigger compatibilite_controle before insert or update on public.compatibilites_produits for each row execute function public.controler_compatibilite();

-- Every business write is serialized with the import lock, including publication.
create function public.verrou_catalogue_metier() returns trigger language plpgsql security invoker set search_path='' as $$
begin perform pg_advisory_xact_lock(2042,1); return null; end $$;
do $$ declare t text; begin
 foreach t in array array['produits','produits_fournisseurs','attributs','attribut_valeurs','categories','categorie_attributs',
  'categorie_exigences','observations_attributs','valeurs_catalogue','compatibilites_produits','produit_attributs'] loop
  execute format('create trigger a_verrou_metier before insert or update or delete on public.%I for each statement execute function public.verrou_catalogue_metier()',t);
 end loop;
end $$;

create function public.valeur_metier_valide(code_attribut text,v jsonb,u text,ctx jsonb)
returns boolean language plpgsql stable security invoker set search_path='' as $$
declare a public.attributs%rowtype; x jsonb; n numeric;
begin
 select * into a from public.attributs where code=code_attribut and actif;
 if not found or v is null or v='null'::jsonb or u is distinct from a.unite
  or jsonb_typeof(ctx) is distinct from 'object' or not(ctx @> a.contexte_requis) then return false; end if;
 if a.format_valeur='number' then
  if jsonb_typeof(v)<>'number' then return false; end if;
  n:=(v#>>'{}')::numeric; return n between 0 and 1000000000 and (not a.entier or n=trunc(n));
 elsif a.format_valeur='boolean' then return jsonb_typeof(v)='boolean';
 elsif a.format_valeur='text' then
  if jsonb_typeof(v)<>'string' or length(btrim(v#>>'{}')) not between 1 and 1000 then return false; end if;
  if a.code='ip' then return coalesce((v#>>'{}') ~ '^IP[0-6X][0-9X][A-D]?[HMSW]?$' and jsonb_typeof(ctx->'assemblage')='string' and length(btrim(ctx->>'assemblage'))>0,false); end if;
  if a.code='ik' then return (v#>>'{}') ~ '^IK(0[0-9]|10|11)$'; end if;
  return true;
 elsif a.format_valeur='choice' then
  return jsonb_typeof(v)='string' and exists(select 1 from public.attribut_valeurs where attribut_code=a.code and code=v#>>'{}');
 elsif a.format_valeur='set' then
  if jsonb_typeof(v)<>'array' then return false; end if;
  if jsonb_array_length(v) not between 1 and 30 then return false; end if;
  if (select count(*)<>count(distinct value) from jsonb_array_elements(v)) then return false; end if;
  for x in select value from jsonb_array_elements(v) loop
   if jsonb_typeof(x)<>'string' or not exists(select 1 from public.attribut_valeurs where attribut_code=a.code and code=x#>>'{}') then return false; end if;
  end loop; return true;
 elsif a.format_valeur='range' then
  if jsonb_typeof(v)<>'object' then return false; end if;
  if not(v ?& array['min','max']) or exists(select 1 from jsonb_object_keys(v) k where k not in ('min','max'))
   or jsonb_typeof(v->'min') is distinct from 'number' or jsonb_typeof(v->'max') is distinct from 'number'
  then return false; end if;
  return (v->>'min')::numeric>=0 and (v->>'max')::numeric<1000000000 and (v->>'min')::numeric<=(v->>'max')::numeric;
 end if; return false;
exception when invalid_text_representation then return false;
end $$;

create function public.controler_observation() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_op<>'INSERT' and exists(select 1 from public.valeurs_catalogue where observation_id=old.id) then
  raise exception 'Observation retenue immuable : retirer la sélection avant de la réviser'; end if;
 if tg_op='DELETE' then return old; end if;
 if new.observe_le>now()+interval '5 minutes' then raise exception 'Observation dans le futur'; end if;
 if new.statut='validee' and public.valeur_metier_valide(new.attribut_code,new.valeur,new.unite,new.contexte) is not true
 then raise exception 'Valeur, unité, vocabulaire ou contexte invalide'; end if;
 if new.statut in ('conflit','rejetee') and nullif(btrim(new.motif_revue),'') is null then raise exception 'Motif de revue requis'; end if;
 return new;
end $$;
create trigger observation_controle before insert or update or delete on public.observations_attributs for each row execute function public.controler_observation();
create function public.controler_valeur_catalogue() returns trigger language plpgsql security invoker set search_path='' as $$
declare o public.observations_attributs%rowtype;
begin
 if not exists(select 1 from public.produits p join public.categorie_attributs ca on ca.categorie_id=p.categorie_id
  where p.id=new.produit_id and ca.attribut_code=new.attribut_code and ca.actif)
 then raise exception 'Attribut non applicable à cette famille'; end if;
 if new.valide_le>now()+interval '5 minutes' then raise exception 'Validation dans le futur'; end if;
 if new.statut='valide' then
  select * into o from public.observations_attributs where id=new.observation_id and produit_id=new.produit_id and attribut_code=new.attribut_code;
  if not found or o.statut<>'validee' or o.valeur is distinct from new.valeur or o.contexte is distinct from new.contexte
   or public.valeur_metier_valide(new.attribut_code,new.valeur,o.unite,new.contexte) is not true
  then raise exception 'Valeur sans observation validée correspondante'; end if;
 elsif new.valeur is not null or new.observation_id is not null or new.motif is null or length(btrim(new.motif))<10
   or new.source_exception is null or new.source_exception !~ '^https://[^/@?#[:space:]]+/'
 then raise exception 'Non applicable : motif et source requis'; end if;
 return new;
end $$;
create trigger valeur_catalogue_controle before insert or update on public.valeurs_catalogue for each row execute function public.controler_valeur_catalogue();

-- Useful to the later search API: a value must be INSIDE a documented interval.
create function public.intervalle_catalogue_contient(plage jsonb,n numeric) returns boolean
language sql immutable security invoker set search_path='' as $$
 select coalesce(jsonb_typeof(plage)='object' and jsonb_typeof(plage->'min')='number' and jsonb_typeof(plage->'max')='number'
 and n between (plage->>'min')::numeric and (plage->>'max')::numeric,false);
$$;

create function public.diagnostic_publication(pid bigint) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare p public.produits%rowtype; erreurs text[]:='{}'; r record; type_cond text; cle text;
begin
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Diagnostic réservé à un administrateur' using errcode='42501'; end if;
 select * into p from public.produits where id=pid;
 if not found then raise exception 'Produit inconnu'; end if;
 if not p.catalogue_verifie or p.code_ean is null or not public.gtin_valide(p.code_ean)
  or p.source_catalogue is null or p.catalogue_verifie_le is null or nullif(btrim(p.marque),'') is null
 then erreurs:=array_append(erreurs,'identite_non_verifiee'); end if;
 if not exists(select 1 from public.categories c where c.id=p.categorie_id and c.actif and
   not exists(select 1 from public.categories e where e.parent_id=c.id))
  or exists(with recursive arbre as(select id,parent_id,actif from public.categories where id=p.categorie_id
   union all select c.id,c.parent_id,c.actif from public.categories c join arbre a on c.id=a.parent_id)
   select 1 from arbre where not actif)
 then erreurs:=array_append(erreurs,'categorie_finale_inactive_ou_absente'); end if;
 if not exists(select 1 from public.produits_fournisseurs where produit_id=pid and reference_verifiee)
 then erreurs:=array_append(erreurs,'offre_verifiee_absente'); end if;
 for r in select ca.attribut_code from public.categorie_attributs ca where ca.categorie_id=p.categorie_id and ca.essentiel and ca.actif loop
  if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code=r.attribut_code)
  then erreurs:=array_append(erreurs,'manquant:'||r.attribut_code); end if;
 end loop;
 if exists(select 1 from public.valeurs_catalogue v where v.produit_id=pid and not exists(
   select 1 from public.categorie_attributs ca where ca.categorie_id=p.categorie_id and ca.attribut_code=v.attribut_code and ca.actif))
 then erreurs:=array_append(erreurs,'attribut_incompatible'); end if;
 -- Recheck retained values against the current dictionary, even when they were
 -- selected before an administrative vocabulary change.
 if exists(select 1 from public.valeurs_catalogue v left join public.observations_attributs o on o.id=v.observation_id
  where v.produit_id=pid and v.statut='valide' and (o.statut is distinct from 'validee'
   or o.produit_id is distinct from v.produit_id or o.attribut_code is distinct from v.attribut_code
   or o.valeur is distinct from v.valeur or o.contexte is distinct from v.contexte
   or public.valeur_metier_valide(v.attribut_code,v.valeur,o.unite,v.contexte) is not true))
 then erreurs:=array_append(erreurs,'valeur_retenue_invalide'); end if;
 -- An observation explicitly in conflict, or disagreeing candidates in the SAME
 -- context, cannot silently be suppressed by selecting one candidate.
 if exists(select 1 from public.observations_attributs where produit_id=pid and statut='conflit')
 or exists(select 1 from public.observations_attributs o join public.attributs a on a.code=o.attribut_code
  where o.produit_id=pid and o.statut in ('observee','validee') and o.valeur is not null
  group by o.attribut_code,o.contexte having count(distinct
   case when a.format_valeur='set' and jsonb_typeof(o.valeur)='array'
    then (select jsonb_agg(e.value order by e.value) from jsonb_array_elements(o.valeur) e)
    else o.valeur end)>1)
 then erreurs:=array_append(erreurs,'conflit_non_resolu'); end if;
 for r in select code from public.categorie_exigences where categorie_id=p.categorie_id loop
  if r.code='gamme' and p.gamme_id is null then erreurs:=array_append(erreurs,'gamme_absente');
  elsif r.code in ('compatibilite','gamme_ou_compatibilite') then
   if (r.code='compatibilite' or p.gamme_id is null) and not exists(select 1 from public.compatibilites_produits where produit_id=pid and statut='valide')
   then erreurs:=array_append(erreurs,'compatibilite_absente'); end if;
  elsif r.code='entraxe_multiposte' then
   if exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code='postes' and statut='valide' and (valeur#>>'{}')::numeric>1)
    and not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code='entraxe')
   then erreurs:=array_append(erreurs,'entraxe_absent'); end if;
  elsif r.code='coupure' then
   if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code in ('icn_230','icn_400','icn_61009_230','icn_61009_400','icu_230','icu_400') and statut='valide')
   then erreurs:=array_append(erreurs,'coupure_qualifiee_absente'); end if;
  elsif r.code='sections' then
   if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and attribut_code like 'section_%' and statut='valide')
   then erreurs:=array_append(erreurs,'plages_sections_absentes'); end if;
   for type_cond in select jsonb_array_elements_text(valeur) from public.valeurs_catalogue where produit_id=pid and attribut_code='types_conducteurs' and statut='valide' loop
    cle:=case type_cond when 'massif' then 'section_rigide' when 'multifilaire_rigide' then 'section_multifilaire' else 'section_souple' end;
    if not exists(select 1 from public.valeurs_catalogue where produit_id=pid and statut='valide' and
      (attribut_code=cle or (cle='section_souple' and attribut_code in ('section_souple_sans_embout','section_souple_avec_embout'))))
    then erreurs:=array_append(erreurs,'plage_manquante:'||type_cond); end if;
   end loop;
  end if;
 end loop;
 return jsonb_build_object('produit_id',pid,'publiable',cardinality(erreurs)=0,'erreurs',to_jsonb(erreurs));
end $$;

create function public.controler_publication_metier() returns trigger language plpgsql security invoker set search_path='' as $$
declare diagnostic jsonb;
begin
 if tg_op='INSERT' and new.statut_qualification='publie' then raise exception 'Créer la fiche puis qualifier avant publication'; end if;
 if tg_op='UPDATE' and new.statut_qualification='publie' and
  row(new.categorie_id,new.gamme_id,new.marque,new.ref_fabricant,new.code_ean,new.catalogue_verifie,new.source_catalogue)
  is distinct from row(old.categorie_id,old.gamme_id,old.marque,old.ref_fabricant,old.code_ean,old.catalogue_verifie,old.source_catalogue)
 then new.statut_qualification:='a_revoir'; new.qualification_le:=null; end if;
 if new.statut_qualification='publie' then
  diagnostic:=public.diagnostic_publication(new.id);
  if not (diagnostic->>'publiable')::boolean then raise exception 'Publication refusée : %',diagnostic->'erreurs'; end if;
  new.qualification_le:=now();
 else new.qualification_le:=null; end if;
 return new;
end $$;
create trigger z_publication_metier before insert or update on public.produits for each row execute function public.controler_publication_metier();
create function public.invalider_qualification() returns trigger language plpgsql security invoker set search_path='' as $$
declare ids bigint[];
begin
 ids:=case when tg_op='INSERT' then array[new.produit_id] when tg_op='DELETE' then array[old.produit_id] else array[old.produit_id,new.produit_id] end;
 update public.produits set statut_qualification='a_revoir',qualification_le=null where id=any(ids) and statut_qualification='publie';
 return null;
end $$;
do $$ declare t text; begin
 foreach t in array array['observations_attributs','valeurs_catalogue','compatibilites_produits','produits_fournisseurs','produit_attributs'] loop
  execute format('create trigger a_invalider_qualification after insert or update or delete on public.%I for each row execute function public.invalider_qualification()',t);
 end loop;
end $$;
-- Administrative dictionary changes require a deliberate unpublication first.
create function public.proteger_referentiel_publie() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.produits where statut_qualification='publie') then
  raise exception 'Dépublier les fiches avant de modifier le référentiel'; end if;
 return null;
end $$;
do $$ declare t text; begin
 foreach t in array array['attributs','attribut_valeurs','categorie_attributs','categorie_exigences','categories'] loop
  execute format('create trigger proteger_referentiel before insert or update or delete on public.%I for each statement execute function public.proteger_referentiel_publie()',t);
 end loop;
end $$;
create function public.publier_produit_catalogue(pid bigint) returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 perform pg_advisory_xact_lock(2042,1);
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Publication réservée à un administrateur' using errcode='42501'; end if;
 perform 1 from public.produits where id=pid for update;
 if not found then raise exception 'Produit inconnu'; end if;
 update public.produits set statut_qualification='publie' where id=pid;
 return public.diagnostic_publication(pid);
end $$;

-- Publication is enforced on every public read, including legacy RPCs.
drop policy produits_lecture on public.produits;
create policy produits_lecture on public.produits for select to anon,authenticated using(
 (catalogue_verifie and statut_qualification='publie') or (select auth.jwt())->'app_metadata'->>'role'='admin');
drop policy offres_lecture on public.produits_fournisseurs;
create policy offres_lecture on public.produits_fournisseurs for select to authenticated using(
 (select auth.uid()) is not null and not coalesce(((select auth.jwt())->>'is_anonymous')::boolean,false) and
 ((reference_verifiee and exists(select 1 from public.produits p where p.id=produit_id and p.statut_qualification='publie'))
 or (select auth.jwt())->'app_metadata'->>'role'='admin'));
create or replace function public.verifier_offre_panier() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if not exists(select 1 from public.produits_fournisseurs o join public.produits p on p.id=o.produit_id
  where o.id=new.offre_id and o.reference_verifiee and p.catalogue_verifie and p.statut_qualification='publie')
 then raise exception 'Offre indisponible ou non publiée'; end if;
 return new;
end $$;

-- Explicit least privilege, including Supabase's inherited TRUNCATE grants.
do $$ declare t text; begin
 foreach t in array array['attribut_valeurs','categorie_exigences','observations_attributs','valeurs_catalogue',
  'compatibilites_produits','regles_categories_fournisseurs','alias_attributs'] loop
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select,insert,update,delete on public.%I to authenticated',t);
  execute format('grant all on public.%I to service_role',t);
  if t in ('attribut_valeurs','categorie_exigences') then
   execute format('grant select on public.%I to anon',t);
   execute format('create policy lecture on public.%I for select to anon,authenticated using(true)',t);
  elsif t='valeurs_catalogue' then
   execute format('grant select on public.%I to anon',t);
   execute format('create policy lecture on public.%I for select to anon,authenticated using((statut=''valide'' and exists(select 1 from public.produits p where p.id=produit_id and p.statut_qualification=''publie'')) or (select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  elsif t='compatibilites_produits' then
   execute format('grant select on public.%I to anon',t);
   execute format('create policy lecture on public.%I for select to anon,authenticated using((statut=''valide'' and exists(select 1 from public.produits p where p.id=produit_id and p.statut_qualification=''publie'') and (cible_produit_id is null or exists(select 1 from public.produits p where p.id=cible_produit_id and p.statut_qualification=''publie''))) or (select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  else
   execute format('create policy lecture on public.%I for select to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  end if;
  execute format('create policy creation_admin on public.%I for insert to authenticated with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy modification_admin on public.%I for update to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'') with check((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
  execute format('create policy suppression_admin on public.%I for delete to authenticated using((select auth.jwt())->''app_metadata''->>''role''=''admin'')',t);
 end loop;
end $$;
revoke all on sequence public.observations_attributs_id_seq,public.compatibilites_produits_id_seq,public.regles_categories_fournisseurs_id_seq from public,anon,authenticated;
grant usage,select on sequence public.observations_attributs_id_seq,public.compatibilites_produits_id_seq,public.regles_categories_fournisseurs_id_seq to authenticated,service_role;
revoke all on function public.verrou_catalogue_metier(),public.valeur_metier_valide(text,jsonb,text,jsonb),public.controler_observation(),
 public.controler_valeur_catalogue(),public.intervalle_catalogue_contient(jsonb,numeric),public.diagnostic_publication(bigint),
 public.controler_publication_metier(),public.invalider_qualification(),public.proteger_referentiel_publie(),public.publier_produit_catalogue(bigint),public.controler_compatibilite()
 from public,anon,authenticated;
grant execute on function public.valeur_metier_valide(text,jsonb,text,jsonb),public.diagnostic_publication(bigint),public.publier_produit_catalogue(bigint) to authenticated,service_role;
grant execute on function public.intervalle_catalogue_contient(jsonb,numeric) to anon,authenticated,service_role;

-- Navigation exposes only branches with published products; respects caller RLS.
create view public.categories_catalogue with (security_invoker=true) as
 with recursive branches as (
  select c.id,c.parent_id from public.categories c where c.actif and exists(
   select 1 from public.produits p where p.categorie_id=c.id and p.catalogue_verifie and p.statut_qualification='publie')
  union select c.id,c.parent_id from public.categories c join branches b on b.parent_id=c.id where c.actif
 ) select c.* from public.categories c where c.id in(select id from branches);
revoke all on public.categories_catalogue from public,anon,authenticated;
grant select on public.categories_catalogue to anon,authenticated,service_role;

do $$ declare t record; begin
 for t in select tablename from pg_tables where schemaname='public' loop
  execute format('revoke truncate,references,trigger on public.%I from public,anon,authenticated',t.tablename);
 end loop;
end $$;

-- Generated from catalog/model/referentiel_v1.json.
do $seed$
declare data jsonb := $vocabulary${"version":"1.0.0","roots":{"appareillage":"Appareillage mural et boîtes","protection":"Protections et distribution modulaire","raccordement":"Connexion et raccordement"},"attributes":[{"code":"couleur","label":"Couleur","format":"choice","unit":"","integer":false,"values":["blanc","noir","gris","anthracite","beige","transparent","incolore","rouge","bleu","vert","jaune","orange","marron"],"context":{}},{"code":"couleur_secondaire","label":"Couleur secondaire","format":"choice","unit":"","integer":false,"values":["blanc","noir","gris","anthracite","transparent","rouge","bleu","vert","jaune","orange"],"context":{}},{"code":"finition","label":"Finition","format":"choice","unit":"","integer":false,"values":["mat","brillant","satine"],"context":{}},{"code":"materiau","label":"Matériau","format":"choice","unit":"","integer":false,"values":["plastique","metal","bois","verre","ceramique"],"context":{}},{"code":"pose","label":"Mode de pose","format":"set","unit":"","integer":false,"values":["encastre","saillie","rail_din","support_modulaire","montage_direct"],"context":{}},{"code":"fixation","label":"Fixation","format":"set","unit":"","integer":false,"values":["vis","griffes","clips"],"context":{}},{"code":"composition","label":"Composition","format":"choice","unit":"","integer":false,"values":["mecanisme_seul","mecanisme_enjoliveur","ensemble_complet","finition_seule","support_seul","boitier_seul"],"context":{}},{"code":"type_tension","label":"Type de tension","format":"choice","unit":"","integer":false,"values":["AC","DC","AC_DC"],"context":{}},{"code":"connexion","label":"Raccordement","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"standard_prise","label":"Standard de prise","format":"choice","unit":"","integer":false,"values":["franco_belge","schuko","universel"],"context":{}},{"code":"configuration_contacts","label":"Configuration des contacts","format":"choice","unit":"","integer":false,"values":["2P","2P_T"],"context":{}},{"code":"fonction_commande","label":"Fonction de commande","format":"choice","unit":"","integer":false,"values":["simple_allumage","va_et_vient","permutateur","double_allumage","double_va_et_vient"],"context":{}},{"code":"fonction_voyant","label":"Fonction du voyant","format":"choice","unit":"","integer":false,"values":["reperage","temoin"],"context":{}},{"code":"orientation","label":"Orientation","format":"set","unit":"","integer":false,"values":["horizontal","vertical"],"context":{}},{"code":"parois_admises","label":"Parois admises","format":"set","unit":"","integer":false,"values":["cloison_creuse","maconnerie","beton"],"context":{}},{"code":"forme","label":"Forme","format":"choice","unit":"","integer":false,"values":["ronde","carree","rectangulaire","ovale"],"context":{}},{"code":"configuration_poles","label":"Configuration des pôles","format":"choice","unit":"","integer":false,"values":["1P","1P_N","2P","3P","3P_N","4P"],"context":{}},{"code":"courbe","label":"Courbe","format":"choice","unit":"","integer":false,"values":["B","C","D","K","Z"],"context":{}},{"code":"type_differentiel","label":"Type différentiel","format":"choice","unit":"","integer":false,"values":["AC","A","F","B"],"context":{}},{"code":"actionnement","label":"Actionnement","format":"choice","unit":"","integer":false,"values":["levier","insertion_directe","vis"],"context":{}},{"code":"types_conducteurs","label":"Conducteurs admis","format":"set","unit":"","integer":false,"values":["massif","multifilaire_rigide","souple"],"context":{}},{"code":"fonction_borne","label":"Fonction de borne","format":"choice","unit":"","integer":false,"values":["passage","neutre","PE"],"context":{}},{"code":"rail_compatible","label":"Rail compatible","format":"choice","unit":"","integer":false,"values":["DIN_35","DIN_15","DIN_32"],"context":{}},{"code":"type_accessoire","label":"Type d’accessoire","format":"choice","unit":"","integer":false,"values":["support","pontage","plaque_extremite","reperage"],"context":{}},{"code":"nature_capacite_peigne","label":"Nature de capacité du peigne","format":"choice","unit":"","integer":false,"values":["voies","appareils","modules"],"context":{}},{"code":"connexion_amont","label":"Connexion amont","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"connexion_aval","label":"Connexion aval","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"connexion_cote_1","label":"Connexion cote 1","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"connexion_cote_2","label":"Connexion cote 2","format":"choice","unit":"","integer":false,"values":["vis","automatique","ressort","embrochable"],"context":{}},{"code":"ip","label":"Indice IP","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"ik","label":"Indice IK","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"marquage_calibre","label":"Marquage du calibre","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"fonction_associee","label":"Fonction associée","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"format_appareillage","label":"Format de l’appareillage","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"geometrie_montage","label":"Géométrie de montage","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"systeme_modulaire","label":"Système modulaire","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"taille_accessoire","label":"Taille ou capacité de l’accessoire","format":"text","unit":"","integer":false,"values":[],"context":{}},{"code":"plaque_fournie","label":"Plaque fournie","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"support_fourni","label":"Support fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"enjoliveur_fourni","label":"Enjoliveur fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"boitier_fourni","label":"Boitier fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"eclairable","label":"Eclairable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"source_lumineuse_fournie","label":"Source lumineuse fournie","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"etanche_air","label":"Etanche air","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"serre_cable","label":"Serre cable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"neutre_sectionne","label":"Neutre sectionne","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"selectif","label":"Selectif","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"retard_courte_duree","label":"Retard courte duree","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"porte_fournie","label":"Porte fournie","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"bornier_terre_fourni","label":"Bornier terre fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"bornier_neutre_fourni","label":"Bornier neutre fourni","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"decoupable","label":"Decoupable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"sans_halogene","label":"Sans halogene","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"volet","label":"Volet","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"separable","label":"Separable","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"plaque_extremite_requise","label":"Plaque extremite requise","format":"boolean","unit":"","integer":false,"values":[],"context":{}},{"code":"nombre_prises","label":"Nombre prises","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"nombre_commandes","label":"Nombre commandes","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"contacts_no","label":"Contacts no","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"contacts_nc","label":"Contacts nc","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"contacts_inverseurs","label":"Contacts inverseurs","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"postes","label":"Postes","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"poles","label":"Poles","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"poles_proteges","label":"Poles proteges","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"rangees","label":"Rangees","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"modules_par_rangee","label":"Modules par rangee","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"modules_total","label":"Modules total","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"points_connexion","label":"Points connexion","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"potentiels_independants","label":"Potentiels independants","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"etages","label":"Etages","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"points_par_etage","label":"Points par etage","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"points_par_circuit","label":"Points par circuit","format":"number","unit":"","integer":true,"values":[],"context":{}},{"code":"courant","label":"Courant nominal","format":"number","unit":"A","integer":false,"values":[],"context":{}},{"code":"tension","label":"Tension assignée","format":"number","unit":"V","integer":false,"values":[],"context":{}},{"code":"sensibilite","label":"Sensibilité différentielle","format":"number","unit":"mA","integer":false,"values":[],"context":{}},{"code":"modules_din","label":"Largeur DIN","format":"number","unit":"","integer":false,"values":[],"context":{}},{"code":"modules_appareillage","label":"Modules d’appareillage","format":"number","unit":"","integer":false,"values":[],"context":{}},{"code":"capacite_peigne","label":"Capacité du peigne","format":"number","unit":"","integer":false,"values":[],"context":{}},{"code":"entraxe","label":"Entraxe","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"profondeur_utile","label":"Profondeur utile","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"diametre_percage","label":"Diamètre de perçage","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"largeur","label":"Largeur","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"hauteur","label":"Hauteur","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"profondeur","label":"Profondeur","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"pas_peigne","label":"Pas du peigne","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"longueur_peigne","label":"Longueur du peigne","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"longueur_denudage","label":"Longueur de dénudage","format":"number","unit":"mm","integer":false,"values":[],"context":{}},{"code":"section_rigide","label":"Section rigide","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_multifilaire","label":"Section multifilaire","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_souple","label":"Section souple","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_souple_sans_embout","label":"Section souple sans embout","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"section_souple_avec_embout","label":"Section souple avec embout","format":"range","unit":"mm²","integer":false,"values":[],"context":{}},{"code":"diametre_cable","label":"Diamètre du câble","format":"range","unit":"mm","integer":false,"values":[],"context":{}},{"code":"icn_230","label":"ICN 230 V — EN 60898","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 60898","tension_v":230}},{"code":"icn_400","label":"ICN 400 V — EN 60898","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 60898","tension_v":400}},{"code":"icn_61009_230","label":"ICN_61009 230 V — EN 61009","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 61009","tension_v":230}},{"code":"icn_61009_400","label":"ICN_61009 400 V — EN 61009","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"EN 61009","tension_v":400}},{"code":"icu_230","label":"ICU 230 V — IEC/EN 60947-2","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"IEC/EN 60947-2","tension_v":230}},{"code":"icu_400","label":"ICU 400 V — IEC/EN 60947-2","format":"number","unit":"kA","integer":false,"values":[],"context":{"norme":"IEC/EN 60947-2","tension_v":400}}],"families":[{"code":"prises","label":"Prises de courant","parent":"appareillage","essential":["composition","standard_prise","configuration_contacts","courant","couleur","pose"],"optional":["fixation","connexion","tension","ip","ik","finition","materiau","largeur","hauteur","profondeur","sans_halogene","nombre_prises","volet","modules_appareillage","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme"]},{"code":"interrupteurs","label":"Interrupteurs et va-et-vient","parent":"appareillage","essential":["fonction_commande","nombre_commandes","composition","courant","marquage_calibre","couleur"],"optional":["fixation","connexion","tension","ip","ik","finition","materiau","largeur","hauteur","profondeur","sans_halogene","pose","eclairable","source_lumineuse_fournie","fonction_voyant","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme"]},{"code":"poussoirs","label":"Boutons-poussoirs","parent":"appareillage","essential":["contacts_no","contacts_nc","contacts_inverseurs","nombre_commandes","composition","courant","couleur"],"optional":["fixation","connexion","tension","ip","ik","finition","materiau","largeur","hauteur","profondeur","sans_halogene","pose","eclairable","source_lumineuse_fournie","fonction_voyant","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme"]},{"code":"plaques","label":"Plaques de finition","parent":"appareillage","essential":["postes","orientation","couleur"],"optional":["entraxe","finition","materiau","largeur","hauteur","profondeur","modules_appareillage","ip"],"special":["compatibilite","entraxe_multiposte"]},{"code":"enjoliveurs","label":"Enjoliveurs et touches","parent":"appareillage","essential":["fonction_associee","format_appareillage","couleur"],"optional":["finition","materiau","largeur","hauteur","profondeur","nombre_commandes","modules_appareillage"],"special":["compatibilite"]},{"code":"supports","label":"Supports de fixation","parent":"appareillage","essential":["postes","modules_appareillage","fixation"],"optional":["entraxe","orientation","materiau","largeur","hauteur","profondeur"],"special":["compatibilite","entraxe_multiposte"]},{"code":"boites","label":"Boîtes d’encastrement","parent":"appareillage","essential":["parois_admises","postes","profondeur_utile","geometrie_montage"],"optional":["diametre_percage","entraxe","etanche_air","fixation","largeur","hauteur","profondeur","ip","forme"],"special":[]},{"code":"boitiers-saillie","label":"Boîtiers et cadres en saillie","parent":"appareillage","essential":["postes","modules_appareillage","profondeur_utile"],"optional":["orientation","couleur","largeur","hauteur","profondeur","ip"],"special":["compatibilite"]},{"code":"boites-derivation","label":"Boîtes de dérivation","parent":"appareillage","essential":["pose","forme","largeur","hauteur","profondeur","ip"],"optional":["materiau","fixation","ik","couleur"],"special":[]},{"code":"sorties-cable","label":"Sorties de câble","parent":"appareillage","essential":["composition","serre_cable","couleur"],"optional":["diametre_cable","courant","connexion","pose","fixation","ip","plaque_fournie","support_fourni","enjoliveur_fourni","boitier_fourni"],"special":["gamme_ou_compatibilite"]},{"code":"disjoncteurs","label":"Disjoncteurs modulaires","parent":"protection","essential":["courant","configuration_poles","courbe","tension","type_tension","modules_din"],"optional":["connexion_amont","connexion_aval","poles_proteges","neutre_sectionne","profondeur","icn_230","icn_400","icu_230","icu_400"],"special":["coupure"]},{"code":"differentiels","label":"Interrupteurs différentiels","parent":"protection","essential":["courant","sensibilite","type_differentiel","poles","tension","type_tension","modules_din"],"optional":["connexion_amont","connexion_aval","selectif","retard_courte_duree","profondeur"],"special":[]},{"code":"disjoncteurs-differentiels","label":"Disjoncteurs différentiels","parent":"protection","essential":["courant","sensibilite","type_differentiel","configuration_poles","courbe","tension","type_tension","modules_din"],"optional":["connexion_amont","connexion_aval","poles_proteges","neutre_sectionne","profondeur","icn_230","icn_400","icn_61009_230","icn_61009_400","icu_230","icu_400","selectif","retard_courte_duree"],"special":["coupure"]},{"code":"coffrets","label":"Coffrets modulaires à équiper","parent":"protection","essential":["rangees","modules_par_rangee","modules_total","pose","largeur","hauteur","profondeur","ip"],"optional":["porte_fournie","bornier_terre_fourni","bornier_neutre_fourni","materiau","ik","couleur"],"special":[]},{"code":"peignes","label":"Peignes d’alimentation","parent":"protection","essential":["configuration_poles","connexion","pas_peigne","longueur_peigne","capacite_peigne","nature_capacite_peigne","courant"],"optional":["decoupable","tension"],"special":["compatibilite"]},{"code":"bornes","label":"Bornes de connexion rapide","parent":"raccordement","essential":["actionnement","points_connexion","potentiels_independants","types_conducteurs"],"optional":["section_rigide","section_multifilaire","section_souple","section_souple_sans_embout","section_souple_avec_embout","courant","tension","longueur_denudage","largeur","hauteur","profondeur","couleur","couleur_secondaire"],"special":["sections"]},{"code":"barrettes-vis","label":"Barrettes de raccordement à vis","parent":"raccordement","essential":["potentiels_independants","points_par_circuit","connexion_cote_1","connexion_cote_2","types_conducteurs"],"optional":["section_rigide","section_multifilaire","section_souple","section_souple_sans_embout","section_souple_avec_embout","courant","tension","separable","materiau","largeur","hauteur","profondeur","entraxe"],"special":["sections"]},{"code":"bornes-rail","label":"Bornes pour rail DIN","parent":"raccordement","essential":["fonction_borne","rail_compatible","etages","potentiels_independants","points_par_etage","connexion_cote_1","connexion_cote_2","types_conducteurs"],"optional":["section_rigide","section_multifilaire","section_souple","section_souple_sans_embout","section_souple_avec_embout","courant","tension","couleur","largeur","hauteur","profondeur","plaque_extremite_requise"],"special":["sections"]},{"code":"accessoires-bornes","label":"Accessoires de bornes","parent":"raccordement","essential":["type_accessoire","taille_accessoire"],"optional":["points_connexion","fixation","couleur","largeur","hauteur","profondeur"],"special":["compatibilite"]}]}$vocabulary$; r record; f jsonb; a jsonb; v text; cid bigint; i integer; k text;
begin
 update public.categories set actif=false where actif;
 update public.attributs set actif=false where actif;
 update public.categorie_attributs set filtrable=false where filtrable;
 for r in select * from jsonb_each_text(data->'roots') loop
  insert into public.categories(code,nom,ordre,actif) values(r.key,r.value,0,true)
   on conflict(code) do update set nom=excluded.nom,actif=true;
 end loop;
 for a in select value from jsonb_array_elements(data->'attributes') loop
  insert into public.attributs(code,nom,type,unite,ordre,format_valeur,entier,contexte_requis,actif)
   values(a->>'code',a->>'label',case when a->>'format' in ('number','range') then 'number' when a->>'format'='boolean' then 'boolean' else 'text' end,
   a->>'unit',0,a->>'format',(a->>'integer')::boolean,a->'context',true)
   on conflict(code) do update set nom=excluded.nom,format_valeur=excluded.format_valeur,entier=excluded.entier,contexte_requis=excluded.contexte_requis,actif=true;
  for v in select jsonb_array_elements_text(a->'values') loop
   insert into public.attribut_valeurs(attribut_code,code,libelle) values(a->>'code',v,replace(v,'_',' ')) on conflict do nothing;
  end loop;
 end loop;
 i:=0;
 for f in select value from jsonb_array_elements(data->'families') loop
  insert into public.categories(code,nom,parent_id,ordre,actif)
   select f->>'code',f->>'label',id,i,true from public.categories where code=f->>'parent'
   on conflict(code) do update set nom=excluded.nom,parent_id=excluded.parent_id,ordre=excluded.ordre,actif=true returning id into cid;
  i:=i+10;
  for r in select value,ordinality from jsonb_array_elements_text((f->'essential')||(f->'optional')) with ordinality loop
   insert into public.categorie_attributs(categorie_id,attribut_code,filtrable,ordre,essentiel,actif)
    values(cid,r.value,true,r.ordinality::int*10,(f->'essential') ? r.value,true)
    on conflict(categorie_id,attribut_code) do update set filtrable=true,ordre=excluded.ordre,essentiel=excluded.essentiel,actif=true;
  end loop;
  for k in select jsonb_array_elements_text(f->'special') loop
   insert into public.categorie_exigences(categorie_id,code) values(cid,k);
  end loop;
 end loop;
end $seed$;

create or replace function public.rechercher_catalogue_v2(terme text default '', filtres jsonb default '{}', page_num integer default 0)
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
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',id,'code',code,'nom',nom,'parent_id',parent_id,'ordre',ordre) order by ordre,nom) from public.categories_catalogue where actif),'[]')
 ) into resultat;
 return resultat;
end $$;$migration_20261029161909$]);

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

begin;

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

commit;

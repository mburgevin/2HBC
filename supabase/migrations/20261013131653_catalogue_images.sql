begin;
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

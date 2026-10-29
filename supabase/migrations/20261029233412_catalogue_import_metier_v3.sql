begin;
-- v3 is additive. Raw evidence stays private; qualification and publication are
-- separate operations. No legacy migration or product data is rewritten.
alter table public.observations_attributs
 add column empreinte_import text check(empreinte_import ~ '^[a-f0-9]{64}$'),
 add column collecte_empreinte text references public.collectes_catalogue(empreinte);
create unique index observations_import_unique on public.observations_attributs(produit_id,empreinte_import) where empreinte_import is not null;
create index observations_collecte on public.observations_attributs(collecte_empreinte);

create function public.importer_catalogue_v3(fiche jsonb, approuver boolean default false, publier boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
<<v3>>
declare
 base jsonb; result jsonb; source jsonb; a jsonb; payload jsonb; o public.observations_attributs%rowtype;
 pid bigint; cid bigint; oid bigint; digest text; observation_digest text; statut_observation text;
 selection_keys jsonb:='[]'; observation_keys text[]:='{}'; selection_key jsonb;
 collection public.collectes_catalogue%rowtype;
begin
 if current_user not in ('postgres','service_role') and coalesce(auth.jwt()->'app_metadata'->>'role','')<>'admin'
 then raise exception 'Import réservé à un administrateur' using errcode='42501'; end if;
 if approuver is null or publier is null or (publier and not approuver) then raise exception 'Publication sans qualification explicite'; end if;
 if fiche is null or jsonb_typeof(fiche)<>'object' or octet_length(fiche::text)>64000 or fiche->'schema_version' is distinct from '3'::jsonb
 then raise exception 'Fiche métier v3 invalide'; end if;
 if not(fiche ?& array['brand','reference','ean','name','categories','review_status','offers','schema_version','category_code','range','observations','exceptions','compatibilities'])
  or exists(select 1 from jsonb_object_keys(fiche) k where k not in
  ('brand','reference','ean','name','categories','review_status','offers','schema_version','category_code','range','observations','exceptions','compatibilities'))
 then raise exception 'Fiche v3 : champs inconnus ou manquants'; end if;
 perform pg_advisory_xact_lock(2042,1);
 base:=(fiche-array['observations','exceptions','compatibilities'])||'{"schema_version":2,"attributes":[],"attribute_conflicts":[]}'::jsonb;
 -- Reuse authoritative checks for official URLs, hashes, dates, GTIN and raw
 -- source data. The whole call rolls back if any subsequent check fails.
 perform public.importer_catalogue_v2(base,false);
 select id into cid from public.categories where code=fiche->>'category_code' and actif
  and not exists(select 1 from public.categories child where child.parent_id=categories.id);
 if (fiche->>'category_code' is not null or approuver) and cid is null then raise exception 'Famille finale active requise'; end if;
 if approuver and fiche->>'review_status'<>'approved' then raise exception 'Identité non approuvée'; end if;
 if jsonb_typeof(fiche->'observations') is distinct from 'array' or jsonb_typeof(fiche->'exceptions') is distinct from 'array'
  or jsonb_typeof(fiche->'compatibilities') is distinct from 'array' then raise exception 'Listes métier attendues'; end if;
 if jsonb_array_length(fiche->'observations')>300 or jsonb_array_length(fiche->'exceptions')>100 or jsonb_array_length(fiche->'compatibilities')>100
 then raise exception 'Trop de données métier'; end if;
 for a in select value from jsonb_array_elements(fiche->'observations') loop
  if jsonb_typeof(a)<>'object' or not(a ?& array['code','value','unit','context','supplier','raw_label','raw_value','rule_version','status','selected','review_note'])
   or exists(select 1 from jsonb_object_keys(a) k where k not in ('code','value','unit','context','supplier','raw_label','raw_value','rule_version','status','selected','review_note'))
  then raise exception 'Observation : champs inconnus ou manquants'; end if;
  if jsonb_typeof(a->'code') is distinct from 'string' or jsonb_typeof(a->'unit') is distinct from 'string'
   or jsonb_typeof(a->'context') is distinct from 'object' or octet_length((a->'context')::text)>2000
   or public.valeur_metier_valide(a->>'code',a->'value',a->>'unit',a->'context') is not true
  then raise exception 'Observation : valeur, unité ou contexte invalide'; end if;
  if jsonb_typeof(a->'rule_version') is distinct from 'string' or length(btrim(a->>'rule_version')) not between 1 and 100
   or coalesce(a->>'status','') not in ('pending','validated','rejected') or jsonb_typeof(a->'selected') is distinct from 'boolean'
   or ((a->>'selected')::boolean and a->>'status'<>'validated')
   or (a->>'review_note' is not null and (jsonb_typeof(a->'review_note')<>'string' or length(btrim(a->>'review_note')) not between 1 and 2000))
   or (a->>'status'='rejected' and coalesce(length(btrim(a->>'review_note')),0)<10)
  then raise exception 'Décision de revue invalide ou rejet sans motif'; end if;
  select x into source from jsonb_array_elements(fiche->'offers') x where x->>'supplier'=a->>'supplier';
  if source is null or jsonb_typeof(a->'raw_label') is distinct from 'string' or jsonb_typeof(a->'raw_value') is distinct from 'string'
   or not(source->'raw_attributes' @> jsonb_build_array(jsonb_build_object('label',a->'raw_label','value',a->'raw_value')))
  then raise exception 'Observation sans provenance exacte'; end if;
  observation_digest:=encode(sha256(convert_to((a-array['status','selected','review_note'])::text,'UTF8')),'hex');
  if observation_digest=any(observation_keys) then raise exception 'Observation dupliquée'; end if;
  observation_keys:=array_append(observation_keys,observation_digest);
  if (a->>'selected')::boolean then
   if approuver and not exists(select 1 from public.categorie_attributs where categorie_id=cid and attribut_code=a->>'code' and actif)
   then raise exception 'Attribut sélectionné non applicable à la famille'; end if;
   selection_key:=jsonb_build_object('code',a->'code','context',a->'context');
   if selection_keys @> jsonb_build_array(selection_key) then raise exception 'Deux sélections pour le même attribut/contexte'; end if;
   selection_keys:=selection_keys||jsonb_build_array(selection_key);
  end if;
 end loop;
 for a in select value from jsonb_array_elements(fiche->'exceptions') loop
  if jsonb_typeof(a)<>'object' or not(a ?& array['code','context','reason','source_url'])
   or exists(select 1 from jsonb_object_keys(a) k where k not in ('code','context','reason','source_url'))
   or jsonb_typeof(a->'code') is distinct from 'string' or not exists(select 1 from public.attributs where code=a->>'code' and actif)
   or jsonb_typeof(a->'context') is distinct from 'object' or octet_length((a->'context')::text)>2000
   or jsonb_typeof(a->'reason') is distinct from 'string' or length(btrim(a->>'reason')) not between 10 and 2000
   or jsonb_typeof(a->'source_url') is distinct from 'string' or length(a->>'source_url')>2000
   or a->>'source_url' !~ '^https://[^/@?#[:space:]]+/[^?#[:space:]]*$'
  then raise exception 'Exception sans motif ou source valide'; end if;
  if approuver and not exists(select 1 from public.categorie_attributs where categorie_id=cid and attribut_code=a->>'code' and actif)
  then raise exception 'Exception non applicable à la famille'; end if;
  selection_key:=jsonb_build_object('code',a->'code','context',a->'context');
  if selection_keys @> jsonb_build_array(selection_key) then raise exception 'Sélection et exception contradictoires'; end if;
  selection_keys:=selection_keys||jsonb_build_array(selection_key);
 end loop;
 for a in select value from jsonb_array_elements(fiche->'compatibilities') loop
  if jsonb_typeof(a)<>'object' or not(a ?& array['system','version','role','source_url','observed_at','evidence'])
   or exists(select 1 from jsonb_object_keys(a) k where k not in ('system','version','role','source_url','observed_at','evidence'))
   or jsonb_typeof(a->'system') is distinct from 'string' or length(btrim(a->>'system')) not between 1 and 200
   or jsonb_typeof(a->'version') is distinct from 'string' or length(btrim(a->>'version')) not between 1 and 100
   or coalesce(a->>'role','') not in ('compatible_avec','accessoire_pour')
   or jsonb_typeof(a->'evidence') is distinct from 'string' or length(btrim(a->>'evidence')) not between 10 and 4000
   or jsonb_typeof(a->'source_url') is distinct from 'string' or length(a->>'source_url')>2000
   or a->>'source_url' !~ '^https://[^/@?#[:space:]]+/[^?#[:space:]]*$'
   or jsonb_typeof(a->'observed_at') is distinct from 'string'
   or a->>'observed_at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$'
  then raise exception 'Compatibilité non documentée'; end if;
  if (a->>'observed_at')::timestamptz>now()+interval '5 minutes' then raise exception 'Compatibilité dans le futur'; end if;
 end loop;
 payload:=fiche-'review_status';
 digest:=encode(sha256(convert_to(payload::text,'UTF8')),'hex');
 insert into public.collectes_catalogue(empreinte,donnees) values(digest,payload) on conflict do nothing;
 select * into collection from public.collectes_catalogue where empreinte=digest for update;
 if not approuver then return jsonb_build_object('empreinte',digest,'statut',collection.statut,'produit_id',collection.produit_id); end if;
 -- An identical reviewed document must not unpublish a previously published
 -- product, replace evidence or touch personal prices on a repeated import.
 if collection.statut='imported' then
  pid:=collection.produit_id;
 else
  -- The v2 bridge handles identities, offers, photos, ranges and source paths.
  -- This approval materializes a PRIVATE product, never publishes it.
  result:=public.importer_catalogue_v2(base,true); pid:=(result->>'produit_id')::bigint;
  for a in select value from jsonb_array_elements(fiche->'observations') loop
   select x into source from jsonb_array_elements(fiche->'offers') x where x->>'supplier'=a->>'supplier';
   observation_digest:=encode(sha256(convert_to(jsonb_build_object(
    'observation',a-array['status','selected','review_note'],'url',source->'url',
    'observed_at',source->'collected_at','page_sha256',source->'page_sha256')::text,'UTF8')),'hex');
   statut_observation:=case a->>'status' when 'validated' then 'validee' when 'rejected' then 'rejetee' else 'observee' end;
   select * into o from public.observations_attributs where produit_id=pid and empreinte_import=observation_digest;
   if found then
    oid:=o.id;
    -- Pending proposals cannot downgrade an existing reviewed observation.
    if a->>'status'<>'pending' and row(o.statut,o.motif_revue) is distinct from row(statut_observation,a->>'review_note') then
     -- A deliberate rejection revokes the selection before the immutable source
     -- can change its review status. Absence from an import never deletes evidence.
     if a->>'status'='rejected' then delete from public.valeurs_catalogue where observation_id=oid; end if;
     update public.observations_attributs set statut=statut_observation,motif_revue=a->>'review_note' where id=oid;
    end if;
   else
    insert into public.observations_attributs(produit_id,attribut_code,valeur,unite,contexte,libelle_source,valeur_source,
     source_url,observe_le,regle_version,statut,motif_revue,empreinte_import,collecte_empreinte)
    values(pid,a->>'code',a->'value',a->>'unit',a->'context',a->>'raw_label',a->>'raw_value',source->>'url',
     (source->>'collected_at')::timestamptz,a->>'rule_version',statut_observation,a->>'review_note',observation_digest,digest) returning id into oid;
   end if;
   if (a->>'selected')::boolean then
    insert into public.valeurs_catalogue as v(produit_id,attribut_code,contexte,valeur,observation_id)
    values(pid,a->>'code',a->'context',a->'value',oid)
    on conflict(produit_id,attribut_code,contexte) do update set valeur=excluded.valeur,observation_id=excluded.observation_id,
     statut='valide',motif=null,source_exception=null,valide_le=now()
    where row(v.valeur,v.observation_id,v.statut) is distinct from row(excluded.valeur,excluded.observation_id,'valide'::text);
   end if;
  end loop;
  for a in select value from jsonb_array_elements(fiche->'exceptions') loop
   insert into public.valeurs_catalogue as v(produit_id,attribut_code,contexte,statut,motif,source_exception)
   values(pid,a->>'code',a->'context','non_applicable',a->>'reason',a->>'source_url')
   on conflict(produit_id,attribut_code,contexte) do update set statut='non_applicable',valeur=null,observation_id=null,
    motif=excluded.motif,source_exception=excluded.source_exception,valide_le=now()
   where row(v.statut,v.motif,v.source_exception) is distinct from row('non_applicable'::text,excluded.motif,excluded.source_exception);
  end loop;
  for a in select value from jsonb_array_elements(fiche->'compatibilities') loop
   insert into public.compatibilites_produits as c(produit_id,systeme,version_systeme,role_relation,source_url,observe_le,statut,preuve)
   values(pid,a->>'system',a->>'version',a->>'role',a->>'source_url',(a->>'observed_at')::timestamptz,'valide',a->>'evidence')
   on conflict(produit_id,cible_produit_id,systeme,version_systeme,role_relation) do update set source_url=excluded.source_url,
    observe_le=excluded.observe_le,statut='valide',preuve=excluded.preuve
   where row(c.source_url,c.observe_le,c.statut,c.preuve) is distinct from row(excluded.source_url,excluded.observe_le,'valide'::text,excluded.preuve);
  end loop;
  update public.collectes_catalogue set statut='imported',produit_id=pid,valide_le=now() where empreinte=digest;
 end if;
 if publier then perform public.publier_produit_catalogue(pid); end if;
 return jsonb_build_object('empreinte',digest,'statut','imported','produit_id',pid,
  'qualification',(select statut_qualification from public.produits where id=pid),'diagnostic',public.diagnostic_publication(pid));
end $$;
revoke all on function public.importer_catalogue_v3(jsonb,boolean,boolean) from public,anon,authenticated;
grant execute on function public.importer_catalogue_v3(jsonb,boolean,boolean) to authenticated,service_role;
notify pgrst,'reload schema';
commit;

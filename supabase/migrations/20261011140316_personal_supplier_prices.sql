begin;
alter table public.produits add column catalogue_verifie boolean not null default false;
alter table public.produits add column source_catalogue text check (source_catalogue is null or source_catalogue ~ '^https://');
alter table public.produits add column catalogue_verifie_le timestamptz;
alter table public.produits_fournisseurs add column reference_verifiee boolean not null default false;
alter table public.produits_fournisseurs add column reference_verifiee_le timestamptz;

-- Observations privées, pas des tarifs contractuels garantis par le fournisseur.
-- Aucun identifiant de connexion, cookie, token, numéro de compte ou HTML stocké.
create table public.prix_personnels (
 id uuid primary key,
 client_id uuid not null references public.clients(id) on delete cascade,
 offre_id bigint not null references public.produits_fournisseurs(id) on delete cascade,
 contexte_empreinte text not null check (contexte_empreinte ~ '^[a-f0-9]{64}$'),
 quantite integer not null check (quantite between 1 and 9999),
 montant_ht numeric(16,4) not null check (montant_ht > 0 and montant_ht <= 1000000),
 base_prix numeric(16,4) not null check (base_prix > 0 and base_prix <= 1000000),
 unite text not null check (unite in ('piece','m','kg')),
 devise text not null default 'EUR' check (devise='EUR'),
 nature text not null default 'net_compte_observe' check (nature='net_compte_observe'),
 source_url text not null,
 observe_le timestamptz not null,
 expire_le timestamptz not null,
 check (expire_le=observe_le + interval '10 minutes')
);
create index prix_personnels_client_offre on public.prix_personnels(client_id,offre_id,observe_le desc);
create index prix_personnels_offre on public.prix_personnels(offre_id);
alter table public.prix_personnels enable row level security;
revoke all on public.prix_personnels from anon,authenticated;
grant select,insert,delete on public.prix_personnels to authenticated;
create policy prix_personnels_lecture on public.prix_personnels for select to authenticated
 using (client_id=(select auth.uid()));
create policy prix_personnels_creation on public.prix_personnels for insert to authenticated
 with check (client_id=(select auth.uid()) and coalesce((select auth.jwt())->>'is_anonymous','false')<>'true'
   and observe_le <= now() + interval '1 minute' and observe_le > now() - interval '10 minutes'
   and exists(select 1 from public.produits_fournisseurs pf
     where pf.id=offre_id and pf.reference_verifiee and pf.url_produit=source_url));
create policy prix_personnels_suppression on public.prix_personnels for delete to authenticated
 using (client_id=(select auth.uid()));

-- Nouvelle entrée de catalogue : ne change pas le comportement de l'ancien site.
create function public.rechercher_catalogue_personnel(terme text default '', page_num integer default 0)
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
 and position(lower(left(coalesce(terme,''),100)) in lower(p.nom || ' ' || p.ref_fabricant || ' ' || p.marque))>0
 order by p.nom,p.id limit 24 offset (greatest(0,least(coalesce(page_num,0),100000))*24);
$$;
revoke all on function public.rechercher_catalogue_personnel(text,integer) from public;
grant execute on function public.rechercher_catalogue_personnel(text,integer) to anon,authenticated;
commit;

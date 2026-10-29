"""Compile the reviewed business vocabulary. No network or database writes.

Outputs versioned JSON and seed SQL for a NEW migration; never edit an applied
migration with this program. The schema supports intervals as one atomic value.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
attrs = {}
def attr(code, label, fmt='text', unit='', values=None, integer=False, context=None):
    assert code not in attrs, code
    attrs[code] = dict(code=code, label=label, format=fmt, unit=unit,
                       integer=integer, values=values or [], context=context or {})

choices = {
'couleur': ('Couleur','blanc noir gris anthracite beige transparent incolore rouge bleu vert jaune orange marron'),
'couleur_secondaire': ('Couleur secondaire','blanc noir gris anthracite transparent rouge bleu vert jaune orange'),
'finition': ('Finition','mat brillant satine'), 'materiau': ('Matériau','plastique metal bois verre ceramique'),
'pose': ('Mode de pose','encastre saillie rail_din support_modulaire montage_direct'),
'fixation': ('Fixation','vis griffes clips'),
'composition': ('Composition','mecanisme_seul mecanisme_enjoliveur ensemble_complet finition_seule support_seul boitier_seul'),
'type_tension': ('Type de tension','AC DC AC_DC'),
'connexion': ('Raccordement','vis automatique ressort embrochable'),
'standard_prise': ('Standard de prise','franco_belge schuko universel'),
'configuration_contacts': ('Configuration des contacts','2P 2P_T'),
'fonction_commande': ('Fonction de commande','simple_allumage va_et_vient permutateur double_allumage double_va_et_vient'),
'fonction_voyant': ('Fonction du voyant','reperage temoin'),
'orientation': ('Orientation','horizontal vertical'),
'parois_admises': ('Parois admises','cloison_creuse maconnerie beton'),
'forme': ('Forme','ronde carree rectangulaire ovale'),
'configuration_poles': ('Configuration des pôles','1P 1P_N 2P 3P 3P_N 4P'),
'courbe': ('Courbe','B C D K Z'), 'type_differentiel': ('Type différentiel','AC A F B'),
'actionnement': ('Actionnement','levier insertion_directe vis'),
'types_conducteurs': ('Conducteurs admis','massif multifilaire_rigide souple'),
'fonction_borne': ('Fonction de borne','passage neutre PE'),
'rail_compatible': ('Rail compatible','DIN_35 DIN_15 DIN_32'),
'type_accessoire': ('Type d’accessoire','support pontage plaque_extremite reperage'),
'nature_capacite_peigne': ('Nature de capacité du peigne','voies appareils modules'),
}
sets={'pose','fixation','orientation','parois_admises','types_conducteurs'}
for k,(label,vs) in choices.items(): attr(k,label,'set' if k in sets else 'choice',values=vs.split())
for k in ['connexion_amont','connexion_aval','connexion_cote_1','connexion_cote_2']:
    attr(k,k.replace('_',' ').capitalize(),'choice',values=choices['connexion'][1].split())
for k,label in [('ip','Indice IP'),('ik','Indice IK'),('marquage_calibre','Marquage du calibre'),
 ('fonction_associee','Fonction associée'),('format_appareillage','Format de l’appareillage'),
 ('geometrie_montage','Géométrie de montage'),('systeme_modulaire','Système modulaire'),
 ('taille_accessoire','Taille ou capacité de l’accessoire')]: attr(k,label)
for k in ['plaque_fournie','support_fourni','enjoliveur_fourni','boitier_fourni','eclairable',
 'source_lumineuse_fournie','etanche_air','serre_cable','neutre_sectionne','selectif',
 'retard_courte_duree','porte_fournie','bornier_terre_fourni','bornier_neutre_fourni',
 'decoupable','sans_halogene','volet','separable','plaque_extremite_requise']:
    attr(k,k.replace('_',' ').capitalize(),'boolean')
for k in ['nombre_prises','nombre_commandes','contacts_no','contacts_nc','contacts_inverseurs',
 'postes','poles','poles_proteges','rangees','modules_par_rangee','modules_total',
 'points_connexion','potentiels_independants','etages','points_par_etage','points_par_circuit']:
    attr(k,k.replace('_',' ').capitalize(),'number',integer=True)
for k,label,unit in [('courant','Courant nominal','A'),('tension','Tension assignée','V'),
 ('sensibilite','Sensibilité différentielle','mA'),('modules_din','Largeur DIN',''),
 ('modules_appareillage','Modules d’appareillage',''),('capacite_peigne','Capacité du peigne',''),
 ('entraxe','Entraxe','mm'),('profondeur_utile','Profondeur utile','mm'),
 ('diametre_percage','Diamètre de perçage','mm'),('largeur','Largeur','mm'),
 ('hauteur','Hauteur','mm'),('profondeur','Profondeur','mm'),('pas_peigne','Pas du peigne','mm'),
 ('longueur_peigne','Longueur du peigne','mm'),('longueur_denudage','Longueur de dénudage','mm')]:
    attr(k,label,'number',unit)
for k in ['rigide','multifilaire','souple','souple_sans_embout','souple_avec_embout']:
    attr('section_'+k,'Section '+k.replace('_',' '),'range','mm²')
attr('diametre_cable','Diamètre du câble','range','mm')
for k,norme in [('icn','EN 60898'),('icn_61009','EN 61009'),('icu','IEC/EN 60947-2')]:
    for tension in [230,400]:
        attr(f'{k}_{tension}',f'{k.upper()} {tension} V — {norme}','number','kA',context={'norme':norme,'tension_v':tension})

families=[]
def family(code,label,parent,essential,optional='',special=()):
    essentials=essential.split(); optional=optional.split()
    assert set(essentials+optional)<=attrs.keys(),(code,set(essentials+optional)-attrs.keys())
    families.append(dict(code=code,label=label,parent=parent,essential=essentials,
                         optional=list(dict.fromkeys(optional)),special=list(special)))
app='fixation connexion tension ip ik finition materiau largeur hauteur profondeur sans_halogene'
family('prises','Prises de courant','appareillage','composition standard_prise configuration_contacts courant couleur pose',app+' nombre_prises volet modules_appareillage',('gamme',))
family('interrupteurs','Interrupteurs et va-et-vient','appareillage','fonction_commande nombre_commandes composition courant marquage_calibre couleur',app+' pose eclairable source_lumineuse_fournie fonction_voyant',('gamme',))
family('poussoirs','Boutons-poussoirs','appareillage','contacts_no contacts_nc contacts_inverseurs nombre_commandes composition courant couleur',app+' pose eclairable source_lumineuse_fournie fonction_voyant',('gamme',))
family('plaques','Plaques de finition','appareillage','postes orientation couleur','entraxe finition materiau largeur hauteur profondeur modules_appareillage ip',('compatibilite','entraxe_multiposte'))
family('enjoliveurs','Enjoliveurs et touches','appareillage','fonction_associee format_appareillage couleur','finition materiau largeur hauteur profondeur nombre_commandes modules_appareillage',('compatibilite',))
family('supports','Supports de fixation','appareillage','postes modules_appareillage fixation','entraxe orientation materiau largeur hauteur profondeur',('compatibilite','entraxe_multiposte'))
family('boites','Boîtes d’encastrement','appareillage','parois_admises postes profondeur_utile geometrie_montage','diametre_percage entraxe etanche_air fixation largeur hauteur profondeur ip forme')
family('boitiers-saillie','Boîtiers et cadres en saillie','appareillage','postes modules_appareillage profondeur_utile','orientation couleur largeur hauteur profondeur ip',('compatibilite',))
family('boites-derivation','Boîtes de dérivation','appareillage','pose forme largeur hauteur profondeur ip','materiau fixation ik couleur')
family('sorties-cable','Sorties de câble','appareillage','composition serre_cable couleur','diametre_cable courant connexion pose fixation ip',('gamme_ou_compatibilite',))
protection='connexion_amont connexion_aval poles_proteges neutre_sectionne profondeur'
breakers='icn_230 icn_400 icn_61009_230 icn_61009_400 icu_230 icu_400'
family('disjoncteurs','Disjoncteurs modulaires','protection','courant configuration_poles courbe tension type_tension modules_din',protection+' icn_230 icn_400 icu_230 icu_400',('coupure',))
family('differentiels','Interrupteurs différentiels','protection','courant sensibilite type_differentiel poles tension type_tension modules_din','connexion_amont connexion_aval selectif retard_courte_duree profondeur')
family('disjoncteurs-differentiels','Disjoncteurs différentiels','protection','courant sensibilite type_differentiel configuration_poles courbe tension type_tension modules_din',protection+' '+breakers+' selectif retard_courte_duree',('coupure',))
family('coffrets','Coffrets modulaires à équiper','protection','rangees modules_par_rangee modules_total pose largeur hauteur profondeur ip','porte_fournie bornier_terre_fourni bornier_neutre_fourni materiau ik couleur')
family('peignes','Peignes d’alimentation','protection','configuration_poles connexion pas_peigne longueur_peigne capacite_peigne nature_capacite_peigne courant','decoupable tension',('compatibilite',))
sections='section_rigide section_multifilaire section_souple section_souple_sans_embout section_souple_avec_embout'
family('bornes','Bornes de connexion rapide','raccordement','actionnement points_connexion potentiels_independants types_conducteurs',sections+' courant tension longueur_denudage largeur hauteur profondeur couleur couleur_secondaire',('sections',))
family('barrettes-vis','Barrettes de raccordement à vis','raccordement','potentiels_independants points_par_circuit connexion_cote_1 connexion_cote_2 types_conducteurs',sections+' courant tension separable materiau largeur hauteur profondeur entraxe',('sections',))
family('bornes-rail','Bornes pour rail DIN','raccordement','fonction_borne rail_compatible etages potentiels_independants points_par_etage connexion_cote_1 connexion_cote_2 types_conducteurs',sections+' courant tension couleur largeur hauteur profondeur plaque_extremite_requise',('sections',))
family('accessoires-bornes','Accessoires de bornes','raccordement','type_accessoire taille_accessoire','points_connexion fixation couleur largeur hauteur profondeur',('compatibilite',))
# Content flags apply only to functional wall devices, not every catalogue family.
for f in families:
    if 'composition' in f['essential']:
        f['optional'] += ['plaque_fournie','support_fourni','enjoliveur_fourni','boitier_fourni']

data={'version':'1.0.0','roots':{'appareillage':'Appareillage mural et boîtes','protection':'Protections et distribution modulaire','raccordement':'Connexion et raccordement'},'attributes':list(attrs.values()),'families':families}
assert len(families)==19 and len({f['code'] for f in families})==19
path=ROOT/'catalog/model/referentiel_v1.json'
path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
payload=json.dumps(data,ensure_ascii=False,separators=(',',':'))
seed="""-- Generated from catalog/model/referentiel_v1.json.
do $seed$
declare data jsonb := $vocabulary$%s$vocabulary$; r record; f jsonb; a jsonb; v text; cid bigint; i integer; k text;
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
""" % payload
(ROOT/'supabase/catalogue/referentiel_seed.sql').write_text(seed)
print(f'{len(families)} families, {len(attrs)} attributes')

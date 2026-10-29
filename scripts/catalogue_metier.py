"""Business contract v3: conservative proposals, retained evidence, explicit review.

No network, credentials or database access. The versioned vocabulary is shared
with the schema. A proposal is never automatically a validated catalogue value.
"""
import copy
from decimal import Decimal
import json
import math
import re
import unicodedata
from pathlib import Path

MODEL = json.loads((Path(__file__).resolve().parents[1] / 'catalog/model/referentiel_v1.json').read_text(encoding='utf-8'))
ATTRS = {a['code']: a for a in MODEL['attributes']}
FAMILIES = {f['code']: f for f in MODEL['families']}
RULE_VERSION = '2hbc-metier-0.5.0'
OBS_KEYS = {'code','value','unit','context','supplier','raw_label','raw_value','rule_version','status','selected','review_note'}
EXCEPTION_KEYS = {'code','context','reason','source_url'}
COMPAT_KEYS = {'system','version','role','source_url','observed_at','evidence'}
PRODUCT_KEYS = {'brand','reference','ean','name','categories','review_status','offers','schema_version','category_code','range','observations','exceptions','compatibilities'}


def key(text):
    return re.sub(r'\s+', ' ', ''.join(c for c in unicodedata.normalize('NFKD', text.casefold())
        if not unicodedata.combining(c)).replace('_',' ')).strip(' :')


# Exact labels only. Ambiguous "modules", "unités" and unqualified breaking
# capacities deliberately have no alias. Raw strings always remain in offers.
LABELS = {key(a['label']): a['code'] for a in ATTRS.values()}
LABELS.update({key(k): v for k,v in {
 'Mode de pose':'pose','Type de pose':'pose','Type de fixation':'fixation',
 'Type de connexion':'connexion','Courant nominal':'courant','Courant nominal assigné':'courant','Intensité':'courant',
 'Calibre/courant nominal assigné (In)':'courant','Tension assignée (Ue)':'tension',
 'Tension nominale':'tension','Nombre de pôles':'poles','Nombre de pôles (total)':'poles',
 'Nombre de pôles protégés':'poles_proteges','Courbe de déclenchement':'courbe',
 'Caractéristique de déclenchement (type/courbe)':'courbe','Caractéristique de déclenchement':'courbe',
 'Courant différentiel assigné':'sensibilite','Sensibilité différentielle':'sensibilite',
 'Type de protection différentielle':'type_differentiel','Nombre de postes':'postes',
 'Nombre de commandes':'nombre_commandes','Nombre de points de connexion':'points_connexion',
 'Nombre de potentiels':'potentiels_independants','Nombre de potentiels indépendants':'potentiels_independants',
 'Types de conducteurs':'types_conducteurs','Type de conducteur':'types_conducteurs',
 'Type de raccordement':'connexion','Type de raccordement côté 1':'connexion_cote_1',
 'Type de raccordement côté 2':'connexion_cote_2','Section conducteur rigide':'section_rigide',
 'Section conducteur multifilaire':'section_multifilaire','Section conducteur souple':'section_souple',
 'Section conducteur souple avec embout':'section_souple_avec_embout',
 'Section conducteur souple sans embout':'section_souple_sans_embout',
 'Section de conducteur connectable souple avec embout':'section_souple_avec_embout',
 'Section de conducteur connectable souple sans embout':'section_souple_sans_embout',
 'Section de conducteur connectable rigide':'section_rigide',
 'Largeur en modules DIN':'modules_din','Largeur en modules d’appareillage':'modules_appareillage',
 'Indice de protection (IP)':'ip','Classe de protection (IP)':'ip',
 'Sans halogène':'sans_halogene','Technologie de connexion':'actionnement',
 # Exact labels confirmed on the six live pilot pages (2026-10-30, Paris).
 'Type de commutation':'fonction_commande',"Nombre de bascules d'actionnement":'nombre_commandes',
 'Finition de la surface':'finition','IK':'ik','Indice de protection contre les chocs (IK)':'ik',
 "Largeur d'appareil":'largeur',"Hauteur d'appareil":'hauteur',"Profondeur d'appareil":'profondeur',
 'Calibre':'courant',
}.items()})
CONTEXTS = {}
for code in ('icn_230','icn_400','icn_61009_230','icn_61009_400','icu_230','icu_400'):
    a=ATTRS[code]; symbol='Icu' if code.startswith('icu') else 'Icn'
    norm=a['context']['norme']; tension=a['context']['tension_v']
    for label in (f'Pouvoir de coupure assigné {symbol} selon {norm} à {tension} V',
                  f'Pouvoir de coupure assigné selon {norm} à {tension} V ({symbol})',
                  f'Pouvoir de coupure assigné selon {norm.replace("IEC/EN", "IEC")} à {tension} V ({symbol})'):
        LABELS[key(label)]=code; CONTEXTS[key(label)]=a['context']
for label,context in [('Indice de protection (IP) avec porte','avec_porte'),
                      ('Indice de protection (IP) sans porte','sans_porte'),
                      ('Indice de protection (IP) à l’état livré','etat_livre')]:
    LABELS[key(label)]='ip'; CONTEXTS[key(label)]={'assemblage':context}
ALIASES = {
 'pose': {'en saillie':'saillie','encastre':'encastre','rail din':'rail_din'},
 'fixation': {'a vis':'vis','a griffes':'griffes','a clipser':'clips','fixation a vis':'vis','fixation a griffes':'griffes'},
 'connexion': {'a vis':'vis','borne a vis':'vis','borne automatique':'automatique'},
 'fonction_commande': {'va-et-vient':'va_et_vient'},
 'composition': {'mecanisme avec enjoliveur (ou doigt)':'mecanisme_enjoliveur'},
 'configuration_poles': {'1p+n':'1P_N','3p+n':'3P_N'},
 'configuration_contacts': {'2p+t':'2P_T'},
 'type_tension': {'ac/dc':'AC_DC'},
 'actionnement': {'a levier':'levier','a vis':'vis'},
 'types_conducteurs': {'rigide massif':'massif','multifilaire rigide':'multifilaire_rigide'},
 'fonction_borne': {'terre':'PE'},
}
NUM = r'[0-9]+(?:[.,][0-9]+)?'


def valid_value(code, value, unit, context):
    a=ATTRS.get(code)
    if not a or unit!=a['unit'] or not isinstance(context,dict): return False
    if any(context.get(k)!=v for k,v in a['context'].items()): return False
    fmt=a['format']
    number=lambda n: type(n) in (int,float) and math.isfinite(n) and 0<=n<=1e9
    if fmt=='number': return number(value) and (not a['integer'] or int(value)==value)
    if fmt=='boolean': return type(value) is bool
    if fmt=='choice': return isinstance(value,str) and value in a['values']
    if fmt=='set': return isinstance(value,list) and 1<=len(value)<=30 and all(isinstance(v,str) and v in a['values'] for v in value) and len(set(value))==len(value)
    if fmt=='range': return isinstance(value,dict) and set(value)=={'min','max'} and all(number(v) for v in value.values()) and value['min']<=value['max']<1e9
    if not isinstance(value,str) or not 1<=len(value.strip())<=1000: return False
    if code=='ip': return bool(re.fullmatch(r'IP[0-6X][0-9X][A-D]?[HMSW]?',value)) and isinstance(context.get('assemblage'),str) and bool(context['assemblage'].strip())
    if code=='ik': return bool(re.fullmatch(r'IK(0[0-9]|10|11)',value))
    return True


def proposal(label, raw_value):
    code=LABELS.get(key(label))
    if not code: return None
    a=ATTRS[code]; fmt=a['format']; ctx=copy.deepcopy(CONTEXTS.get(key(label),a['context']))
    text=raw_value.strip(); value=None
    if fmt in ('number','range'):
        unit=re.escape(a['unit']).replace('²','[²2]')
        if fmt=='range':
            m=re.fullmatch(rf'({NUM})\s*(?:\.\.\.?|…|–|-|à)\s*({NUM})\s*{unit}',text)
            if m: value={'min':float(m[1].replace(',','.')),'max':float(m[2].replace(',','.'))}
        else:
            m=re.fullmatch(rf'({NUM})\s*(?:{unit})?',text)
            if m: value=float(m[1].replace(',','.'))
            elif code=='sensibilite':
                m=re.fullmatch(rf'({NUM})\s*A',text)
                if m: value=float(Decimal(m[1].replace(',','.'))*1000)
    elif fmt=='boolean':
        value={'oui':True,'non':False}.get(key(text))
    elif fmt in ('choice','set'):
        values={key(v):v for v in a['values']}; values.update(ALIASES.get(code,{}))
        if fmt=='choice': value=values.get(key(text))
        else:
            parts=re.split(r'\s*(?:;|,|\bet\b)\s*',text)
            mapped=[values.get(key(v)) for v in parts]
            if all(mapped): value=sorted(set(mapped))
    else:
        value=text.upper() if code in ('ip','ik') else text
    if not valid_value(code,value,a['unit'],ctx): return None
    return {'code':code,'value':value,'unit':a['unit'],'context':ctx}


def enrich(product):
    product['schema_version']=3
    product.pop('attributes',None); product.pop('attribute_conflicts',None)
    product.setdefault('category_code',None)
    product.setdefault('exceptions',[]); product.setdefault('compatibilities',[])
    product['observations']=[]
    for offer in product['offers']:
        for raw in offer.get('raw_attributes',[]):
            item=proposal(raw['label'],raw['value'])
            if item:
                item.update(supplier=offer['supplier'],raw_label=raw['label'],raw_value=raw['value'],
                    rule_version=RULE_VERSION,status='pending',selected=False,review_note=None)
                product['observations'].append(item)
    ranges={o['range'] for o in product['offers'] if o.get('range')}
    product['range']=next(iter(ranges)) if len(ranges)==1 else None
    # A resumed/re-enriched file never silently preserves an old approval.
    product['review_status']='pending'
    return product


def review_report(product):
    groups={}; covered=set(); suggestions=[]
    for a in product.get('observations',[]):
        covered.add((a['supplier'],a['raw_label'],a['raw_value']))
        if a['status']=='rejected': continue
        value=sorted(a['value']) if ATTRS[a['code']]['format']=='set' else a['value']
        group=(a['code'],json.dumps(a['context'],sort_keys=True))
        groups.setdefault(group,set()).add(json.dumps(value,sort_keys=True))
    family=FAMILIES.get(product.get('category_code'))
    selected={a['code'] for a in product.get('observations',[]) if a['selected'] and a['status']=='validated'}
    selected.update(a['code'] for a in product.get('exceptions',[]))
    applicable=set(family['essential']+family['optional']) if family else set()
    labels={key(f['label']):f['code'] for f in FAMILIES.values()}
    for o in product['offers']:
        for c in o.get('category_path',[])[-1:]:
            if key(c['label']) in labels:
                suggestions.append({'code':labels[key(c['label'])],'supplier':o['supplier'],
                    'source_url':c['url'],'source_label':c['label'],'status':'a_revoir'})
    return {'category_code':product.get('category_code'),'family_suggestions':suggestions,
        'missing_essential':sorted(set(family['essential'])-selected) if family else [],
        'special_requirements':family['special'] if family else [],
        'not_applicable_to_family':sorted({a['code'] for a in product.get('observations',[]) if family and a['code'] not in applicable}),
        'conflicts':[{'code':code,'context':json.loads(ctx)} for (code,ctx),values in groups.items() if len(values)>1],
        'unmapped_raw':[{'supplier':o['supplier'],**r} for o in product['offers'] for r in o.get('raw_attributes',[])
            if (o['supplier'],r['label'],r['value']) not in covered],
        'pending_observations':sum(a['status']=='pending' for a in product.get('observations',[])),
        'publication_checked_by_database':False}


def validate_details(product, approve=False):
    """Called after the existing v2 validator has checked identities and offers."""
    from datetime import datetime, timezone, timedelta
    from urllib.parse import urlsplit
    def require(ok, message):
        if not ok: raise ValueError(message)
    def text(v,lo=1,hi=2000):
        return isinstance(v,str) and lo<=len(v.strip())<=hi and '\x00' not in v
    def url(v):
        if not text(v): return False
        p=urlsplit(v)
        return p.scheme=='https' and bool(p.hostname) and not (p.username or p.password or p.query or p.fragment) and bool(p.path) and not re.search(r'\s',v)
    def context(v):
        return isinstance(v,dict) and len(json.dumps(v,ensure_ascii=False).encode())<=2000
    require(type(product.get('schema_version')) is int and product['schema_version']==3 and set(product)==PRODUCT_KEYS,'Fiche v3 : champs inconnus ou manquants')
    category=product['category_code']; family=FAMILIES.get(category)
    require(category is None or family is not None,'Famille métier inconnue')
    require(not approve or family is not None,'Attribuer une famille finale avant qualification')
    applicable=set(family['essential']+family['optional']) if family else set()
    offers={o['supplier']:o for o in product['offers']}; selected=set(); identities=set()
    for field,limit in [('observations',300),('exceptions',100),('compatibilities',100)]:
        require(isinstance(product.get(field),list) and len(product[field])<=limit,f'{field} : liste trop longue ou invalide')
    for a in product['observations']:
        require(isinstance(a,dict) and set(a)==OBS_KEYS,'Observation : champs inconnus ou manquants')
        require(isinstance(a['code'],str) and context(a['context']) and valid_value(a['code'],a['value'],a['unit'],a['context']),'Observation : valeur, unité ou contexte invalide')
        require(text(a['rule_version'],1,100) and a['status'] in ('pending','validated','rejected') and type(a['selected']) is bool,'Décision de revue invalide')
        require(a['review_note'] is None or text(a['review_note']),'Motif de revue invalide')
        require(a['status']!='rejected' or text(a['review_note'],10),'Rejet sans motif documenté')
        require(not a['selected'] or a['status']=='validated','Sélection sans validation explicite')
        offer=offers.get(a['supplier']); require(offer is not None and {'label':a['raw_label'],'value':a['raw_value']} in offer['raw_attributes'],'Observation sans provenance exacte')
        identity=json.dumps({k:v for k,v in a.items() if k not in ('status','selected','review_note')},sort_keys=True)
        require(identity not in identities,'Observation dupliquée'); identities.add(identity)
        if a['selected']:
            require(not approve or a['code'] in applicable,'Attribut sélectionné non applicable à la famille')
            k=(a['code'],json.dumps(a['context'],sort_keys=True))
            require(k not in selected,'Deux sélections pour le même attribut/contexte'); selected.add(k)
    for a in product['exceptions']:
        require(isinstance(a,dict) and set(a)==EXCEPTION_KEYS,'Exception : champs inconnus ou manquants')
        require(isinstance(a['code'],str) and a['code'] in ATTRS and context(a['context']) and text(a['reason'],10) and url(a['source_url']),'Exception sans motif ou source')
        require(not approve or a['code'] in applicable,'Exception non applicable à la famille')
        k=(a['code'],json.dumps(a['context'],sort_keys=True)); require(k not in selected,'Sélection et exception contradictoires'); selected.add(k)
    for a in product['compatibilities']:
        require(isinstance(a,dict) and set(a)==COMPAT_KEYS,'Compatibilité : champs inconnus ou manquants')
        require(text(a['system'],1,200) and text(a['version'],1,100) and a['role'] in ('compatible_avec','accessoire_pour') and text(a['evidence'],10,4000) and url(a['source_url']),'Compatibilité non documentée')
        require(isinstance(a['observed_at'],str) and bool(re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})',a['observed_at'])),'Date de compatibilité invalide')
        require(datetime.fromisoformat(a['observed_at'].replace('Z','+00:00'))<=datetime.now(timezone.utc)+timedelta(minutes=5),'Compatibilité datée dans le futur')
    return product

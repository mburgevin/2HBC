"""Reproducible Windows/macOS/Linux collector package; standard library only."""
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
ROOT=Path(__file__).resolve().parents[1]
FILES=['scripts/collect_catalogue.py','scripts/prepare_catalogue_import.py',
       'scripts/catalogue_metier.py','catalog/model/referentiel_v1.json',
       'catalog/collector-pilot-urls.txt','docs/COLLECTE_CATALOGUE.md',
       'docs/ETAPE_3_IMPORT_METIER.md']
readme='''2HBC - Collecteur metier 0.5.0

Extraire TOUT le dossier. Python 3.10+ suffit, aucune cle ni connexion fournisseur.
Depuis ce dossier sous Windows :
  py scripts/collect_catalogue.py --version
  py scripts/collect_catalogue.py --limit 100 --max-pages 500 --out catalogue-metier-v050
  py scripts/prepare_catalogue_import.py catalogue-metier-v050/products.json --out preparation.sql --review-out revue.json

Lire docs/COLLECTE_CATALOGUE.md pour la revue, la qualification privee et la
publication explicite. Les scripts ne se connectent jamais a Supabase.
Ne pas approuver automatiquement les observations ni executer de SQL incomplet.
'''
target=ROOT/'releases/collecteur-metier-v0.5.0.zip';target.parent.mkdir(exist_ok=True)
with ZipFile(target,'w',compression=ZIP_DEFLATED,compresslevel=9) as z:
    for name,content in [(f,(ROOT/f).read_bytes()) for f in FILES]+[('LIRE-MOI.txt',readme.encode())]:
        info=ZipInfo(name,date_time=(2026,10,30,0,0,0));info.compress_type=ZIP_DEFLATED;info.external_attr=0o100644<<16
        z.writestr(info,content)
print(target, target.stat().st_size,'bytes')

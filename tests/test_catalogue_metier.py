import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_catalogue_collector import c, product, ROOT
from scripts import catalogue_metier as m
from scripts import prepare_catalogue_import as imp


class BusinessCollectorTests(unittest.TestCase):
    def test_ranges_remain_atomic_and_conductor_terminations_separate(self):
        a=m.proposal('Section conducteur souple avec embout','0,5...2,5 mm²')
        self.assertEqual(a['code'],'section_souple_avec_embout')
        self.assertEqual(a['value'],{'min':0.5,'max':2.5})
        self.assertEqual(a['unit'],'mm²')
        for raw in ['2,5...0,5 mm²','0,5...2,5 A','0,5...2,5','2,5 mm²','≤2,5 mm²']:
            self.assertIsNone(m.proposal('Section conducteur souple avec embout',raw))
        self.assertIsNone(m.proposal('section nominale du conducteur','2,5 mm²'))

    def test_ambiguous_modules_and_unqualified_ip_stay_raw(self):
        for label,value in [('Nombre de modules','3'),('Nombre d’unités','3'),('Indice de protection (IP)','IP55'),('Pouvoir de coupure','6 kA')]:
            self.assertIsNone(m.proposal(label,value))
        self.assertEqual(m.proposal('Indice de protection (IP) avec porte','IP55')['context'],{'assemblage':'avec_porte'})
        self.assertEqual(m.proposal('Largeur en modules DIN','1,5')['value'],1.5)
        self.assertIsNone(m.proposal('Nombre de postes','1,5'))

    def test_exact_norm_voltage_and_sensitivity_conversion(self):
        a=m.proposal('Pouvoir de coupure assigné selon EN 61009 à 400 V (Icn)','6 kA')
        self.assertEqual(a['code'],'icn_61009_400')
        self.assertEqual(a['context'],{'norme':'EN 61009','tension_v':400})
        self.assertEqual(m.proposal('Courant différentiel assigné','0,03 A')['value'],30)
        self.assertEqual(m.proposal('Courant différentiel assigné','0,00003 A')['value'],0.03)
        self.assertIsNone(m.proposal('Courant nominal','10 AX'))
        self.assertEqual(m.proposal('Marquage du calibre','10 AX')['value'],'10 AX')
        self.assertIsNone(m.proposal('Tension nominale','230/400 V'))

    def test_sets_booleans_unknown_vocabulary_and_contexts(self):
        self.assertEqual(m.proposal('Types de conducteurs','souple; massif')['value'],['massif','souple'])
        self.assertEqual(m.proposal('Sans halogène','Non')['value'],False)
        self.assertIsNone(m.proposal('Couleur','nom commercial inconnu'))
        self.assertIsNone(m.proposal('Types de conducteurs','souple; inconnu'))
        self.assertEqual(m.proposal('Configuration des pôles','1P+N')['value'],'1P_N')

    def test_no_source_wins_and_family_suggestions_never_classify(self):
        p=product(); q=product('Sonepar')
        p['offers'][0]['raw_attributes']=[{'label':'Couleur','value':'blanc'}]
        q['offers'][0]['raw_attributes']=[{'label':'Couleur','value':'noir'}]
        p['offers'][0]['category_path']=[{'code':'M2_123','label':'Prises de courant','url':'https://www.rexel.fr/frx/c/M2_123'}]
        c.merge([p],q)
        r=m.review_report(p)
        self.assertEqual(len(p['observations']),2)
        self.assertEqual(r['conflicts'],[{'code':'couleur','context':{}}])
        self.assertEqual(r['family_suggestions'][0]['code'],'prises')
        self.assertIsNone(p['category_code'])
        self.assertTrue(all(a['status']=='pending' and not a['selected'] for a in p['observations']))
        p['category_code']='prises'
        self.assertIn('composition',m.review_report(p)['missing_essential'])

    def test_v3_strict_evidence_decisions_and_separate_publish_flag(self):
        p=product(); p['offers'][0]['raw_attributes']=[{'label':'Couleur','value':'blanc'}]; m.enrich(p)
        imp.validate([p])
        a=p['observations'][0]
        for patch in [{'selected':True},{'value':'inventé'},{'unit':'V'},{'raw_value':'noir'},
                      {'status':'rejected'},{'rule_version':None},{'price':10}]:
            bad=copy.deepcopy(p);bad['observations'][0].update(patch)
            with self.subTest(patch=patch),self.assertRaises((ValueError,TypeError)):imp.validate([bad])
        with self.assertRaises(ValueError):imp.generate_sql([p],False,True)
        p['category_code']='prises';p['review_status']='approved';a.update(status='validated',selected=True)
        self.assertIn('::jsonb, true, false)',imp.generate_sql([p],True))
        self.assertIn('::jsonb, true, true)',imp.generate_sql([p],True,True))
        # Completeness is authoritative in PostgreSQL, not guessed by the CLI.
        self.assertFalse(m.review_report(p)['publication_checked_by_database'])

    def test_non_applicability_and_compatibility_require_documented_proof(self):
        p=product(); p['exceptions']=[{'code':'courant','context':{},'reason':'Non applicable à ce modèle documenté','source_url':'https://fabricant.example/fiche'}]
        imp.validate([p])
        p['compatibilities']=[{'system':'Gamme précise','version':'2026','role':'compatible_avec','source_url':'https://fabricant.example/notice','observed_at':'2026-10-11T12:00:00Z','evidence':'Compatibilité explicitement indiquée'}]
        imp.validate([p])
        for patch in [{'version':None},{'source_url':'https://fabricant.example/notice?token=secret'},{'observed_at':'2099-01-01T00:00:00Z'}]:
            bad=copy.deepcopy(p);bad['compatibilities'][0].update(patch)
            with self.assertRaises(ValueError):imp.validate([bad])

    def test_duplicate_selection_and_cross_product_reference_are_rejected(self):
        p=product();p['offers'][0]['raw_attributes']=[{'label':'Couleur','value':'blanc'}];m.enrich(p)
        p['observations'].append(copy.deepcopy(p['observations'][0]))
        with self.assertRaises(ValueError):imp.validate([p])
        with self.assertRaises(ValueError):imp.validate([product(),product()])

    def test_bundle_runs_after_extracting_outside_the_repository(self):
        from zipfile import ZipFile
        with tempfile.TemporaryDirectory() as tmp:
            with ZipFile(ROOT/'releases/collecteur-metier-v0.5.0.zip') as z:z.extractall(tmp)
            for script,arg in [('collect_catalogue.py','--version'),('prepare_catalogue_import.py','--help')]:
                run=subprocess.run([sys.executable,str(Path(tmp)/'scripts'/script),arg],cwd=tmp,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
            source=ROOT/'catalog/validation/20261016/products-pending.json'
            run=subprocess.run([sys.executable,str(Path(tmp)/'scripts/prepare_catalogue_import.py'),str(source),'--upgrade-out',str(Path(tmp)/'upgraded.json')],cwd=tmp,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertTrue((Path(tmp)/'upgraded.json').exists())

    def test_saved_official_fixtures_upgrade_without_losing_raw_data(self):
        source=ROOT/'catalog/validation/20261016/products-pending.json'
        original=json.loads(source.read_text())
        with tempfile.TemporaryDirectory() as tmp:
            dest=Path(tmp)/'v3.json'
            run=subprocess.run([sys.executable,str(ROOT/'scripts/prepare_catalogue_import.py'),str(source),'--upgrade-out',str(dest)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            converted=json.loads(dest.read_text())
            for before,after in zip(original,converted):
                self.assertEqual(before['offers'],after['offers'])
                self.assertEqual(after['schema_version'],3)
                self.assertEqual(after['review_status'],'pending')
                self.assertIsNone(after['category_code'])
            imp.validate(converted)
            self.assertEqual(json.loads(source.read_text()),original)

if __name__=='__main__':unittest.main()

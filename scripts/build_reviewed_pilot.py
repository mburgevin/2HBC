#!/usr/bin/env python3
"""Rejoue les décisions explicites d'un lot relu, sans réseau ni accès BDD.

Le SHA-256 de la source verrouille la portée de cette revue. Ce script ne
qualifie pas de nouvelles références : chacune exige son manifeste de preuves.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

try:
    from scripts import catalogue_metier as metier
    from scripts.prepare_catalogue_import import validate, generate_sql
except ModuleNotFoundError:
    import catalogue_metier as metier
    from prepare_catalogue_import import validate, generate_sql


def build(source, manifest):
    if hashlib.sha256(source).hexdigest() != manifest['source_sha256']:
        raise ValueError('La source a changé : une nouvelle revue est nécessaire')
    original = validate(json.loads(source))
    decisions = {r['reference']: r for r in manifest['decisions']}
    if len(decisions) != len(original) or set(decisions) != {p['reference'] for p in original}:
        raise ValueError('Le manifeste doit couvrir exactement toutes les références')
    pending, reviewed, report = [], [], []
    for old in original:
        d = decisions[old['reference']]
        if (d['brand'], d['ean']) != (old['brand'], old['ean']):
            raise ValueError('Identité différente de celle relue')
        p = metier.enrich(copy.deepcopy(old))
        p.update(category_code=d['category_code'], exceptions=[], compatibilities=[])
        pending.append(copy.deepcopy(p))
        if d['decision'] == 'publish':
            offers = {o['supplier']: o for o in p['offers']}
            for s in d['selections']:
                offer = offers[s['supplier']]
                # Description capturée, recopiée sans modification pour conserver
                # une paire brute exploitable par le contrat v3 existant.
                if s['origin'] == 'description':
                    if s['raw_value'] != offer['description']:
                        raise ValueError('Description source modifiée')
                    raw = {'label': s['raw_label'], 'value': s['raw_value']}
                    if raw not in offer['raw_attributes']:
                        offer['raw_attributes'].append(raw)
                elif s['origin'] != 'raw_attribute':
                    raise ValueError('Origine de preuve inconnue')
                raw = {'label': s['raw_label'], 'value': s['raw_value']}
                if raw not in offer['raw_attributes']:
                    raise ValueError('Preuve absente de la collecte')
                existing = next((a for a in p['observations'] if
                    all(a[k] == s[k] for k in ('code','value','context','supplier','raw_label','raw_value'))), None)
                if existing is None:
                    existing = {k: copy.deepcopy(s[k]) for k in ('code','value','context','supplier','raw_label','raw_value')}
                    existing.update(unit=metier.ATTRS[s['code']]['unit'], rule_version=manifest['review_version'])
                    p['observations'].append(existing)
                existing.update(status='validated', selected=True, review_note=s['note'])
            for rejection in d['rejections']:
                matches = [a for a in p['observations'] if all(a[k] == rejection[k]
                    for k in ('code','value','supplier','raw_label','raw_value'))]
                if len(matches) != 1 or matches[0]['selected']:
                    raise ValueError('Rejet ambigu ou portant sur une sélection')
                matches[0].update(status='rejected', review_note=rejection['note'])
            p.update(review_status='approved', compatibilities=copy.deepcopy(d['compatibilities']))
            validate([p], True)
            review = metier.review_report(p)
            if review['missing_essential'] or review['conflicts']:
                raise ValueError(f"Revue incomplète pour {p['reference']}: {review}")
            reviewed.append(p)
        elif d['decision'] != 'hold':
            raise ValueError('Décision inconnue')
        report.append({k: d[k] for k in ('brand','reference','ean','category_code','decision','reason')})
    validate(pending)
    validate(reviewed, True)
    return pending, reviewed, report


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('source', type=Path)
    cli.add_argument('manifest', type=Path)
    cli.add_argument('--out', type=Path, required=True)
    args = cli.parse_args()
    pending, reviewed, report = build(args.source.read_bytes(), json.loads(args.manifest.read_text()))
    args.out.mkdir(parents=True, exist_ok=True)
    for name, value in [('products-pending',pending),('products-reviewed',reviewed),('review-report',report)]:
        (args.out / (name+'.json')).write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
    for name, products, approve, publish in [('01-stage',pending,False,False),('02-qualify',reviewed,True,False),('03-publish',reviewed,True,True)]:
        (args.out / (name+'.sql')).write_text(generate_sql(products,approve,publish))
    print(json.dumps({'prepared':len(pending),'publish_candidates':len(reviewed),'held':len(pending)-len(reviewed)}))


if __name__ == '__main__':
    main()

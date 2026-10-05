"""Import all three Stalpi workbook sheets into material layers for OROC."""
import argparse,gzip,json,math,re,sqlite3
from collections import Counter,defaultdict
from pathlib import Path
from zipfile import ZipFile
from lxml import etree as ET

MATERIALS=('Concrete','Composite','Wood','Steel','Necunoscut')
COLORS={'Orange Romania SA':'#ff7900','Orange Communications SA':'#e6007e'}
def owner_color(owner):return COLORS.get(owner,'#22c55e')
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workbook',type=Path)
    parser.add_argument('--dist',type=Path,default=Path(__file__).parent/'dist')
    args=parser.parse_args();args.dist.mkdir(exist_ok=True,parents=True)
    dbpath=Path(__file__).parent/'.sites-runtime/stalpi.sqlite';dbpath.parent.mkdir(exist_ok=True)
    if dbpath.exists():dbpath.unlink()
    db=sqlite3.connect(dbpath);db.execute('PRAGMA journal_mode=OFF');db.execute('PRAGMA synchronous=OFF')
    db.execute('CREATE TABLE points(material TEXT,shard TEXT,payload TEXT)')
    counts=Counter();source=Counter();excluded=Counter();owners=Counter();sheet_counts=Counter();extents={};headers_by_sheet={}
    with ZipFile(args.workbook) as z:
        strings=[]
        if 'xl/sharedStrings.xml' in z.namelist():
            for _,item in ET.iterparse(z.open('xl/sharedStrings.xml'),events=['end'],tag='{*}si'):
                strings.append(''.join(t.text or '' for t in item.findall('.//{*}t')));item.clear()
                while item.getprevious() is not None:del item.getparent()[0]
        sheets=sorted(n for n in z.namelist() if re.fullmatch(r'xl/worksheets/sheet\d+\.xml',n))
        assert len(sheets)==3,f'Expected three sheets, found {len(sheets)}'
        for sheet in sheets:
            for _,row in ET.iterparse(z.open(sheet),events=['end'],tag='{*}row'):
                number=int(row.get('r'));values={}
                for cell in row:
                    v=cell.findtext('{*}v');t=cell.get('t')
                    if t=='s' and v is not None:v=strings[int(v)]
                    elif t=='inlineStr':v=''.join(t.text or '' for t in cell.findall('.//{*}t'))
                    values[re.sub(r'\d+','',cell.get('r'))]=v or ''
                row.clear()
                while row.getprevious() is not None:del row.getparent()[0]
                if number==4:
                    assert values.get('G')=='PNI Material Type' and values.get('I')=='Owner'
                    assert values.get('O')=='Longitude (degrees)' and values.get('P')=='Latitude (degrees)'
                    headers_by_sheet[sheet]=values
                if number<5:continue
                sheet_counts[sheet]+=1;material=values.get('G','').strip() or 'Necunoscut';source[material]+=1
                if material not in MATERIALS:excluded['material:'+material]+=1;continue
                try:
                    lng,lat=float(values['O']),float(values['P'])
                    if not(math.isfinite(lng) and math.isfinite(lat) and -180<=lng<=180 and -90<=lat<=90 and (lng!=0 or lat!=0)):raise ValueError()
                except (KeyError,ValueError,TypeError):excluded['invalid coordinates:'+material]+=1;continue
                owner=values.get('I','').strip();color=owner_color(owner);owners[color]+=1
                props={k:values[c].strip() for c,k in {'E':'n','D':'ID','G':'Material','I':'Owner','F':'Construction Status','H':'Usage','J':'Owner Alias','K':'ORO Alias','L':'Equipment(s)'}.items() if values.get(c)}
                props['_color']=color
                props['Material']=material
                shard=f'{math.floor(lng*10)}_{math.floor(lat*10)}';key=(material,shard)
                b=extents.setdefault(key,[lng,lat,lng,lat]);b[0]=min(b[0],lng);b[1]=min(b[1],lat);b[2]=max(b[2],lng);b[3]=max(b[3],lat)
                db.execute('INSERT INTO points VALUES (?,?,?)',(material,shard,json.dumps([props,[lng,lat]],ensure_ascii=False,separators=(',',':'))));counts[key]+=1
                if sum(sheet_counts.values())%100000==0:db.commit();print(f'Read {sum(sheet_counts.values()):,} rows',flush=True)
            print(f'Completed {sheet}: {sheet_counts[sheet]:,} rows',flush=True)
    db.commit();db.execute('CREATE INDEX by_material_shard ON points(material,shard)');db.commit()
    manifest_path=args.dist/'layers.json';manifest=json.loads(manifest_path.read_text(encoding='utf-8'));layers=[]
    for material in MATERIALS:
        layerid='stalpi-'+material.lower();shards=[]
        for (mat,shard),count in sorted(counts.items()):
            if mat!=material:continue
            filename=f'layers/{layerid}-{shard}.json.gz';path=args.dist/filename;path.parent.mkdir(exist_ok=True)
            payloads=[r[0] for r in db.execute('SELECT payload FROM points WHERE material=? AND shard=?',(material,shard))]
            assert len(payloads)==count
            blob=gzip.compress(('{"p":['+','.join(payloads)+']}').encode(),compresslevel=6,mtime=0);path.write_bytes(blob)
            shards.append({'file':filename,'features':count,'bytes':len(blob),'bounds':extents[(mat,shard)]})
        bounds=[min(s['bounds'][0] for s in shards),min(s['bounds'][1] for s in shards),max(s['bounds'][2] for s in shards),max(s['bounds'][3] for s in shards)] if shards else [0,0,0,0]
        layers.append({'id':layerid,'name':material,'group':'Stalpi','features':sum(s['features'] for s in shards),'sourceFeatures':source[material],'geometryTypes':{'Point':sum(s['features'] for s in shards)},'color':'#22c55e','source':args.workbook.name,'bounds':bounds,'bytes':sum(s['bytes'] for s in shards),'shards':shards})
    manifest['layers']=[l for l in manifest['layers'] if l.get('group')!='Stalpi']+layers
    manifest['totals']['layers']=len(manifest['layers']);manifest['totals']['features']=sum(l['features'] for l in manifest['layers']);manifest['totals']['bytes']=sum(l['bytes'] for l in manifest['layers'])
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    report={'sourceRows':sum(sheet_counts.values()),'sheets':dict(sheet_counts),'materials':dict(source),'imported':{l['name']:l['features'] for l in layers},'colors':dict(owners),'excluded':dict(excluded)}
    assert sum(report['imported'].values())+sum(excluded.values())==report['sourceRows']
    (dbpath.parent/'stalpi-import-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8');db.close();dbpath.unlink()
    print(json.dumps(report),flush=True)
if __name__=='__main__':main()

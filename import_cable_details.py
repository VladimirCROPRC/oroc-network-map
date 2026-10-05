import hashlib, io, json, sqlite3, zipfile, sys
from pathlib import Path
from lxml import etree as ET

ROOT = Path(__file__).resolve().parent
SOURCE = Path(r'C:/Users/VladimirCARLAN/Downloads/Retea/_MergedKMZ/20260930_133523_fcae61b1')
FIELDS = {'proprietar':'pr','status':'st','tip':'tp','tip_structura_capat_a':'ta','id_structura_capat_a':'ia','tip_structura_capat_z':'tz','id_structura_capat_z':'iz','cabluri':'cb'}

def signature(lines):
    normalized = [[[round(float(p[0]),6),round(float(p[1]),6)] for p in line] for line in lines]
    return hashlib.sha256(json.dumps(normalized,separators=(',',':')).encode()).hexdigest()

def kml_files(blob):
    with zipfile.ZipFile(blob) as archive:
        for name in archive.namelist():
            if name.lower().endswith('.kml'): yield archive.read(name)
            elif name.lower().endswith('.kmz'): yield from kml_files(io.BytesIO(archive.read(name)))

db = sqlite3.connect(ROOT/'.sites-runtime/cable-details.sqlite')
if '--reuse' not in sys.argv:
    db.execute('DROP TABLE IF EXISTS cables')
    db.execute('CREATE TABLE cables(network TEXT,name TEXT,signature TEXT,properties TEXT)')
    for network,filename in [('fo-orange','Orange.kmz'),('fo-oroc','OROC.kmz')]:
        count=0
        for content in kml_files(SOURCE/filename):
            root=ET.fromstring(content,ET.XMLParser(recover=True,huge_tree=True))
            styles={e.get('id'): e for e in root.findall('.//{*}Style') if e.get('id')}
            maps={e.get('id'):e for e in root.findall('.//{*}StyleMap') if e.get('id')}
            for placemark in root.findall('.//{*}Placemark'):
                line_elements=placemark.findall('.//{*}LineString/{*}coordinates')
                if not line_elements: continue
                name=placemark.findtext('{*}name','').strip()
                lines=[[[float(v) for v in coord.split(',')[:2]] for coord in (e.text or '').split()] for e in line_elements]
                values={e.get('name'):e.findtext('{*}value','') for e in placemark.findall('.//{*}Data')}
                values.update({e.get('name'):e.text or '' for e in placemark.findall('.//{*}SimpleData')})
                properties={short:values.get(long,'') for long,short in FIELDS.items()}
                color=placemark.findtext('{*}Style/{*}LineStyle/{*}color')
                if not color:
                    style_id=placemark.findtext('{*}styleUrl','').split('#')[-1]
                    if style_id in maps:
                        pair=next((p for p in maps[style_id].findall('{*}Pair') if p.findtext('{*}key')=='normal'),None)
                        if pair is not None:style_id=pair.findtext('{*}styleUrl','').split('#')[-1]
                    if style_id in styles:color=styles[style_id].findtext('{*}LineStyle/{*}color')
                if color and len(color.strip())==8:
                    c=color.strip();properties['_color']='#'+c[6:8]+c[4:6]+c[2:4];properties['_opacity']=int(c[:2],16)/255
                db.execute('INSERT INTO cables VALUES(?,?,?,?)',(network,name,signature(lines),json.dumps(properties,ensure_ascii=False,separators=(',',':'))))
                count+=1
        db.commit();print(network,'KMZ lines:',count,flush=True)
    db.execute('CREATE INDEX cable_lookup ON cables(network,name,signature)');db.commit()
prepared=[]
for directory in [ROOT/'dist',ROOT/'.sites-runtime/oro-source/dist']:
    manifest=json.loads((directory/'layers.json').read_text(encoding='utf-8'))
    stats={'matched':0,'missing':0,'colors_changed':0}
    for layer in manifest['layers']:
        if not layer['id'].startswith('fo-'):continue
        for shard in layer.get('shards',[layer]):
            filename=directory/shard['file'];data=json.loads(filename.read_text(encoding='utf-8'))
            for item in data.get('c',[]):
                properties,coords=item[:2];lines=coords if len(item)>2 and item[2] else [coords]
                matches=db.execute('SELECT DISTINCT properties FROM cables WHERE network=? AND name=? AND signature=?',(layer['id'],properties.get('n',''),signature(lines))).fetchall()
                if not matches:matches=db.execute('SELECT DISTINCT properties FROM cables WHERE network=? AND name=?',(layer['id'],properties.get('n',''))).fetchall()
                if len(matches)>1:
                    same_color=[m for m in matches if json.loads(m[0]).get('_color','').lower()==properties.get('_color','').lower()]
                    if same_color:matches=same_color
                if len(matches)>1:
                    scores=[sum(properties.get(k)==v for k,v in json.loads(m[0]).items() if not k.startswith('_') and k in properties) for m in matches]
                    best=max(scores)
                    matches=[m for m,score in zip(matches,scores) if score==best]
                if len(matches)!=1:
                    stats['missing']+=1
                    if stats['missing']<=3:print('Unmatched:',layer['id'],properties.get('n'),len(matches),flush=True)
                    continue
                imported=json.loads(matches[0][0]);stats['colors_changed']+=imported.get('_color',properties.get('_color','')).lower()!=properties.get('_color','').lower()
                properties.update(imported);stats['matched']+=1
            output=json.dumps(data,ensure_ascii=False,separators=(',',':')).encode()
            prepared.append((filename,output));shard['bytes']=len(output)
        layer['bytes']=sum(s.get('bytes',0) for s in layer.get('shards',[])) or layer.get('bytes',0)
    print(str(directory),stats,flush=True)
    if stats['missing']:raise RuntimeError('Unmatched cables; original data has not been modified')
    prepared.append((directory/'layers.json',json.dumps(manifest,ensure_ascii=False,separators=(',',':')).encode()))
for filename,output in prepared:filename.write_bytes(output)
print('All cable attributes imported; original KMZ line styles applied.',flush=True)

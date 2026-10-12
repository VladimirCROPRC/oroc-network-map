param(
  [Parameter(Mandatory=$true)][string]$KmzPath,
  [string]$AppRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$layerDir = Join-Path $AppRoot 'dist\layers'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($KmzPath)
try {
  $entry = $zip.GetEntry('doc.kml')
  if (-not $entry) { throw 'KMZ does not contain doc.kml' }
  $reader = [IO.StreamReader]::new($entry.Open())
  try { [xml]$kml = $reader.ReadToEnd() } finally { $reader.Dispose() }
} finally { $zip.Dispose() }

$ns = [Xml.XmlNamespaceManager]::new($kml.NameTable)
$ns.AddNamespace('k','http://www.opengis.net/kml/2.2')
$backbone = $kml.SelectSingleNode('//k:Folder[k:name="BACKBONE FO TKR"]',$ns)
if (-not $backbone) { throw 'BACKBONE FO TKR folder not found' }

function Read-CoordinateTuples([string]$text) {
  $tuples = [Collections.Generic.List[object]]::new()
  foreach ($tuple in [regex]::Split($text.Trim(), '\s+')) {
    if ([string]::IsNullOrWhiteSpace($tuple)) { continue }
    $parts = $tuple.Split(',')
    if ($parts.Length -lt 2) { continue }
    $lon = [double]::Parse($parts[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
    $lat = [double]::Parse($parts[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
    $tuples.Add(@($lon,$lat))
  }
  return ,$tuples.ToArray()
}

$cables = [Collections.Generic.List[object]]::new()
$pops = [Collections.Generic.List[object]]::new()
$allX = [Collections.Generic.List[double]]::new()
$allY = [Collections.Generic.List[double]]::new()
$cableIndex = 0
$popIndex = 0
foreach ($placemark in $backbone.SelectNodes('.//k:Placemark',$ns)) {
  $nameNode = $placemark.SelectSingleNode('k:name',$ns)
  $name = if ($nameNode) { $nameNode.InnerText.Trim() } else { 'Fără nume' }
  $folderNode = $placemark.ParentNode.SelectSingleNode('k:name',$ns)
  $route = if ($folderNode) { $folderNode.InnerText.Trim() } else { '' }

  foreach ($line in $placemark.SelectNodes('.//k:LineString/k:coordinates',$ns)) {
    $coordinates = Read-CoordinateTuples $line.InnerText
    if ($coordinates.Count -lt 2) { continue }
    foreach ($pair in $coordinates) { $allX.Add([double]$pair[0]); $allY.Add([double]$pair[1]) }
    $cableIndex++
    $cables.Add([ordered]@{
      type='Feature'; id="backbone-cable-$cableIndex"
      properties=[ordered]@{ n=$name; route=$route }
      geometry=[ordered]@{ type='LineString'; coordinates=$coordinates }
    })
  }

  if ($name -match '(?i)\bPOP\b') {
    foreach ($point in $placemark.SelectNodes('.//k:Point/k:coordinates',$ns)) {
      $coordinates = Read-CoordinateTuples $point.InnerText
      if ($coordinates.Count -lt 1) { continue }
      $coordinate = $coordinates[0]
      $allX.Add([double]$coordinate[0]); $allY.Add([double]$coordinate[1])
      $popIndex++
      $pops.Add([ordered]@{
        type='Feature'; id="backbone-pop-$popIndex"
        properties=[ordered]@{ n=$name; route=$route }
        geometry=[ordered]@{ type='Point'; coordinates=$coordinate }
      })
    }
  }
}
if ($cables.Count -eq 0 -or $pops.Count -eq 0) {
  throw "Unexpected extraction counts: cables=$($cables.Count), POPs=$($pops.Count)"
}

$cablePath = Join-Path $layerDir 'magistrale-backbone-cables.geojson'
$popPath = Join-Path $layerDir 'magistrale-backbone-pops.geojson'
$cableJson = [ordered]@{ type='FeatureCollection'; name='Cabluri Backbone'; features=$cables.ToArray() } | ConvertTo-Json -Depth 100 -Compress
$popJson = [ordered]@{ type='FeatureCollection'; name='POP-uri Backbone'; features=$pops.ToArray() } | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText($cablePath, $cableJson, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($popPath, $popJson, [Text.UTF8Encoding]::new($false))

$bounds = @(
  ($allX | Measure-Object -Minimum).Minimum,
  ($allY | Measure-Object -Minimum).Minimum,
  ($allX | Measure-Object -Maximum).Maximum,
  ($allY | Measure-Object -Maximum).Maximum
)
$manifestPath = Join-Path $AppRoot 'dist\layers.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$previousImported = @($manifest.layers | Where-Object { $_.id -in @('magistrale-backbone-cables','magistrale-backbone-pops') })
$previousFeatures = 0
$previousBytes = 0L
foreach ($layer in $previousImported) {
  $previousFeatures += [int]$layer.features
  $previousBytes += [long]$layer.bytes
}
$baseFeatureCount = [int]$manifest.totals.features - $previousFeatures
$baseByteCount = [long]$manifest.totals.bytes - $previousBytes
$manifest.layers = @($manifest.layers | Where-Object { $_.id -notin @('magistrale-backbone-cables','magistrale-backbone-pops') })
$cableBytes = (Get-Item $cablePath).Length
$popBytes = (Get-Item $popPath).Length
$manifest.layers += @(
  [ordered]@{
    id='magistrale-backbone-cables'; name='Cabluri Backbone'; group='Magistrale'; subgroup='Backbone'
    features=$cables.Count; source=[IO.Path]::GetFileName($KmzPath)
    geometryTypes=[ordered]@{ LineString=$cables.Count }; bytes=$cableBytes; bounds=$bounds
    color='#e879f9'; file='layers/magistrale-backbone-cables.geojson'; defaultActive=$false
  },
  [ordered]@{
    id='magistrale-backbone-pops'; name='POP-uri Backbone'; group='Magistrale'; subgroup='Backbone'
    features=$pops.Count; source=[IO.Path]::GetFileName($KmzPath)
    geometryTypes=[ordered]@{ Point=$pops.Count }; bytes=$popBytes; bounds=$bounds
    color='#fb923c'; file='layers/magistrale-backbone-pops.geojson'; defaultActive=$true
  }
)
$manifest['totals']['layers'] = $manifest.layers.Count
$manifest['totals']['features'] = $baseFeatureCount + $cables.Count + $pops.Count
$manifest['totals']['bytes'] = $baseByteCount + $cableBytes + $popBytes
$manifest | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $manifestPath -Encoding utf8

Write-Output "Cables: $($cables.Count), $cableBytes bytes"
Write-Output "POP points: $($pops.Count), $popBytes bytes"
Write-Output ('Bounds: ' + ($bounds -join ', '))


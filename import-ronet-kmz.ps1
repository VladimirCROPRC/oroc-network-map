param(
  [Parameter(Mandatory=$true)][string]$KmzPath,
  [string]$AppRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$layerDir = Join-Path $AppRoot 'dist\layers'
$zip = [IO.Compression.ZipFile]::OpenRead($KmzPath)
try {
  $entry = $zip.GetEntry('doc.kml')
  if (-not $entry) { throw 'KMZ does not contain doc.kml' }
  $reader = [IO.StreamReader]::new($entry.Open())
  try { [xml]$kml = $reader.ReadToEnd() } finally { $reader.Dispose() }
} finally { $zip.Dispose() }

$ns = [Xml.XmlNamespaceManager]::new($kml.NameTable)
$ns.AddNamespace('k','http://www.opengis.net/kml/2.2')
$root = $kml.SelectSingleNode('//k:Folder[k:name="Ronet"]',$ns)
if (-not $root) { throw 'Ronet folder not found' }

function Convert-KmlColor([string]$value) {
  if ($value -notmatch '^(?<a>[0-9a-fA-F]{2})(?<b>[0-9a-fA-F]{2})(?<g>[0-9a-fA-F]{2})(?<r>[0-9a-fA-F]{2})$') { return $null }
  return [ordered]@{
    color = ('#' + $Matches.r + $Matches.g + $Matches.b).ToLowerInvariant()
    opacity = [math]::Round(([Convert]::ToInt32($Matches.a,16) / 255),3)
  }
}

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

$styles = @{}
$iconPaths = @{}
$iconZip = [IO.Compression.ZipFile]::OpenRead($KmzPath)
try {
foreach ($style in $kml.SelectNodes('//k:Style',$ns)) {
  $item = [ordered]@{}
  $lineColor = $style.SelectSingleNode('k:LineStyle/k:color',$ns)
  if ($lineColor) { $item.line = Convert-KmlColor $lineColor.InnerText }
  $iconHref = $style.SelectSingleNode('k:IconStyle/k:Icon/k:href',$ns)
  if ($iconHref) {
    $iconName = 'ronet-' + $style.GetAttribute('id').ToLowerInvariant() + '.png'
    $iconPath = Join-Path $layerDir $iconName
    $assetEntry = $iconZip.GetEntry($iconHref.InnerText.Trim())
    if ($assetEntry) {
      [IO.Compression.ZipFileExtensions]::ExtractToFile($assetEntry,$iconPath,$true)
      $iconPaths[$style.GetAttribute('id')] = 'layers/' + $iconName
      $item.icon = $iconPaths[$style.GetAttribute('id')]
    }
  }
  $styles[$style.GetAttribute('id')] = $item
}
} finally { $iconZip.Dispose() }

$features = [Collections.Generic.List[object]]::new()
$allX = [Collections.Generic.List[double]]::new()
$allY = [Collections.Generic.List[double]]::new()
$geometryTypes = @{}
$featureIndex = 0
foreach ($placemark in $root.SelectNodes('.//k:Placemark',$ns)) {
  $nameNode = $placemark.SelectSingleNode('k:name',$ns)
  $name = if ($nameNode) { $nameNode.InnerText.Trim() } else { 'Fără nume' }
  $folderNode = $placemark.ParentNode.SelectSingleNode('k:name',$ns)
  $folder = if ($folderNode) { $folderNode.InnerText.Trim() } else { 'Ronet' }
  $styleNode = $placemark.SelectSingleNode('k:styleUrl',$ns)
  $styleId = if ($styleNode) { $styleNode.InnerText.Trim().TrimStart('#') } else { '' }
  $style = $styles[$styleId]
  $properties = [ordered]@{ n=$name; folder=$folder }
  if ($style.line) {
    $properties._color = $style.line.color
    if ($style.line.opacity -lt 1) { $properties._opacity = $style.line.opacity }
  }

  $lines = [Collections.Generic.List[object]]::new()
  foreach ($line in $placemark.SelectNodes('.//k:LineString/k:coordinates',$ns)) {
    $coordinates = Read-CoordinateTuples $line.InnerText
    if ($coordinates.Count -ge 2) {
      foreach ($pair in $coordinates) { $allX.Add([double]$pair[0]); $allY.Add([double]$pair[1]) }
      $lines.Add($coordinates)
    }
  }
  if ($lines.Count) {
    $featureIndex++
    $geometry = if ($lines.Count -eq 1) {
      [ordered]@{ type='LineString'; coordinates=$lines[0] }
    } else {
      [ordered]@{ type='MultiLineString'; coordinates=$lines.ToArray() }
    }
    $geometryTypes[$geometry.type] = 1 + ($geometryTypes[$geometry.type] ?? 0)
    $features.Add([ordered]@{ type='Feature'; id="ronet-$featureIndex"; properties=$properties; geometry=$geometry })
    continue
  }

  foreach ($point in $placemark.SelectNodes('.//k:Point/k:coordinates',$ns)) {
    $coordinates = Read-CoordinateTuples $point.InnerText
    if (-not $coordinates.Count) { continue }
    $coordinate = $coordinates[0]
    foreach ($pair in $coordinates) { $allX.Add([double]$pair[0]); $allY.Add([double]$pair[1]) }
    $pointProperties = [ordered]@{ n=$name; folder=$folder }
    if ($style.icon) { $pointProperties._icon = $style.icon }
    $featureIndex++
    $geometryTypes['Point'] = 1 + ($geometryTypes['Point'] ?? 0)
    $features.Add([ordered]@{ type='Feature'; id="ronet-$featureIndex"; properties=$pointProperties; geometry=[ordered]@{ type='Point'; coordinates=$coordinate } })
  }
}
if (-not $features.Count) { throw 'No supported placemarks found in Ronet folder' }

$geoPath = Join-Path $layerDir 'ronet.geojson'
$geoJson = [ordered]@{ type='FeatureCollection'; name='Ronet'; features=$features.ToArray() } | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText($geoPath,$geoJson,[Text.UTF8Encoding]::new($false))

$bounds = @(
  ($allX | Measure-Object -Minimum).Minimum,
  ($allY | Measure-Object -Minimum).Minimum,
  ($allX | Measure-Object -Maximum).Maximum,
  ($allY | Measure-Object -Maximum).Maximum
)
$gzipPath = Join-Path $layerDir 'ronet.geojson.gz'
& node -e 'const fs=require("fs"),z=require("zlib");fs.writeFileSync(process.argv[1],z.gzipSync(fs.readFileSync(process.argv[2]),{level:9}))' $gzipPath $geoPath
if ($LASTEXITCODE -ne 0) { throw 'Could not compress Ronet GeoJSON' }
Remove-Item -LiteralPath $geoPath

$manifestPath = Join-Path $AppRoot 'dist\layers.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$previous = @($manifest.layers | Where-Object { $_.id -eq 'fo-ronet' })
$baseFeatures = [int]$manifest.totals.features
$baseBytes = [long]$manifest.totals.bytes
foreach ($layer in $previous) { $baseFeatures -= [int]$layer.features; $baseBytes -= [long]$layer.bytes }
$manifest.layers = @($manifest.layers | Where-Object { $_.id -ne 'fo-ronet' })
$fileBytes = (Get-Item $gzipPath).Length
$manifest.layers += [ordered]@{
  id='fo-ronet'; name='Ronet'; group='FO Cables'; features=$features.Count
  source=[IO.Path]::GetFileName($KmzPath); geometryTypes=$geometryTypes; bytes=$fileBytes
  bounds=$bounds; color='#ffffff'; file='layers/ronet.geojson.gz'; defaultActive=$false
}
$manifest.totals.layers = $manifest.layers.Count
$manifest.totals.features = $baseFeatures + $features.Count
$manifest.totals.bytes = $baseBytes + $fileBytes
$manifest | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $manifestPath -Encoding utf8

Write-Output "Features: $($features.Count)"
Write-Output "Geometry types: $(ConvertTo-Json -InputObject $geometryTypes -Compress)"
Write-Output "Original line colors preserved per feature; $($iconPaths.Count) KML icons extracted"
Write-Output "Bounds: $($bounds -join ', ')"
Write-Output "Compressed GeoJSON: $fileBytes bytes"

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

$cableFeatures = [Collections.Generic.List[object]]::new()
$piFeatures = [Collections.Generic.List[object]]::new()
$pablFeatures = [Collections.Generic.List[object]]::new()
$cableX = [Collections.Generic.List[double]]::new(); $cableY = [Collections.Generic.List[double]]::new()
$piX = [Collections.Generic.List[double]]::new(); $piY = [Collections.Generic.List[double]]::new()
$pablX = [Collections.Generic.List[double]]::new(); $pablY = [Collections.Generic.List[double]]::new()
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
      foreach ($pair in $coordinates) { $cableX.Add([double]$pair[0]); $cableY.Add([double]$pair[1]) }
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
    $cableFeatures.Add([ordered]@{ type='Feature'; id="ronet-cable-$featureIndex"; properties=$properties; geometry=$geometry })
    continue
  }

  foreach ($point in $placemark.SelectNodes('.//k:Point/k:coordinates',$ns)) {
    $coordinates = Read-CoordinateTuples $point.InnerText
    if (-not $coordinates.Count) { continue }
    $coordinate = $coordinates[0]
    $targetFeatures = $null; $targetX = $null; $targetY = $null
    if ($folder -like 'PI_PT*') { $targetFeatures=$piFeatures; $targetX=$piX; $targetY=$piY }
    elseif ($folder -like 'PABL_PT*') { $targetFeatures=$pablFeatures; $targetX=$pablX; $targetY=$pablY }
    else { throw "Unrecognized Ronet point folder: $folder" }
    foreach ($pair in $coordinates) { $targetX.Add([double]$pair[0]); $targetY.Add([double]$pair[1]) }
    $pointProperties = [ordered]@{ n=$name; folder=$folder }
    if ($style.icon) { $pointProperties._icon = $style.icon }
    $featureIndex++
    $targetFeatures.Add([ordered]@{ type='Feature'; id="ronet-point-$featureIndex"; properties=$pointProperties; geometry=[ordered]@{ type='Point'; coordinates=$coordinate } })
  }
}
if (-not $cableFeatures.Count -or -not $piFeatures.Count -or -not $pablFeatures.Count) { throw 'One or more Ronet layers are empty' }

function Get-Bounds($xs,$ys) {
  return @(($xs | Measure-Object -Minimum).Minimum,($ys | Measure-Object -Minimum).Minimum,($xs | Measure-Object -Maximum).Maximum,($ys | Measure-Object -Maximum).Maximum)
}
function Write-GzipLayer([string]$stem,[string]$name,[object[]]$items) {
  $jsonPath = Join-Path $layerDir ($stem + '.geojson')
  $gzipPath = Join-Path $layerDir ($stem + '.geojson.gz')
  $json = [ordered]@{ type='FeatureCollection'; name=$name; features=$items } | ConvertTo-Json -Depth 100 -Compress
  [IO.File]::WriteAllText($jsonPath,$json,[Text.UTF8Encoding]::new($false))
  & node -e 'const fs=require("fs"),z=require("zlib");fs.writeFileSync(process.argv[1],z.gzipSync(fs.readFileSync(process.argv[2]),{level:9}))' $gzipPath $jsonPath
  if ($LASTEXITCODE -ne 0) { throw "Could not compress $name GeoJSON" }
  Remove-Item -LiteralPath $jsonPath
  return [pscustomobject]@{ file=('layers/' + $stem + '.geojson.gz'); path=$gzipPath; bytes=(Get-Item $gzipPath).Length }
}
$cablesFile = Write-GzipLayer 'ronet-cables' 'RONET Cables' $cableFeatures.ToArray()
$piFile = Write-GzipLayer 'ronet-pi' 'PI' $piFeatures.ToArray()
$pablFile = Write-GzipLayer 'ronet-pabl' 'PABL' $pablFeatures.ToArray()
$cablesBounds = Get-Bounds $cableX $cableY
$piBounds = Get-Bounds $piX $piY
$pablBounds = Get-Bounds $pablX $pablY

$manifestPath = Join-Path $AppRoot 'dist\layers.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$ronetIds = @('fo-ronet','fo-ronet-cables','fo-ronet-pi','fo-ronet-pabl')
$previous = @($manifest.layers | Where-Object { $_.id -in $ronetIds })
$baseFeatures = [int]$manifest.totals.features
$baseBytes = [long]$manifest.totals.bytes
foreach ($layer in $previous) { $baseFeatures -= [int]$layer.features; $baseBytes -= [long]$layer.bytes }
$manifest.layers = @($manifest.layers | Where-Object { $_.id -notin $ronetIds })
$oldCombined = Join-Path $layerDir 'ronet.geojson.gz'
if (Test-Path -LiteralPath $oldCombined) { Remove-Item -LiteralPath $oldCombined }
$manifest.layers += @(
  [ordered]@{ id='fo-ronet-cables'; name='RONET Cables'; group='FO Cables'; features=$cableFeatures.Count; source=[IO.Path]::GetFileName($KmzPath); geometryTypes=[ordered]@{ LineString=$cableFeatures.Count }; bytes=$cablesFile.bytes; bounds=$cablesBounds; color='#ffffff'; file=$cablesFile.file; defaultActive=$false },
  [ordered]@{ id='fo-ronet-pi'; name='PI'; group='FO Cables'; features=$piFeatures.Count; source=[IO.Path]::GetFileName($KmzPath); geometryTypes=[ordered]@{ Point=$piFeatures.Count }; bytes=$piFile.bytes; bounds=$piBounds; color='#00ff00'; file=$piFile.file; defaultActive=$false },
  [ordered]@{ id='fo-ronet-pabl'; name='PABL'; group='FO Cables'; features=$pablFeatures.Count; source=[IO.Path]::GetFileName($KmzPath); geometryTypes=[ordered]@{ Point=$pablFeatures.Count }; bytes=$pablFile.bytes; bounds=$pablBounds; color='#0000ff'; file=$pablFile.file; defaultActive=$false }
)
$manifest.totals.layers = $manifest.layers.Count
$manifest.totals.features = $baseFeatures + $cableFeatures.Count + $piFeatures.Count + $pablFeatures.Count
$manifest.totals.bytes = $baseBytes + $cablesFile.bytes + $piFile.bytes + $pablFile.bytes
$manifest | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $manifestPath -Encoding utf8

Write-Output "RONET Cables: $($cableFeatures.Count) features, $($cablesFile.bytes) compressed bytes; bounds $($cablesBounds -join ', ')"
Write-Output "PI triangles: $($piFeatures.Count) features, $($piFile.bytes) compressed bytes; bounds $($piBounds -join ', ')"
Write-Output "PABL squares: $($pablFeatures.Count) features, $($pablFile.bytes) compressed bytes; bounds $($pablBounds -join ', ')"
Write-Output "Original KML colors and both point icons preserved"

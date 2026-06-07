[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(Position = 0)]
	[ValidateSet("install", "uninstall", "find")]
	[string] $Action = "install",

	[string] $GameDir,

	[switch] $IncludeNatives,

	[switch] $Force
)

$ErrorActionPreference = "Stop"

$ModName = "EMV-Engine-SILVER-BulletS"
$WildsAppId = "2246340"
$WildsExe = "MonsterHunterWilds.exe"
$ManifestRelativePath = "reframework\data\$ModName.install-manifest.json"
$BackupRootRelativePath = "reframework\data\$ModName.backups"
$SourceRoot = $PSScriptRoot

$PluginDirectories = @(
	"EMV Engine",
	"Enhanced Model Viewer",
	"RE Engine Resource Editor",
	"Gravity Gun",
	"Console",
	"Hooked Method Inspector",
	"Wilds Motion Viewer",
	"Enemy Spawner"
)

function Join-NormalizedPath {
	param([string] $Base, [string] $Child)
	return [System.IO.Path]::GetFullPath((Join-Path -Path $Base -ChildPath $Child))
}

function Get-RelativePath {
	param([string] $Base, [string] $Path)
	$baseUri = [System.Uri]::new((Join-NormalizedPath $Base ".") + [System.IO.Path]::DirectorySeparatorChar)
	$pathUri = [System.Uri]::new((Join-NormalizedPath (Split-Path -Parent $Path) (Split-Path -Leaf $Path)))
	return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace("/", "\")
}

function Get-FileSha256 {
	param([string] $Path)
	if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Convert-VdfStringValue {
	param([string] $Line, [string] $Key)
	if ($Line -match ('^\s*"' + [regex]::Escape($Key) + '"\s+"(.+)"\s*$')) {
		return $Matches[1].Replace("\\", "\")
	}
	return $null
}

function Get-SteamRoots {
	$roots = [System.Collections.Generic.List[string]]::new()
	$registryPaths = @(
		"HKCU:\Software\Valve\Steam",
		"HKLM:\Software\Valve\Steam",
		"HKLM:\Software\WOW6432Node\Valve\Steam"
	)

	foreach ($registryPath in $registryPaths) {
		try {
			$item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
			foreach ($valueName in @("SteamPath", "InstallPath")) {
				$value = $item.$valueName
				if ($value -and (Test-Path -LiteralPath $value -PathType Container)) {
					$roots.Add((Join-NormalizedPath $value "."))
				}
			}
		} catch {}
	}

	return $roots | Select-Object -Unique
}

function Get-SteamLibraries {
	$libraries = [System.Collections.Generic.List[string]]::new()

	foreach ($steamRoot in Get-SteamRoots) {
		$libraries.Add($steamRoot)
		$libraryFile = Join-Path -Path $steamRoot -ChildPath "steamapps\libraryfolders.vdf"
		if (!(Test-Path -LiteralPath $libraryFile -PathType Leaf)) { continue }

		foreach ($line in Get-Content -LiteralPath $libraryFile -Encoding UTF8) {
			$path = Convert-VdfStringValue -Line $line -Key "path"
			if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
				$libraries.Add((Join-NormalizedPath $path "."))
			}
		}
	}

	return $libraries | Select-Object -Unique
}

function Find-MHWildsGameDir {
	$candidates = [System.Collections.Generic.List[string]]::new()

	foreach ($library in Get-SteamLibraries) {
		$steamApps = Join-Path -Path $library -ChildPath "steamapps"
		if (!(Test-Path -LiteralPath $steamApps -PathType Container)) { continue }

		$knownManifest = Join-Path -Path $steamApps -ChildPath "appmanifest_$WildsAppId.acf"
		$manifests = @()
		if (Test-Path -LiteralPath $knownManifest -PathType Leaf) {
			$manifests += Get-Item -LiteralPath $knownManifest
		}
		$manifests += Get-ChildItem -LiteralPath $steamApps -Filter "appmanifest_*.acf" -File -ErrorAction SilentlyContinue

		foreach ($manifest in ($manifests | Sort-Object FullName -Unique)) {
			$content = Get-Content -LiteralPath $manifest.FullName -Encoding UTF8
			$appId = $null
			$name = $null
			$installDir = $null
			foreach ($line in $content) {
				if (!$appId) { $appId = Convert-VdfStringValue -Line $line -Key "appid" }
				if (!$name) { $name = Convert-VdfStringValue -Line $line -Key "name" }
				if (!$installDir) { $installDir = Convert-VdfStringValue -Line $line -Key "installdir" }
			}

			if ($appId -eq $WildsAppId -or $name -like "*Monster Hunter Wilds*") {
				$dir = Join-Path -Path $steamApps -ChildPath "common\$installDir"
				$exe = Join-Path -Path $dir -ChildPath $WildsExe
				if (Test-Path -LiteralPath $exe -PathType Leaf) {
					$candidates.Add((Join-NormalizedPath $dir "."))
				}
			}
		}

		foreach ($fallbackName in @("MonsterHunterWilds", "Monster Hunter Wilds")) {
			$dir = Join-Path -Path $steamApps -ChildPath "common\$fallbackName"
			$exe = Join-Path -Path $dir -ChildPath $WildsExe
			if (Test-Path -LiteralPath $exe -PathType Leaf) {
				$candidates.Add((Join-NormalizedPath $dir "."))
			}
		}
	}

	return $candidates | Select-Object -Unique
}

function Resolve-GameDir {
	param([string] $ExplicitGameDir)
	if ($ExplicitGameDir) {
		$resolved = Join-NormalizedPath $ExplicitGameDir "."
		$exe = Join-Path -Path $resolved -ChildPath $WildsExe
		if (!(Test-Path -LiteralPath $exe -PathType Leaf)) {
			throw "The specified directory is not a Monster Hunter Wilds game directory. Missing ${WildsExe}: $resolved"
		}
		return $resolved
	}

	$matches = @(Find-MHWildsGameDir)
	if ($matches.Count -eq 0) {
		throw "Monster Hunter Wilds was not found through Steam. Use -GameDir to specify the game directory."
	}
	if ($matches.Count -gt 1) {
		throw "Multiple Monster Hunter Wilds directories were found. Use -GameDir to pick one:`n$($matches -join "`n")"
	}
	return $matches[0]
}

function Get-InstallSources {
	$sources = [System.Collections.Generic.List[object]]::new()

	foreach ($plugin in $PluginDirectories) {
		$pluginRoot = Join-Path -Path $SourceRoot -ChildPath $plugin
		if (!(Test-Path -LiteralPath $pluginRoot -PathType Container)) { continue }

		foreach ($top in @("reframework", "natives")) {
			if ($top -eq "natives" -and !$IncludeNatives) { continue }
			$sourceTop = Join-Path -Path $pluginRoot -ChildPath $top
			if (!(Test-Path -LiteralPath $sourceTop -PathType Container)) { continue }

			Get-ChildItem -LiteralPath $sourceTop -File -Recurse | ForEach-Object {
				$relative = Get-RelativePath -Base $pluginRoot -Path $_.FullName
				$sources.Add([pscustomobject]@{
					Plugin = $plugin
					SourcePath = $_.FullName
					RelativePath = $relative
				})
			}
		}
	}

	return $sources
}

function Read-Manifest {
	param([string] $ManifestPath)
	if (!(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $null }
	return Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Manifest {
	param([string] $ManifestPath, [object] $Manifest)
	$dir = Split-Path -Parent $ManifestPath
	if (!(Test-Path -LiteralPath $dir -PathType Container)) {
		New-Item -ItemType Directory -Force -Path $dir | Out-Null
	}
	$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

function Install-Mod {
	$targetRoot = Resolve-GameDir -ExplicitGameDir $GameDir
	$sources = @(Get-InstallSources)
	if ($sources.Count -eq 0) { throw "No installable files were found." }

	$manifestPath = Join-Path -Path $targetRoot -ChildPath $ManifestRelativePath
	$previousManifest = Read-Manifest -ManifestPath $manifestPath
	$backupRoot = Join-Path -Path $targetRoot -ChildPath $BackupRootRelativePath
	$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
	$backupSession = Join-Path -Path $backupRoot -ChildPath $timestamp
	$records = [System.Collections.Generic.List[object]]::new()
	$newRelativePaths = @{}
	foreach ($source in $sources) {
		$newRelativePaths[$source.RelativePath.ToLowerInvariant()] = $true
	}

	if ($previousManifest) {
		foreach ($record in @($previousManifest.files | Sort-Object relativePath -Descending)) {
			$key = [string]$record.relativePath
			if ($newRelativePaths.ContainsKey($key.ToLowerInvariant())) { continue }
			$dest = Join-Path -Path $targetRoot -ChildPath $record.relativePath
			if (!(Test-Path -LiteralPath $dest -PathType Leaf)) { continue }
			$currentHash = Get-FileSha256 -Path $dest
			if ($currentHash -eq $record.installedHash) {
				if ($PSCmdlet.ShouldProcess($dest, "remove stale installed file")) {
					Remove-Item -LiteralPath $dest -Force
					Remove-EmptyParents -Path $dest -StopAt $targetRoot
				}
			}
		}
	}

	foreach ($source in $sources) {
		$dest = Join-Path -Path $targetRoot -ChildPath $source.RelativePath
		$destDir = Split-Path -Parent $dest
		$sourceHash = Get-FileSha256 -Path $source.SourcePath
		$existingHash = Get-FileSha256 -Path $dest
		$backupRelative = $null
		$alreadyCurrent = $existingHash -and $existingHash -eq $sourceHash

		if ($alreadyCurrent) {
			$records.Add([pscustomobject]@{
				plugin = $source.Plugin
				relativePath = $source.RelativePath
				sourceHash = $sourceHash
				installedHash = $sourceHash
				previousHash = $existingHash
				backupRelativePath = $null
			})
			continue
		}

		if ($existingHash -and $existingHash -ne $sourceHash) {
			if (!$Force) {
				throw "Target already has a different file: $($source.RelativePath). Add -Force to overwrite with backup."
			}
			$backupPath = Join-Path -Path $backupSession -ChildPath $source.RelativePath
			if ($PSCmdlet.ShouldProcess($dest, "backup to $backupPath")) {
				New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
				Copy-Item -LiteralPath $dest -Destination $backupPath -Force
			}
			$backupRelative = Get-RelativePath -Base $targetRoot -Path $backupPath
		}

		if ($PSCmdlet.ShouldProcess($dest, "install $($source.Plugin)")) {
			New-Item -ItemType Directory -Force -Path $destDir | Out-Null
			Copy-Item -LiteralPath $source.SourcePath -Destination $dest -Force
		}

		$records.Add([pscustomobject]@{
			plugin = $source.Plugin
			relativePath = $source.RelativePath
			sourceHash = $sourceHash
			installedHash = $sourceHash
			previousHash = $existingHash
			backupRelativePath = $backupRelative
		})
	}

	$manifest = [pscustomobject]@{
		modName = $ModName
		installedAt = (Get-Date).ToString("o")
		sourceRoot = $SourceRoot
		gameDir = $targetRoot
		includeNatives = [bool] $IncludeNatives
		files = $records
	}

	if ($PSCmdlet.ShouldProcess($manifestPath, "write manifest")) {
		Write-Manifest -ManifestPath $manifestPath -Manifest $manifest
	}

	Write-Host "Installed to: $targetRoot"
	Write-Host "Files: $($records.Count)"
	Write-Host "Manifest: $manifestPath"
	if (!$IncludeNatives) {
		Write-Host "Skipped natives/. Run install -IncludeNatives -Force if you intentionally want those resource files."
	}
}

function Remove-EmptyParents {
	param([string] $Path, [string] $StopAt)
	$current = Split-Path -Parent $Path
	$stop = Join-NormalizedPath $StopAt "."
	while ($current -and (Join-NormalizedPath $current ".").StartsWith($stop, [System.StringComparison]::OrdinalIgnoreCase)) {
		if ((Join-NormalizedPath $current ".") -eq $stop) { break }
		if ((Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { break }
		Remove-Item -LiteralPath $current -Force
		$current = Split-Path -Parent $current
	}
}

function Uninstall-Mod {
	$targetRoot = Resolve-GameDir -ExplicitGameDir $GameDir
	$manifestPath = Join-Path -Path $targetRoot -ChildPath $ManifestRelativePath
	$manifest = Read-Manifest -ManifestPath $manifestPath
	if (!$manifest) { throw "Install manifest was not found: $manifestPath" }

	$removed = 0
	$restored = 0
	$skipped = 0

	foreach ($record in @($manifest.files | Sort-Object relativePath -Descending)) {
		$dest = Join-Path -Path $targetRoot -ChildPath $record.relativePath
		if (!(Test-Path -LiteralPath $dest -PathType Leaf)) { continue }

		$currentHash = Get-FileSha256 -Path $dest
		if ($currentHash -ne $record.installedHash -and !$Force) {
			Write-Warning "Skipped modified file: $($record.relativePath). Add -Force to remove it anyway."
			$skipped++
			continue
		}

		if ($PSCmdlet.ShouldProcess($dest, "remove installed file")) {
			Remove-Item -LiteralPath $dest -Force
			$removed++
		}

		if ($record.backupRelativePath) {
			$backup = Join-Path -Path $targetRoot -ChildPath $record.backupRelativePath
			if (Test-Path -LiteralPath $backup -PathType Leaf) {
				if ($PSCmdlet.ShouldProcess($dest, "restore backup")) {
					New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
					Copy-Item -LiteralPath $backup -Destination $dest -Force
					$restored++
				}
			}
		}

		Remove-EmptyParents -Path $dest -StopAt $targetRoot
	}

	if ($skipped -eq 0 -or $Force) {
		if ($PSCmdlet.ShouldProcess($manifestPath, "remove manifest")) {
			Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
			Remove-EmptyParents -Path $manifestPath -StopAt $targetRoot
		}
	}

	Write-Host "Uninstalled from: $targetRoot"
	Write-Host "Removed: $removed, restored backups: $restored, skipped: $skipped"
}

switch ($Action) {
	"find" {
		$matches = @(Find-MHWildsGameDir)
		if ($matches.Count -eq 0) {
			Write-Host "Monster Hunter Wilds was not found."
			exit 1
		}
		$matches | ForEach-Object { Write-Host $_ }
	}
	"install" { Install-Mod }
	"uninstall" { Uninstall-Mod }
}

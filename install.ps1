# Installs diskfull on Windows from its GitHub release:
#
#   irm https://raw.githubusercontent.com/hubastard/diskfull/main/install.ps1 | iex
#
# Options, as environment variables set before running it:
#   $env:DISKFULL_VERSION      release to install, e.g. v1.0.0 (default: latest)
#   $env:DISKFULL_INSTALL_DIR  where diskfull.exe goes
#                              (default: %LOCALAPPDATA%\Programs\diskfull)
#
# It adds that folder to your user PATH and creates a "DiskFull" Start menu shortcut.
# To uninstall, delete both (and the folder from PATH in "Edit environment variables
# for your account").
#
# Everything runs in its own scope, so it does not change your session's settings,
# and never calls exit, which would close the window `iex` runs in.

& {
	Set-StrictMode -Version 3
	$ErrorActionPreference = 'Stop'
	$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is much slower with it

	$repo = 'https://github.com/hubastard/diskfull'
	$asset = 'diskfull-windows-x64.zip'
	$tmp = Join-Path ([IO.Path]::GetTempPath()) ('diskfull-' + [Guid]::NewGuid())

	try {
		$version = if ($env:DISKFULL_VERSION) { $env:DISKFULL_VERSION } else { 'latest' }
		if ($version -ne 'latest' -and -not $version.StartsWith('v')) { $version = "v$version" }
		$base = if ($version -eq 'latest') { "$repo/releases/latest/download" } else { "$repo/releases/download/$version" }

		# 32-bit PowerShell on 64-bit Windows reports the real CPU in PROCESSOR_ARCHITEW6432.
		$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
		switch ($arch) {
			'AMD64' {}
			'ARM64' { Write-Warning 'There is no ARM64 build yet: installing the x64 one, which Windows runs under emulation.' }
			default { throw "there is no prebuilt diskfull for $arch Windows; build from source: $repo#building-from-source" }
		}

		# Windows PowerShell 5.1 may still default to TLS 1.0, which GitHub refuses.
		[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
		New-Item -ItemType Directory $tmp | Out-Null

		Write-Host "Downloading $asset ($version)..."
		try {
			Invoke-WebRequest "$base/$asset" -OutFile "$tmp\$asset" -UseBasicParsing
			Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS" -UseBasicParsing
		} catch {
			throw "could not download $base/$asset ($($_.Exception.Message)); releases: $repo/releases"
		}

		$expected = $null
		foreach ($line in Get-Content "$tmp\SHA256SUMS") {
			$hash, $name = $line -split '\s+\*?', 2
			if ($name -eq $asset) { $expected = $hash }
		}
		if (-not $expected) { throw "$asset is not listed in SHA256SUMS" }
		if ((Get-FileHash "$tmp\$asset" -Algorithm SHA256).Hash -ne $expected) {
			throw "checksum mismatch for $asset, try again"
		}

		Expand-Archive "$tmp\$asset" -DestinationPath "$tmp\x" -Force
		if (-not (Test-Path "$tmp\x\diskfull.exe")) { throw "diskfull.exe is missing from $asset" }

		$dir = if ($env:DISKFULL_INSTALL_DIR) { $env:DISKFULL_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\diskfull' }
		$exe = Join-Path $dir 'diskfull.exe'
		New-Item -ItemType Directory $dir -Force | Out-Null
		# A running exe cannot be overwritten, but it can be renamed out of the way.
		Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
		if (Test-Path $exe) { Move-Item $exe "$exe.old" -Force }
		Copy-Item "$tmp\x\*" $dir -Recurse -Force
		Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
		Unblock-File $exe
		Write-Host "Installed $exe"

		# User PATH, read and written raw so entries like %USERPROFILE%\bin stay unexpanded.
		$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
		try {
			$parts = @(([string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')) -split ';' | Where-Object { $_ })
			if ($parts -notcontains $dir) {
				$key.SetValue('Path', (($parts + $dir) -join ';'), 'ExpandString')
				# Setting any variable through .NET tells Explorer that the environment
				# changed, so terminals opened from now on see the new PATH.
				[Environment]::SetEnvironmentVariable('DISKFULL_INSTALLING', '1', 'User')
				[Environment]::SetEnvironmentVariable('DISKFULL_INSTALLING', $null, 'User')
				Write-Host "Added $dir to your PATH (new terminals will see it)."
			}
		} finally {
			$key.Close()
		}
		if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$env:Path;$dir" }

		try {
			$programs = [Environment]::GetFolderPath('Programs')
			$link = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $programs 'DiskFull.lnk'))
			$link.TargetPath = $exe
			$link.WorkingDirectory = $dir
			$link.Description = 'See what is filling your disk'
			$link.Save()
			Write-Host 'Added DiskFull to the Start menu.'
		} catch {
			Write-Warning "could not create the Start menu shortcut: $($_.Exception.Message)"
		}

		Write-Host ''
		Write-Host "Start DiskFull from the Start menu, or run 'diskfull' (whole C: drive) or 'diskfull <folder>'."
		Write-Host 'To see everything, run it as administrator.'
	} catch {
		Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
		$global:LASTEXITCODE = 1 # lets scripts and CI see the failure
	} finally {
		Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
	}
}

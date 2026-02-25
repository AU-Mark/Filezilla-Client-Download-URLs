<#
.SYNOPSIS
    Updates FileZilla Client download links from filezilla-project.org

.DESCRIPTION
    Fetches the latest FileZilla Client download links from the official download page
    and saves them as a standardized JSON file with version tracking.

    Uses Selenium with stealth options to bypass CloudFlare bot protection.

    The JSON maintains:
    - "Latest" entry with current version info and download URLs for win32 and win64
    - Historical versions preserved with their original URLs

.PARAMETER OutputPath
    Path to the data folder. Defaults to ../data relative to script location.

.PARAMETER SkipVersionCheck
    Skip checking if version has changed (always update).

.EXAMPLE
    .\Update-FileZillaData.ps1

.EXAMPLE
    .\Update-FileZillaData.ps1 -OutputPath "C:\Data"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$SkipVersionCheck
)

# Set output path
if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "..\data"
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$Url = 'https://filezilla-project.org/download.php?show_all=1'
$JsonPath = Join-Path $OutputPath "FileZilla.json"
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FileZilla Client Download Data Updater" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Timestamp: $timestamp" -ForegroundColor Gray
Write-Host "Output: $JsonPath" -ForegroundColor Gray
Write-Host ""

#region Helper Functions

function Get-FileZillaDataSelenium {
    <#
    .SYNOPSIS
        Fetches FileZilla download data using Selenium with stealth options.
    #>
    param([string]$Url)

    Write-Host "[FileZilla] Fetching data using Selenium..." -ForegroundColor Cyan
    Write-Host "[FileZilla] URL: $Url" -ForegroundColor Gray

    # Try to find Selenium module
    $seleniumModule = Get-Module -ListAvailable -Name Selenium
    if (-not $seleniumModule) {
        Write-Error "[FileZilla] Selenium module not found. Please install with: Install-Module -Name Selenium"
        return $null
    }

    # Find Selenium assemblies
    $seleniumPath = $seleniumModule.ModuleBase
    $assembliesPath = Join-Path $seleniumPath "assemblies"
    $webDriverDll = Join-Path $assembliesPath "WebDriver.dll"

    if (-not (Test-Path $webDriverDll)) {
        Write-Error "[FileZilla] WebDriver.dll not found at: $webDriverDll"
        return $null
    }

    # Load WebDriver
    if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "WebDriver" })) {
        Add-Type -Path $webDriverDll -ErrorAction Stop
    }

    $driver = $null

    try {
        # Create Chrome options with stealth settings to bypass bot protection
        $chromeOptions = New-Object OpenQA.Selenium.Chrome.ChromeOptions
        $chromeOptions.AddExcludedArgument("enable-automation")
        $chromeOptions.AddArgument("--disable-blink-features=AutomationControlled")
        $chromeOptions.AddArgument("--disable-extensions")
        $chromeOptions.AddArgument("--disable-http2")
        $chromeOptions.AddArgument("--no-sandbox")
        $chromeOptions.AddArgument("--disable-dev-shm-usage")
        $chromeOptions.AddArgument("--disable-gpu")
        $chromeOptions.AddArgument("--disable-infobars")
        $chromeOptions.AddArgument("--disable-notifications")
        $chromeOptions.AddArgument("--disable-popup-blocking")
        $chromeOptions.AddArgument("--window-size=1920,1080")
        $chromeOptions.AddArgument("--start-maximized")
        $chromeOptions.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36")
        $chromeOptions.AddArgument("--lang=en-US")
        $chromeOptions.AddArgument("--headless=new")
        $chromeOptions.AddArgument("--log-level=3")
        $chromeOptions.AddArgument("--silent")

        # Create service
        $chromeDriverPath = Join-Path $assembliesPath "chromedriver.exe"
        if (Test-Path $chromeDriverPath) {
            $chromeService = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService($assembliesPath)
        } else {
            $chromeService = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService()
        }
        $chromeService.HideCommandPromptWindow = $true
        $chromeService.SuppressInitialDiagnosticInformation = $true

        Write-Host "[FileZilla] Starting Chrome..." -ForegroundColor Cyan
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($chromeService, $chromeOptions)
        $driver.Manage().Timeouts().PageLoad = [TimeSpan]::FromSeconds(60)

        Write-Host "[FileZilla] Navigating to page..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($Url)

        # Wait for page to load and CloudFlare check to complete
        Start-Sleep -Seconds 8

        Write-Host "[FileZilla] Page loaded: $($driver.Title)" -ForegroundColor Green

        $html = $driver.PageSource

        # Check for errors
        if ($html -match "ERR_|can't be reached|Access Denied|blocked|cloudflare") {
            throw "Page load failed or blocked by protection"
        }

        # Extract version information
        # FileZilla version typically appears as "FileZilla 3.x.x" in the page
        $version = $null
        $releaseDate = $null

        # Try to find version in various formats
        if ($html -match 'FileZilla[^\d]*?(3\.[\d\.]+)') {
            $version = $Matches[1]
            Write-Host "[FileZilla] Found version: $version" -ForegroundColor Green
        } elseif ($html -match 'FileZilla_([3\. \d]+)_win') {
            $version = $Matches[1].Trim()
            Write-Host "[FileZilla] Found version from download link: $version" -ForegroundColor Green
        }

        if (-not $version) {
            Write-Error "[FileZilla] Could not extract version information"
            return $null
        }

        # Extract download links for win32 and win64
        $downloads = @{}

        # Pattern: FileZilla_VERSION_winARCH-setup.exe
        # Example: https://dl4.cdn.filezilla-project.org/client/FileZilla_3.68.1_win64-setup.exe
        $downloadPattern = '(https://[^"'']+/FileZilla_[\d\.]+_win(32|64)-setup\.exe[^"'']*)'

        $linkMatches = [regex]::Matches($html, $downloadPattern, 'IgnoreCase')

        Write-Host "[FileZilla] Found $($linkMatches.Count) potential download links" -ForegroundColor Cyan

        foreach ($match in $linkMatches) {
            $fullUrl = $match.Groups[1].Value
            $architecture = $match.Groups[2].Value

            $platform = "win$architecture"

            if (-not $downloads.ContainsKey($platform)) {
                # Extract version from URL to verify
                if ($fullUrl -match 'FileZilla_([\d\.]+)_') {
                    $urlVersion = $Matches[1]
                } else {
                    $urlVersion = $version
                }

                $downloads[$platform] = [PSCustomObject]@{
                    Platform = $platform
                    Architecture = $architecture
                    Url = $fullUrl
                    Version = $urlVersion
                }

                Write-Host "  [$platform] URL: $fullUrl" -ForegroundColor Gray
            }
        }

        if ($downloads.Count -eq 0) {
            Write-Error "[FileZilla] No download links extracted"
            return $null
        }

        if ($downloads.Count -lt 2) {
            Write-Warning "[FileZilla] Expected at least win32 and win64 downloads, found $($downloads.Count)"
        }

        # Convert downloads hashtable to PSCustomObject for JSON serialization
        $downloadsObj = [PSCustomObject]@{}
        foreach ($key in $downloads.Keys) {
            $downloadsObj | Add-Member -NotePropertyName $key -NotePropertyValue $downloads[$key]
        }

        # Build result object
        $result = [PSCustomObject]@{
            Version = $version
            ReleaseDate = $releaseDate
            Downloads = $downloadsObj
        }

        Write-Host "[FileZilla] Extracted $($downloads.Count) platform downloads" -ForegroundColor Green
        return $result

    } catch {
        Write-Error "[FileZilla] Selenium failed: $_"
        Write-Error $_.ScriptStackTrace
        return $null
    } finally {
        if ($driver) {
            try {
                Write-Host "[FileZilla] Closing browser..." -ForegroundColor Gray
                $driver.Quit()
            } catch { }
        }
    }
}

#endregion

#region Main Execution

# Fetch current data
$fileZillaData = Get-FileZillaDataSelenium -Url $Url

if (-not $fileZillaData) {
    Write-Error "[FileZilla] Failed to fetch FileZilla data"
    exit 1
}

# Load existing JSON if present
$existingData = $null
if (Test-Path $JsonPath) {
    try {
        $existingData = Get-Content $JsonPath -Raw | ConvertFrom-Json
        Write-Host "[FileZilla] Loaded existing data from: $JsonPath" -ForegroundColor Cyan
    } catch {
        Write-Warning "[FileZilla] Could not parse existing JSON, will create new file"
    }
}

# Check if version has changed
$versionChanged = $true
if ($existingData -and $existingData.Latest -and -not $SkipVersionCheck) {
    if ($existingData.Latest.Version -eq $fileZillaData.Version) {
        Write-Host "[FileZilla] Version unchanged ($($fileZillaData.Version)). Skipping update." -ForegroundColor Yellow
        $versionChanged = $false
    }
}

if ($versionChanged) {
    Write-Host "[FileZilla] Processing version update..." -ForegroundColor Cyan

    # Initialize or update the JSON structure
    $jsonOutput = if ($existingData) {
        # Preserve existing structure
        $existingData
    } else {
        # Create new structure
        [PSCustomObject]@{
            Product = "FileZilla Client"
            LastUpdated = $timestamp
            SourceUrl = $Url
            Latest = $null
            Versions = [PSCustomObject]@{}
        }
    }

    # If there was a previous "Latest", move it to Versions
    if ($existingData -and $existingData.Latest -and $existingData.Latest.Version -ne $fileZillaData.Version) {
        $oldVersion = $existingData.Latest.Version
        Write-Host "[FileZilla] Archiving previous version: $oldVersion" -ForegroundColor Cyan

        # Add old version to Versions object
        $jsonOutput.Versions | Add-Member -NotePropertyName $oldVersion -NotePropertyValue ([PSCustomObject]@{
            Version = $existingData.Latest.Version
            ReleaseDate = $existingData.Latest.ReleaseDate
            ArchivedOn = $timestamp
            Downloads = $existingData.Latest.Downloads
        }) -Force
    }

    # Update Latest
    $jsonOutput.Latest = [PSCustomObject]@{
        Version = $fileZillaData.Version
        ReleaseDate = $fileZillaData.ReleaseDate
        UpdatedOn = $timestamp
        Downloads = $fileZillaData.Downloads
    }

    $jsonOutput.LastUpdated = $timestamp

    # Save JSON
    $jsonOutput | ConvertTo-Json -Depth 10 | Out-File -FilePath $JsonPath -Encoding UTF8
    Write-Host "[FileZilla] Saved to: $JsonPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Version: $($fileZillaData.Version)" -ForegroundColor White
Write-Host "  Release Date: $(if ($fileZillaData.ReleaseDate) { $fileZillaData.ReleaseDate } else { 'N/A' })" -ForegroundColor White
Write-Host "  Platforms: $(($fileZillaData.Downloads | Get-Member -MemberType NoteProperty).Count)" -ForegroundColor White
Write-Host "  Version Changed: $versionChanged" -ForegroundColor $(if ($versionChanged) { 'Green' } else { 'Yellow' })
Write-Host "========================================" -ForegroundColor Cyan

exit 0

#endregion

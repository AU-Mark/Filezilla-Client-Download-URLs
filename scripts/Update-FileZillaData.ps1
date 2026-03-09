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

        # ============================================================
        # Selenium Stealth: Inject JavaScript via CDP to mask automation
        # This patches browser properties that CloudFlare checks to
        # detect headless/automated Chrome instances.
        # Equivalent to Python's selenium-stealth / undetected-chromedriver.
        # ============================================================
        Write-Host "[FileZilla] Applying stealth patches via CDP..." -ForegroundColor Cyan

        # Stealth JS payload - patches navigator properties, plugins, WebGL, etc.
        $stealthJs = @'
// Override navigator.webdriver to return undefined
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

// Inject window.chrome object (missing in headless)
window.chrome = {
    runtime: {},
    loadTimes: function() {},
    csi: function() {},
    app: { isInstalled: false, InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' }, RunningState: { CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running' } }
};

// Override navigator.plugins to show realistic plugins
Object.defineProperty(navigator, 'plugins', {
    get: () => {
        const plugins = [
            { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer', description: 'Portable Document Format' },
            { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai', description: '' },
            { name: 'Native Client', filename: 'internal-nacl-plugin', description: '' }
        ];
        plugins.refresh = () => {};
        return plugins;
    }
});

// Override navigator.languages
Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });

// Override navigator.permissions.query to handle 'notifications' properly
const originalQuery = window.navigator.permissions.query;
window.navigator.permissions.query = (parameters) => (
    parameters.name === 'notifications'
        ? Promise.resolve({ state: Notification.permission })
        : originalQuery(parameters)
);

// Fix missing connection property
Object.defineProperty(navigator, 'connection', {
    get: () => ({ effectiveType: '4g', rtt: 50, downlink: 10, saveData: false })
});

// Override WebGL vendor and renderer (SwiftShader is a headless giveaway)
const getParameter = WebGLRenderingContext.prototype.getParameter;
WebGLRenderingContext.prototype.getParameter = function(parameter) {
    if (parameter === 37445) return 'Google Inc. (NVIDIA)';
    if (parameter === 37446) return 'ANGLE (NVIDIA, NVIDIA GeForce GTX 1050 Direct3D11 vs_5_0 ps_5_0, D3D11)';
    return getParameter.call(this, parameter);
};

// Prevent iframe contentWindow detection
try {
    const elementDescriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight');
    Object.defineProperty(HTMLDivElement.prototype, 'offsetHeight', elementDescriptor);
    Object.defineProperty(HTMLDivElement.prototype, 'offsetWidth', elementDescriptor);
} catch(e) {}
'@

        # Inject stealth JS before any page navigation using CDP
        # Page.addScriptToEvaluateOnNewDocument runs JS on every new page/frame
        try {
            $driver.ExecuteCdpCommand("Page.addScriptToEvaluateOnNewDocument", [System.Collections.Generic.Dictionary[string,object]]@{ source = $stealthJs })
            Write-Host "[FileZilla] Stealth patches applied via CDP" -ForegroundColor Green
        } catch {
            Write-Warning "[FileZilla] CDP stealth injection failed: $($_.Exception.Message)"
            Write-Warning "[FileZilla] Falling back to post-navigation JS injection"

            # Fallback: navigate first, then inject (less effective but still helps)
            $driver.Navigate().GoToUrl("about:blank")
            $null = $driver.ExecuteScript($stealthJs)
            Write-Host "[FileZilla] Stealth patches applied via ExecuteScript fallback" -ForegroundColor Yellow
        }

        Write-Host "[FileZilla] Navigating to page..." -ForegroundColor Cyan
        $driver.Navigate().GoToUrl($Url)

        # Wait for CloudFlare challenge to resolve and real page to load
        # CloudFlare interstitials show empty title or "Just a moment..." before resolving
        $maxWaitSeconds = 30
        $pollInterval = 2
        $waited = 0
        $pageReady = $false

        Write-Host "[FileZilla] Waiting for CloudFlare challenge to resolve (max ${maxWaitSeconds}s)..." -ForegroundColor Cyan

        while ($waited -lt $maxWaitSeconds) {
            Start-Sleep -Seconds $pollInterval
            $waited += $pollInterval

            $currentTitle = $driver.Title
            $currentSource = $driver.PageSource

            # CloudFlare challenge indicators - page not ready yet
            $isCloudFlare = [string]::IsNullOrWhiteSpace($currentTitle) -or
                            $currentTitle -match 'Just a moment' -or
                            $currentTitle -match 'Attention Required' -or
                            $currentSource -match 'cf-browser-verification' -or
                            $currentSource -match 'challenge-platform'

            if (-not $isCloudFlare -and $currentTitle.Length -gt 0) {
                Write-Host "[FileZilla] Page ready after ${waited}s - Title: $currentTitle" -ForegroundColor Green
                $pageReady = $true
                break
            }

            Write-Host "[FileZilla] Waiting... (${waited}s) Title: '$currentTitle'" -ForegroundColor Yellow
        }

        if (-not $pageReady) {
            # Log diagnostic info for debugging
            $finalTitle = $driver.Title
            $finalSource = $driver.PageSource
            $sourcePreview = if ($finalSource.Length -gt 500) { $finalSource.Substring(0, 500) } else { $finalSource }
            Write-Host "[FileZilla] DIAGNOSTIC - Final page title: '$finalTitle'" -ForegroundColor Red
            Write-Host "[FileZilla] DIAGNOSTIC - Page source preview:" -ForegroundColor Red
            Write-Host $sourcePreview -ForegroundColor Gray
            throw "CloudFlare challenge was not resolved within ${maxWaitSeconds} seconds. Page title: '$finalTitle'"
        }

        $html = $driver.PageSource

        # Check for error pages that got past the CloudFlare wait
        if ($html -match "ERR_|can't be reached|Access Denied") {
            throw "Page load failed with error after CloudFlare check"
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
            # Log page info for debugging
            $sourcePreview = if ($html.Length -gt 1000) { $html.Substring(0, 1000) } else { $html }
            Write-Host "[FileZilla] DIAGNOSTIC - Page source preview (first 1000 chars):" -ForegroundColor Red
            Write-Host $sourcePreview -ForegroundColor Gray
            Write-Error "[FileZilla] Could not extract version information from page"
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

# Check if version has changed (for archiving purposes only)
$versionChanged = $true
if ($existingData -and $existingData.Latest -and -not $SkipVersionCheck) {
    if ($existingData.Latest.Version -eq $fileZillaData.Version) {
        Write-Host "[FileZilla] Version unchanged ($($fileZillaData.Version)). Refreshing download URLs." -ForegroundColor Yellow
        $versionChanged = $false
    }
}

# Always update - CDN download URLs can rotate/expire independently of version changes
Write-Host "[FileZilla] Processing update..." -ForegroundColor Cyan

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

# If the version changed, archive the previous "Latest" to Versions history
if ($versionChanged -and $existingData -and $existingData.Latest -and $existingData.Latest.Version -ne $fileZillaData.Version) {
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

# Always refresh Latest with current URLs from the download page
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

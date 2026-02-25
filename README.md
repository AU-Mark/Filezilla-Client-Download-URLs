# FileZilla Client Download Data Automation

This GitHub Action automatically scrapes the FileZilla Client download page using Selenium Stealth to bypass CloudFlare protection and maintains a JSON file with the latest download URLs.

## 🎯 Purpose

FileZilla's website implements bot protection that blocks standard HTTP requests. This automation:
- Uses Selenium with Chrome in headless mode with stealth options
- Bypasses CloudFlare and bot detection
- Extracts download URLs for both win32 and win64 architectures
- Maintains version history in a structured JSON file
- Runs daily to keep download links current

## 📁 Structure

```
.
├── .github/
│   └── workflows/
│       └── update-filezilla-data.yml    # GitHub Action workflow
├── data/
│   └── FileZilla.json                    # Generated download data
├── scripts/
│   └── Update-FileZillaData.ps1          # Selenium scraping script
├── .gitignore
└── README.md                             # This file
```

## 🔄 How It Works

### 1. Scheduled Execution
The GitHub Action runs daily at 8:00 AM UTC via the workflow schedule.

### 2. Selenium Stealth
The PowerShell script uses Selenium with Chrome configured to:
- Disable automation flags
- Use realistic browser User-Agent
- Bypass bot detection features
- Wait for CloudFlare challenges to complete

### 3. Data Extraction
The script:
- Navigates to `https://filezilla-project.org/download.php?show_all=1`
- Waits for the page to fully load (including CloudFlare checks)
- Extracts version information
- Finds download URLs using regex patterns
- Validates extracted data

### 4. JSON Structure
```json
{
  "Product": "FileZilla Client",
  "LastUpdated": "2026-02-25T10:00:00Z",
  "SourceUrl": "https://filezilla-project.org/download.php?show_all=1",
  "Latest": {
    "Version": "3.68.1",
    "ReleaseDate": null,
    "UpdatedOn": "2026-02-25T10:00:00Z",
    "Downloads": {
      "win32": {
        "Platform": "win32",
        "Architecture": "32",
        "Url": "https://dl4.cdn.filezilla-project.org/client/FileZilla_3.68.1_win32-setup.exe",
        "Version": "3.68.1"
      },
      "win64": {
        "Platform": "win64",
        "Architecture": "64",
        "Url": "https://dl4.cdn.filezilla-project.org/client/FileZilla_3.68.1_win64-setup.exe",
        "Version": "3.68.1"
      }
    }
  },
  "Versions": {
    "3.68.0": {
      "Version": "3.68.0",
      "ReleaseDate": null,
      "ArchivedOn": "2026-02-25T10:00:00Z",
      "Downloads": { ... }
    }
  }
}
```

## 🚀 Usage

### Accessing the Data

The JSON file is available at:
```
https://raw.githubusercontent.com/AunalyticsManagedServices/ThirdPartyApplications/main/FileZilla/Github%20Action/data/FileZilla.json
```

### PowerShell Example

```powershell
# Fetch the latest FileZilla download data
$JsonUrl = "https://raw.githubusercontent.com/AunalyticsManagedServices/ThirdPartyApplications/main/FileZilla/Github%20Action/data/FileZilla.json"
$Data = Invoke-RestMethod -Uri $JsonUrl

# Get the latest version
$LatestVersion = $Data.Latest.Version
Write-Host "Latest FileZilla version: $LatestVersion"

# Determine architecture
$Is64Bit = [System.Environment]::Is64BitOperatingSystem
$Architecture = if ($Is64Bit) { "win64" } else { "win32" }

# Get download URL
$DownloadUrl = $Data.Latest.Downloads.$Architecture.Url
Write-Host "Download URL for $Architecture: $DownloadUrl"

# Download the installer
Invoke-WebRequest -Uri $DownloadUrl -OutFile "FileZilla_Setup.exe"
```

### Integration with Update Scripts

The main `Update-FileZilla.ps1` script can be modified to read from this JSON:

```powershell
function Get-FileZillaDownloadUrl {
    param([string]$Architecture)

    $JsonUrl = "https://raw.githubusercontent.com/AunalyticsManagedServices/ThirdPartyApplications/main/FileZilla/Github%20Action/data/FileZilla.json"

    Try {
        $Data = Invoke-RestMethod -Uri $JsonUrl -TimeoutSec 30
        $DownloadUrl = $Data.Latest.Downloads.$Architecture.Url

        if ($DownloadUrl) {
            return $DownloadUrl
        } else {
            Throw "No download URL found for architecture: $Architecture"
        }
    } Catch {
        Throw "Failed to fetch FileZilla download data: $_"
    }
}
```

## 🔧 Manual Execution

To manually trigger the GitHub Action:
1. Go to the "Actions" tab in the GitHub repository
2. Select "Update FileZilla Download Data"
3. Click "Run workflow"
4. Select the branch (usually `main`)
5. Click "Run workflow"

## 🛠️ Local Development

To run the scraping script locally:

```powershell
# Install Selenium module
Install-Module -Name Selenium -Scope CurrentUser -Force

# Run the script
.\scripts\Update-FileZillaData.ps1 -Verbose

# Check the generated JSON
Get-Content .\data\FileZilla.json | ConvertFrom-Json
```

**Note**: Requires Chrome browser to be installed for ChromeDriver to work.

## 📊 Monitoring

The GitHub Action:
- Validates the generated JSON structure
- Only commits if the data is valid and changed
- Reports status in the workflow logs
- Continues on error to prevent workflow failures

## ⚠️ Important Notes

1. **CloudFlare Protection**: FileZilla's website uses CloudFlare bot protection. The Selenium stealth configuration is specifically designed to bypass this.

2. **Rate Limiting**: The workflow runs once daily to avoid triggering rate limits or additional bot detection.

3. **Version History**: Old versions are automatically archived in the `Versions` object when a new version is detected.

4. **Validation**: The workflow validates that at least 2 platforms (win32 and win64) are present before committing changes.

## 🔒 Security

- The GitHub Action runs in a sandboxed environment
- No sensitive credentials are required
- All operations are read-only on the FileZilla website
- The generated JSON is public data

## 📝 License

This automation is part of the Aunalytics Managed Services ThirdPartyApplications repository.

## 👤 Maintainer

Mark Newton - Aunalytics Managed Services

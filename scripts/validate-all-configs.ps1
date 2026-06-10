# Validate all example configuration files
# This script validates each *.example.yaml file in lablink-infrastructure/config

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path (Split-Path -Parent $scriptDir) "lablink-infrastructure\config"
$dockerImage = "ghcr.io/talmolab/lablink-allocator-image:linux-amd64-latest-test"

Write-Host "=== Validating All Example Configs ===" -ForegroundColor Cyan
Write-Host ""

$examples = Get-ChildItem "$configDir\*.example.yaml"
$exampleConfigYaml = Get-Item "$configDir\example.config.yaml"
$allExamples = $examples + $exampleConfigYaml

$passed = 0
$failed = 0
$failedFiles = @()

foreach ($example in $allExamples) {
    Write-Host "Validating: $($example.Name)" -ForegroundColor Yellow

    # Copy to config.yaml for validation
    Copy-Item $example.FullName "$configDir\config.yaml" -Force

    # Run validation
    $result = docker run --rm -v "${configDir}\config.yaml:/config/config.yaml:ro" $dockerImage uv run lablink-validate-config /config/config.yaml 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [PASS]" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  [FAIL]" -ForegroundColor Red
        Write-Host "  $result" -ForegroundColor Red
        $failed++
        $failedFiles += $example.Name
    }

    # Clean up
    Remove-Item "$configDir\config.yaml" -Force -ErrorAction SilentlyContinue
    Write-Host ""
}

Write-Host "=== Validation Summary ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })

if ($failed -gt 0) {
    Write-Host ""
    Write-Host "Failed files:" -ForegroundColor Red
    foreach ($file in $failedFiles) {
        Write-Host "  - $file" -ForegroundColor Red
    }
    exit 1
} else {
    Write-Host ""
    Write-Host "All configurations validated successfully!" -ForegroundColor Green
    exit 0
}

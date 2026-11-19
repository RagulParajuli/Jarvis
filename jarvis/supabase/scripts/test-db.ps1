# Applies the Jarvis migrations to a throwaway PostgreSQL container and runs the
# database tests in supabase/tests.
#
# Requires Docker only: no local psql, no database credentials, no Supabase
# project. The container is deleted when the script exits.
#
#   pwsh -File supabase/scripts/test-db.ps1
#   $env:JARVIS_TEST_POSTGRES_IMAGE = 'postgres:17'; pwsh -File supabase/scripts/test-db.ps1
#   $env:JARVIS_TEST_SUPABASE_LIKE = '1'; pwsh -File supabase/scripts/test-db.ps1

[CmdletBinding()]
param(
    [string] $Image = $env:JARVIS_TEST_POSTGRES_IMAGE
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Image)) { $Image = 'postgres:16' }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$name = "jarvis-db-test-$PID"
$database = 'jarvis_test'

# Runs docker and captures its output. psql writes notices to stderr, which
# PowerShell would otherwise turn into a terminating error.
function Invoke-Native {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-Psql {
    param([string] $File)

    return Invoke-Native exec $name psql --quiet --set ON_ERROR_STOP=1 `
        --set client_min_messages=warning `
        --username postgres --dbname $database --file $File
}

try {
    Write-Host "Starting $Image as $name"
    $start = Invoke-Native run --detach --name $name `
        --env POSTGRES_HOST_AUTH_METHOD=trust `
        --env POSTGRES_DB=postgres `
        $Image
    if ($start.ExitCode -ne 0) { throw "could not start the test container: $($start.Output -join ' ')" }

    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $probe = Invoke-Native exec $name pg_isready --quiet --username postgres --dbname postgres
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 1000
    }
    if (-not $ready) { throw 'the test database did not become ready' }

    $created = Invoke-Native exec $name createdb --username postgres $database
    if ($created.ExitCode -ne 0) { throw "could not create the test database: $($created.Output -join ' ')" }

    $copied = Invoke-Native cp (Join-Path $root 'supabase/migrations') "${name}:/migrations"
    if ($copied.ExitCode -ne 0) { throw "could not copy migrations: $($copied.Output -join ' ')" }
    $copied = Invoke-Native cp (Join-Path $root 'supabase/tests') "${name}:/tests"
    if ($copied.ExitCode -ne 0) { throw "could not copy tests: $($copied.Output -join ' ')" }
    $copied = Invoke-Native cp (Join-Path $root 'supabase/scripts/bootstrap-test-roles.sql') "${name}:/bootstrap-test-roles.sql"
    if ($copied.ExitCode -ne 0) { throw "could not copy the role bootstrap: $($copied.Output -join ' ')" }

    # The client roles must exist before the access-control migration so that its
    # revokes are exercised against real roles, not skipped.
    Write-Host 'bootstrap test roles'
    $result = Invoke-Psql '/bootstrap-test-roles.sql'
    if ($result.ExitCode -ne 0) {
        $result.Output | ForEach-Object { Write-Host $_ }
        throw 'the test role bootstrap failed'
    }

    # Optional: start from the state a fresh Supabase project is in (extensions
    # schema already present, pgcrypto and pg_trgm already installed).
    if ($env:JARVIS_TEST_SUPABASE_LIKE -eq '1') {
        $copied = Invoke-Native cp (Join-Path $root 'supabase/scripts/bootstrap-supabase-like.sql') "${name}:/bootstrap-supabase-like.sql"
        if ($copied.ExitCode -ne 0) { throw "could not copy the supabase-like bootstrap: $($copied.Output -join ' ')" }

        Write-Host 'bootstrap supabase-like state'
        $result = Invoke-Psql '/bootstrap-supabase-like.sql'
        if ($result.ExitCode -ne 0) {
            $result.Output | ForEach-Object { Write-Host $_ }
            throw 'the supabase-like bootstrap failed'
        }
    }

    $listing = Invoke-Native exec $name ls /migrations
    if ($listing.ExitCode -ne 0) { throw "could not list migrations: $($listing.Output -join ' ')" }

    foreach ($file in ($listing.Output | Sort-Object)) {
        Write-Host "migration $file"
        $result = Invoke-Psql "/migrations/$file"
        if ($result.ExitCode -ne 0) {
            $result.Output | ForEach-Object { Write-Host $_ }
            throw "migration failed: $file"
        }
    }

    $listing = Invoke-Native exec $name ls /tests
    if ($listing.ExitCode -ne 0) { throw "could not list tests: $($listing.Output -join ' ')" }

    $failures = 0
    $total = 0
    foreach ($file in ($listing.Output | Sort-Object)) {
        $total++
        $result = Invoke-Psql "/tests/$file"
        if ($result.ExitCode -eq 0) {
            Write-Host "ok   $file"
        }
        else {
            Write-Host "FAIL $file"
            $result.Output | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
            $failures++
        }
    }

    Write-Host ''
    if ($failures -ne 0) {
        Write-Host "$failures of $total test files failed"
        exit 1
    }
    Write-Host "all $total test files passed"
}
finally {
    $cleanup = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & docker rm --force $name *> $null
    $ErrorActionPreference = $cleanup
}

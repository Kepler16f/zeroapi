$tokens = $null; $errs = $null
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "build.ps1"), [ref]$tokens, [ref]$errs) | Out-Null
if ($errs.Count) {
  $errs | ForEach-Object { "line {0} col {1}: {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message }
  exit 1
} else { "build.ps1 syntax OK" }

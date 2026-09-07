$c = [System.IO.File]::ReadAllText('C:\Users\MTC\Desktop\madjana\supabase\migrations\UNIFIED_schema.sql', [System.Text.Encoding]::UTF8)
Write-Host "Functions: $([regex]::Matches($c, 'CREATE OR REPLACE FUNCTION').Count)"
Write-Host "Tables: $([regex]::Matches($c, 'CREATE TABLE').Count)"
Write-Host "Policies: $([regex]::Matches($c, 'CREATE POLICY').Count)"
Write-Host "Triggers: $([regex]::Matches($c, 'CREATE TRIGGER').Count)"
Write-Host "Length: $($c.Length)"

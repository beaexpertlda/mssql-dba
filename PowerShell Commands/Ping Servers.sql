/*	PowerShell Command */
$sizeThreshold_In_MB = 5;
$pingResultPath = $PSScriptRoot;
$pingResultFile = "$pingResultPath\pingResult";
$names = @('MyDbServer01');

# Delete files older than 15 days
$limit = (Get-Date).AddDays(-15);
Get-ChildItem -Path $pingResultPath -Recurse -Force | Where-Object {$_.Name -like 'pingResult*' -and !$_.PSIsContainer -and $_.LastWriteTime -lt $limit } | Remove-Item -Force;

if (Test-Path $pingResultFile -PathType Leaf)
{
  $fileDetails = Get-ItemProperty $pingResultFile;
  $sizeInKB = ([Math]::Ceiling(($fileDetails.Length/1mb)));

  if ($sizeInKB -ge $sizeThreshold_In_MB)
  {
    Write-Host "Renaming file $pingResultFile to $($pingResultFile) $(Get-Date -Format ddMMMyyyyTHHmm) since threshold size of $sizeThreshold_In_MB MB is crossed.";
    Rename-Item -Path $pingResultFile -NewName ($pingResultFile+(Get-Date -Format ddMMMyyyyTHHmm));
  }
}

foreach ($name in $names)
{
  if (Test-Connection -ComputerName $name -Count 1 -ErrorAction SilentlyContinue)
  {
   Out-File -FilePath $pingResultFile -Append -InputObject "$((Get-Date).ToString()) - $name is Up and Running";
  }
  else
  {
    Out-File -FilePath $pingResultFile -Append -InputObject "$((Get-Date).ToString()) - $name is not connecting";
    Out-File -FilePath $pingResultFile -Append -InputObject (Test-Connection $name -Count 1 );
  }
}
# Return 0 for Success
return 0; 

/*	TSQL Command to execute script every one second*/
SET NOCOUNT ON;
DECLARE @cmdQuery VARCHAR(1000); 

SET @cmdQuery = 'PowerShell.exe -noprofile -command "F:\PingMirroringPartners\PingServers.ps1"';

WHILE (1 = 1)
BEGIN
	-- Keep Running the code every time
	WAITFOR DELAY '00:00:01'; 
	exec xp_cmdshell @cmdQuery, NO_OUTPUT;
END


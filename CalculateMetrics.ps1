[CmdletBinding()]
param([Parameter(Mandatory=$true)]$CheckoutDir, $OutputFile=".\index.html")


function Create-Node($Name)
{
    @{name=$Name}
}

function AddTo-ObjectTree($Root, $Element)
{
    foreach($child in $Root.Children)
    {
        if($child.name -eq $Element)
        {
            return $child
        }
    }
    $newChild = Create-Node $Element
    if($Root.children -eq $null)
    {
        $Root.children = @($newChild)
    }else{
        $Root.children+=$newChild
    }    
    return $newChild
}


 <#
    .SYNOPSIS
        Generate calculate LOC for every file inside CheckoutDir
#>
function Get-FilesLOC
{
    [CmdletBinding()]
    param()
    $clocExePath = "$PSScriptRoot\cloc-1.70.exe"
    if(-not (Test-Path $clocExePath))
    {
        Write-Error "Cannot find file: $clocExePath"
    }
    Write-Verbose "Start colecting LOC statistics"
    Remove-Item "$PSScriptRoot\cloc.csv" -ErrorAction SilentlyContinue
    & $clocExePath --by-file --csv --skip-uniqueness --out="$PSScriptRoot\cloc.csv"  $CheckoutDir
    Get-Content "$PSScriptRoot\cloc.csv" -Raw | ConvertFrom-Csv -Delimiter ','    
    Write-Verbose "Finish colecting LOC statistics"
}

 <#
    .SYNOPSIS
        Merge LOC statistics with SVN statistics data for every file in checkout directory

    .PARAMETER LocData 
        Collection with LOC for every file

    .PARAMETER SvnData
        Dictionary with number of commits for every file

#>
function Merge-StatisticData
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$LocData, 
        [Parameter(Mandatory=$true)]$SvnData
    )
    
    Write-Verbose "Start merging statistic data"
    $root = Create-Node '.';
    $maxCommitCount =  ($SvnData.Values | Measure-Object -Maximum).Maximum    
    foreach($el in $LocData)
    {        
        $fileName = ([string] $el.filename).Replace($CheckoutDir,"").Replace('\','/').Trim('/')
        if($fileName.EndsWith(".cs"))
        {
            $nameParts = $fileName.Split('/')
            $localRoot = $root
            foreach($p in $nameParts)
            {
                $localRoot = AddTo-ObjectTree $localRoot $p
            }            
            $commitCount = $SvnData[$fileName]            
            $localRoot.size = $el.code             
            $localRoot.weight = $commitCount/$maxCommitCount
        }
    }
    Write-Verbose "Finish merging statistic data"
    $root
}

 <#
    .SYNOPSIS
        Get SVN module path for CheckoutDir
#>
function Get-SvnModulePath
{
    $data = (svn info $CheckoutDir) -split '\r'    
    foreach($attr in $data)
    {
        $parts = $attr.Split(":")
        if($parts[0] -eq "Relative URL")
        {
            $parts[1].Trim().Replace("^","")
        }
    }
}

 <#
    .SYNOPSIS
        Calculate number of commits for every file inside CheckoutDir
#>
function Get-SvnStatistics(){
    [CmdletBinding()]
    Param()
    Write-Verbose "Start collecting SVN log"
    $svnExePath = "$env:ProgramFiles\TortoiseSVN\bin\svn.exe"
    #svn log -v --xml -r "{2016-07-01}:HEAD" ./ > svnlogfile.log
    if(-not (Test-Path $svnExePath))
    {
        Write-Error "Cannot find svn.exe"
    }
    & $svnExePath log -v --xml $CheckoutDir | Out-File "$PSScriptRoot\svnlogfile.log" -Encoding utf8
    Write-Verbose "Finish collecting SVN log"
    Write-Verbose "Start processing SVN log"
    $modulePath = Get-SvnModulePath
    $logfilePath = Get-Item "$PSScriptRoot\svnlogfile.log"
    $Reader = New-Object IO.StreamReader($logfilePath.FullName)
    $XmlReader = [Xml.XmlReader]::Create($Reader)
    $fileStatistics = @{};
    try{
        $moves = @()
        while ($XmlReader.Read())
        {
            if ($XmlReader.IsStartElement())
            {
                if(($XmlReader.Name -eq "path") -and ($XmlReader["action"] -ne "D") -and ($XmlReader["kind"] -eq "file") )
                {
                    $originFile = $null
                    if($XmlReader["copyfrom-path"] -ne $null)
                    {
                        $originFile = $XmlReader["copyfrom-path"].Replace($modulePath,"").Trim('/')

                    }
                    $XmlReader.Read() | Out-Null
                    if(($XmlReader.Value.StartsWith($modulePath)) -and ($XmlReader.Value.EndsWith(".cs")))
                    {
                        $file = $XmlReader.Value.Replace($modulePath,"").Trim('/')

                        if($fileStatistics[$file] -eq $null)
                        {
                            $fileStatistics[$file] = 1
                        }else{
                            $fileStatistics[$file]++
                        }

                        if($originFile -ne $null)
                        {
                            $moves+= @{from=$originFile; to= $file}
                        }
                    }
                }
            }
        }

        [array]::Reverse($moves)
        foreach($move in $moves)
        {
            if($fileStatistics[$move.from] -ne $null)
            {
                $fileStatistics[$move.to]+=$fileStatistics[$move.from]
            }
        }
    }
    finally{
        $XmlReader.Dispose()
        $Reader.Dispose()
    }
    Write-Verbose "Finish processing SVN log"
    $fileStatistics
}


function Set-ScriptEncoding($Encoding){
    $OutputEncoding = New-Object -typename $Encoding
    [Console]::OutputEncoding = New-Object -typename $Encoding

}

Set-ScriptEncoding -Encoding System.Text.UTF8Encoding

Write-Verbose "Start generating raport"
$locData = Get-FilesLOC
$svnData = Get-SvnStatistics
$mergedData = Merge-StatisticData $locData $svnData
$data = $mergedData | ConvertTo-Json -Depth 255 
$indexContent = Get-Content "$PSScriptRoot\index_placeholder1.html" -Raw
$indexContent -replace '#DATA_PLACEHOLDER#',$data | Out-File $OutputFile
Write-Verbose "Finish generating raport: $OutputFile"
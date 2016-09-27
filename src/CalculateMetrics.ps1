[CmdletBinding()]
param([Parameter(Mandatory=$true)]$CheckoutDir, $OutputFile=".\index.html")

$scriptPath = if($PSScriptRoot -eq $null){"."} else {$PSScriptRoot}

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


function Get-FilesLOC
{
    <#
        .SYNOPSIS
            Generate calculate LOC for every file inside CheckoutDir
    #>
    [CmdletBinding()]
    param()
    $clocExePath = "$scriptPath\cloc-1.70.exe"
    if(-not (Test-Path $clocExePath))
    {
        $PSCmdlet.ThrowTerminatingError("Cannot find file: $clocExePath")
    }
    Write-Verbose "Start colecting LOC statistics"
    Remove-Item "$scriptPath\cloc.csv" -ErrorAction SilentlyContinue
    & $clocExePath --by-file --csv --skip-uniqueness --exclude-lang=js --out="$scriptPath\cloc.csv"  $CheckoutDir
    if(-not(Test-Path "$scriptPath\cloc.csv"))
    {
        $PSCmdlet.ThrowTerminatingError("Cannot create LOC statistics file")
    }
    Get-Content "$scriptPath\cloc.csv" -Raw | ConvertFrom-Csv -Delimiter ','    
    Write-Verbose "Finish colecting LOC statistics"
}

function Merge-StatisticData
{
     <#
        .SYNOPSIS
            Merge LOC statistics with SVN statistics data for every file in checkout directory

        .PARAMETER LocData 
            Collection with LOC for every file

        .PARAMETER SvnData
            Dictionary with number of commits for every file

    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$LocData, 
        [Parameter(Mandatory=$true)]$SvnData
    )
    
    Write-Verbose "Start merging statistic data"
    $root = Create-Node '.';
    $maxCommitCount =  ($SvnData.Values |% {$_.commits}| Measure-Object -Maximum).Maximum    
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
            $commitCount = $SvnData[$fileName].commits            
            $localRoot.size = $el.code             
            $localRoot.commits = $commitCount
            $localRoot.weight = $commitCount/$maxCommitCount
            $localRoot.authors = $SvnData[$fileName].authors.length
        }
    }
    Write-Verbose "Finish merging statistic data"
    $root
}

function Get-SvnModulePath
{
     <#
        .SYNOPSIS
            Get SVN module path for CheckoutDir
    #>
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


function Get-SvnStatistics(){
     <#
        .SYNOPSIS
            Calculate number of commits for every file inside CheckoutDir
    #>
    [CmdletBinding()]
    Param()
    Write-Verbose "Start collecting SVN log"
    $svnExePath = "$env:ProgramFiles\TortoiseSVN\bin\svn.exe"
    #svn log -v --xml -r "{2016-07-01}:HEAD" ./ > svnlogfile.log
    if(-not (Test-Path $svnExePath))
    {
        $PSCmdlet.ThrowTerminatingError("Cannot find svn.exe")
    }
    Remove-Item "$scriptPath\svnlogfile.log"
    & $svnExePath log -v --xml $CheckoutDir | Out-File "$scriptPath\svnlogfile.log" -Encoding utf8
    if(-not(Test-Path "$scriptPath\svnlogfile.log"))
    {
        $PSCmdlet.ThrowTerminatingError("Cannot collect SVN log file")
    }
    Write-Verbose "Finish collecting SVN log"
    Write-Verbose "Start processing SVN log"
    $modulePath = Get-SvnModulePath
    $logfilePath = Get-Item "$scriptPath\svnlogfile.log"
    $Reader = New-Object IO.StreamReader($logfilePath.FullName)
    $XmlReader = [Xml.XmlReader]::Create($Reader)
    $fileStatistics = @{};
    try{
        $moves = @()
        $currentAuthor = ""
        while ($XmlReader.Read())
        {
            if ($XmlReader.IsStartElement())
            {
                if($XmlReader.Name -eq "author")
                {
                    $XmlReader.Read() | Out-Null
                    $currentAuthor = $XmlReader.Value
                }
                elseif(($XmlReader.Name -eq "path") -and ($XmlReader["action"] -ne "D") -and ($XmlReader["kind"] -eq "file") )
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
                            $fileStatistics[$file] = @{commits=1; authors=@($currentAuthor)}
                        }else{
                            $fileStatistics[$file].commits++
                            if(-not $fileStatistics[$file].authors.Contains($currentAuthor))
                            {
                                $fileStatistics[$file].authors+=$currentAuthor
                            }

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
                $fileStatistics[$move.to].commits+=$fileStatistics[$move.from].commits
                $fileStatistics[$move.to].authors+=$fileStatistics[$move.from].authors
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

function Get-JiraTicketIds{
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$text)
    Select-String -InputObject $text -Pattern "([\w]+-[\d]+)" -AllMatches | % { $_.Matches } | Select-Object -ExpandProperty Value -Unique    
}

function Set-ScriptEncoding($Encoding){
    $OutputEncoding = New-Object -typename $Encoding
    [Console]::OutputEncoding = New-Object -typename $OutputEncoding

}

Set-ScriptEncoding -Encoding System.Text.UTF8Encoding

Write-Verbose "Start generating raport"
$locData = Get-FilesLOC
$svnData = Get-SvnStatistics
$mergedData = Merge-StatisticData $locData $svnData
$data = $mergedData | ConvertTo-Json -Depth 255 
$indexContent = Get-Content "$scriptPath\index_placeholder1.html" -Raw
$indexContent -replace '#DATA_PLACEHOLDER#',$data | Out-File $OutputFile
Write-Verbose "Finish generating raport: $OutputFile"
# TDfocus - récupération réseau pour les imports (exécutée dans un runspace d'arrière-plan).
# Chaque script est autonome (le bloc param() doit rester en tête) et renvoie les données brutes ; la conversion en tâches se fait
# ensuite avec les fonctions du cœur (Core\Import.ps1), testées unitairement.

$script:TdHttpPrelude = @'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
function Invoke-TdHttp {
    param([string]$Uri, [string]$Method = 'GET', [hashtable]$Headers = @{}, [string]$Body)
    $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 25 }
    if ($Body) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    $response = Invoke-WebRequest @params
    # Décodage UTF-8 explicite : Windows PowerShell 5.1 se trompe parfois de jeu de caractères.
    [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
}
'@

$script:TdIcsFetchScript = "param([string]`$Url)`n" + $script:TdHttpPrelude + @'
$uri = $Url.Trim() -replace '^webcal://', 'https://'
Invoke-TdHttp -Uri $uri
'@

$script:TdTodoistFetchScript = "param([string]`$Token)`n" + $script:TdHttpPrelude + @'
$all = New-Object System.Collections.ArrayList
$cursor = $null
for ($page = 0; $page -lt 10; $page++) {
    $uri = 'https://api.todoist.com/api/v1/tasks/filter?limit=200&query=' + [Uri]::EscapeDataString('today | overdue')
    if ($cursor) { $uri += '&cursor=' + [Uri]::EscapeDataString($cursor) }
    $json = Invoke-TdHttp -Uri $uri -Headers @{ Authorization = "Bearer $Token" } | ConvertFrom-Json
    foreach ($t in @($json.results)) { if ($null -ne $t) { [void]$all.Add($t) } }
    $cursor = $json.next_cursor
    if (-not $cursor) { break }
}
, $all.ToArray()
'@

$script:TdNotionFetchScript = "param([string]`$Token, [string]`$DatabaseId)`n" + $script:TdHttpPrelude + @'
$clean = ($DatabaseId -replace '-', '')
$match = [regex]::Match($clean, '[0-9a-fA-F]{32}')
if (-not $match.Success) { throw "Identifiant de base Notion invalide." }
$id = $match.Value
$headers = @{ Authorization = "Bearer $Token"; 'Notion-Version' = '2022-06-28' }
$all = New-Object System.Collections.ArrayList
$cursor = $null
for ($page = 0; $page -lt 10; $page++) {
    $body = @{ page_size = 100 }
    if ($cursor) { $body.start_cursor = $cursor }
    $json = Invoke-TdHttp -Uri "https://api.notion.com/v1/databases/$id/query" -Method 'POST' -Headers $headers -Body ($body | ConvertTo-Json) | ConvertFrom-Json
    foreach ($p in @($json.results)) { if ($null -ne $p) { [void]$all.Add($p) } }
    if (-not $json.has_more) { break }
    $cursor = $json.next_cursor
}
, $all.ToArray()
'@

function Get-TdFriendlyNetworkError {
    param([string]$Message)
    if (-not $Message) { return 'Erreur inconnue.' }
    if ($Message -match '401|Unauthorized|403|Forbidden') { return 'Accès refusé : vérifie le jeton (et, pour Notion, que la base est partagée avec ton intégration).' }
    if ($Message -match '404|Not Found') { return "Introuvable : vérifie l'adresse ou l'identifiant." }
    if ($Message -match '429') { return 'Trop de requêtes : réessaie dans une minute.' }
    if ($Message -match 'resolve|remote name|connect|timed out|délai|connexion|Unable to connect|No such host') { return 'Connexion impossible : vérifie ta connexion Internet.' }
    $Message
}

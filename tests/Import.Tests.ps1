BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TDfocus.Core.ps1')
    $script:Day = ConvertFrom-TdLocalDate ([DateTime]::new(2026, 10, 29, 8, 0, 0))  # jeudi
    function New-Ics([string[]]$EventLines) {
        $lines = @('BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Test//FR') + $EventLines + @('END:VCALENDAR')
        $lines -join "`r`n"
    }
    function LocalClock([DateTime]$Utc) {
        [DateTime]::SpecifyKind($Utc, [DateTimeKind]::Utc).ToLocalTime().ToString('HH:mm')
    }
}

Describe 'Import iCalendar (Google Agenda, Outlook)' {
    It "importe un événement du jour en UTC comme créneau figé" {
        $ics = New-Ics @('BEGIN:VEVENT', 'UID:a1', 'SUMMARY:Point d''équipe', 'DTSTART:20261029T130000Z', 'DTEND:20261029T134500Z', 'END:VEVENT')
        $items = ConvertFrom-TdIcs -Content $ics -DayMs $Day
        $items.Count | Should -Be 1
        $items[0].title | Should -Be "Point d'équipe"
        $items[0].minutes | Should -Be 45
        $items[0].fixedStart | Should -Be (LocalClock ([DateTime]::new(2026, 10, 29, 13, 0, 0)))
        $items[0].externalId | Should -Be 'ics:a1:2026-10-29'
    }
    It 'convertit un fuseau TZID' {
        $ics = New-Ics @('BEGIN:VEVENT', 'UID:tz', 'SUMMARY:Paris', 'DTSTART;TZID=Europe/Paris:20261029T090000', 'DURATION:PT1H30M', 'END:VEVENT')
        $items = ConvertFrom-TdIcs -Content $ics -DayMs $Day
        # 29 octobre 2026 : Paris est en UTC+1 (heure d'hiver)
        $items[0].fixedStart | Should -Be (LocalClock ([DateTime]::new(2026, 10, 29, 8, 0, 0)))
        $items[0].minutes | Should -Be 90
    }
    It 'ignore les autres jours, les annulations et déplie les lignes' {
        $ics = New-Ics @(
            'BEGIN:VEVENT', 'UID:x', 'SUMMARY:Demain', 'DTSTART:20261030T090000', 'END:VEVENT',
            'BEGIN:VEVENT', 'UID:y', 'SUMMARY:Annulé', 'STATUS:CANCELLED', 'DTSTART:20261029T090000', 'END:VEVENT',
            'BEGIN:VEVENT', 'UID:z', 'SUMMARY:Très long titre qui', ' continue\, ici', 'DTSTART:20261029T100000', 'DTEND:20261029T101500', 'BEGIN:VALARM', 'TRIGGER:-PT10M', 'END:VALARM', 'END:VEVENT'
        )
        $items = ConvertFrom-TdIcs -Content $ics -DayMs $Day
        $items.Count | Should -Be 1
        $items[0].title | Should -Be 'Très long titre quicontinue, ici'
        $items[0].fixedStart | Should -Be '10:00'
        $items[0].minutes | Should -Be 15
    }
    It 'gère les événements sur la journée entière' {
        $ics = New-Ics @('BEGIN:VEVENT', 'UID:ad', 'SUMMARY:Anniversaire', 'DTSTART;VALUE=DATE:20261028', 'DTEND;VALUE=DATE:20261030', 'END:VEVENT')
        $items = ConvertFrom-TdIcs -Content $ics -DayMs $Day
        $items[0].allDay | Should -BeTrue
        $items[0].fixedStart | Should -BeNullOrEmpty
    }
    It 'développe une récurrence hebdomadaire BYDAY' {
        $ics = New-Ics @('BEGIN:VEVENT', 'UID:w', 'SUMMARY:Sport', 'DTSTART:20261001T180000', 'DTEND:20261001T190000', 'RRULE:FREQ=WEEKLY;BYDAY=TU,TH', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $ics -DayMs $Day).Count | Should -Be 1
        $friday = $Day + 24L * 3600 * 1000
        (ConvertFrom-TdIcs -Content $ics -DayMs $friday).Count | Should -Be 0
    }
    It 'respecte INTERVAL, COUNT, UNTIL et EXDATE' {
        $every2 = New-Ics @('BEGIN:VEVENT', 'UID:i', 'SUMMARY:Un jeudi sur deux', 'DTSTART:20261022T090000', 'RRULE:FREQ=WEEKLY;INTERVAL=2', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $every2 -DayMs $Day).Count | Should -Be 0
        $count = New-Ics @('BEGIN:VEVENT', 'UID:c', 'SUMMARY:Cure', 'DTSTART:20261027T090000', 'RRULE:FREQ=DAILY;COUNT=2', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $count -DayMs $Day).Count | Should -Be 0
        $count3 = New-Ics @('BEGIN:VEVENT', 'UID:c3', 'SUMMARY:Cure', 'DTSTART:20261027T090000', 'RRULE:FREQ=DAILY;COUNT=3', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $count3 -DayMs $Day).Count | Should -Be 1
        $until = New-Ics @('BEGIN:VEVENT', 'UID:u', 'SUMMARY:Fin', 'DTSTART:20261020T090000', 'RRULE:FREQ=DAILY;UNTIL=20261028T235959Z', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $until -DayMs $Day).Count | Should -Be 0
        $ex = New-Ics @('BEGIN:VEVENT', 'UID:e', 'SUMMARY:Quotidien', 'DTSTART:20261020T090000', 'RRULE:FREQ=DAILY', 'EXDATE:20261029T090000', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $ex -DayMs $Day).Count | Should -Be 0
    }
    It 'gère le n-ième jour du mois et les occurrences modifiées' {
        $monthly = New-Ics @('BEGIN:VEVENT', 'UID:m', 'SUMMARY:Dernier jeudi', 'DTSTART:20260924T140000', 'RRULE:FREQ=MONTHLY;BYDAY=-1TH', 'END:VEVENT')
        (ConvertFrom-TdIcs -Content $monthly -DayMs $Day).Count | Should -Be 1
        $moved = New-Ics @(
            'BEGIN:VEVENT', 'UID:r', 'SUMMARY:Daily', 'DTSTART:20261020T090000', 'DTEND:20261020T091500', 'RRULE:FREQ=DAILY', 'END:VEVENT',
            'BEGIN:VEVENT', 'UID:r', 'RECURRENCE-ID:20261029T090000', 'SUMMARY:Daily (décalé)', 'DTSTART:20261029T110000', 'DTEND:20261029T111500', 'END:VEVENT'
        )
        $items = ConvertFrom-TdIcs -Content $moved -DayMs $Day
        $items.Count | Should -Be 1
        $items[0].title | Should -Be 'Daily (décalé)'
        $items[0].fixedStart | Should -Be '11:00'
    }
}

Describe 'Import de texte (Notion, Markdown, listes)' {
    It 'lit des listes à puces et cases à cocher' {
        $text = @"
# Aujourd'hui
- [ ] Écrire le rapport 45 min
- [x] Déjà fait
* Appeler Paul 10
☐ Arroser les plantes
☑ Fini
1. Préparer la réunion @14h 30m

---
Lire un chapitre
"@
        $items = ConvertFrom-TdTextList -Content $text -DefaultMinutes 20
        ($items | ForEach-Object title) -join '|' | Should -Be 'Écrire le rapport|Appeler Paul|Arroser les plantes|Préparer la réunion|Lire un chapitre'
        $items[0].minutes | Should -Be 45
        $items[2].minutes | Should -Be 20
        $items[3].fixedStart | Should -Be '14:00'
        $items[3].minutes | Should -Be 30
    }
    It 'renvoie une liste vide pour un texte vide' {
        (ConvertFrom-TdTextList -Content '   ').Count | Should -Be 0
    }
}

Describe 'Import Todoist' {
    It 'convertit les tâches du jour' {
        $json = @'
[
  { "id": "1", "content": "Payer [la facture](https://x.y)", "priority": 4, "due": { "date": "2026-10-29" }, "duration": { "amount": 15, "unit": "minute" } },
  { "id": "2", "content": "Dentiste", "priority": 1, "due": { "date": "2026-10-29T16:30:00" }, "duration": null },
  { "id": "3", "content": "Hier", "priority": 1, "due": { "date": "2026-10-28" } }
]
'@ | ConvertFrom-Json
        $items = ConvertFrom-TdTodoistTasks -Tasks $json -NowMs $Day -DefaultMinutes 25
        $items.Count | Should -Be 3
        $items[0].title | Should -Be 'Dentiste'
        $items[0].fixedStart | Should -Be '16:30'
        $items[1].title | Should -Be 'Payer la facture'
        $items[1].minutes | Should -Be 15
        $items[1].externalId | Should -Be 'todoist:1'
        $items[2].minutes | Should -Be 25
    }
}

Describe 'Import Notion' {
    It 'détecte titre, statut, durée et date' {
        $json = @'
[
  { "id": "p1", "properties": {
      "Nom": { "type": "title", "title": [ { "plain_text": "Préparer " }, { "plain_text": "slides" } ] },
      "Fait": { "type": "checkbox", "checkbox": false },
      "Durée (min)": { "type": "number", "number": 40 },
      "Date": { "type": "date", "date": { "start": "2026-10-29" } } } },
  { "id": "p2", "properties": {
      "Nom": { "type": "title", "title": [ { "plain_text": "Terminée" } ] },
      "Statut": { "type": "status", "status": { "name": "Terminé" } } } },
  { "id": "p3", "properties": {
      "Nom": { "type": "title", "title": [ { "plain_text": "Plus tard" } ] },
      "Date": { "type": "date", "date": { "start": "2026-11-05" } } } },
  { "id": "p4", "properties": {
      "Nom": { "type": "title", "title": [ { "plain_text": "Sans date" } ] } } }
]
'@ | ConvertFrom-Json
        $items = ConvertFrom-TdNotionPages -Pages $json -NowMs $Day -DefaultMinutes 25
        ($items | ForEach-Object title) -join '|' | Should -Be 'Préparer slides|Sans date'
        $items[0].minutes | Should -Be 40
        $items[1].minutes | Should -Be 25
        $items[0].externalId | Should -Be 'notion:p1'
    }
}

Describe 'Dédoublonnage des imports' {
    It 'ignore ce qui est déjà dans la liste' {
        $state = New-TdState
        $t = New-TdTask -Title 'A' -ExternalId 'todoist:1'
        Add-TdTask -State $state -Task $t -NowMs $Day
        $items = @(
            [pscustomobject]@{ title = 'A'; externalId = 'todoist:1' },
            [pscustomobject]@{ title = 'B'; externalId = 'todoist:2' },
            [pscustomobject]@{ title = 'C'; externalId = $null }
        )
        $fresh = Select-TdNewImportItems -Items $items -State $state
        ($fresh | ForEach-Object title) -join '' | Should -Be 'BC'
    }
}

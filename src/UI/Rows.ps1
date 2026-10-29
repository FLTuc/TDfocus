# TDfocus - liste « Ensuite » (glisser-déposer, édition en ligne) et liste « Terminé aujourd'hui ».

$script:TdRowXaml = @'
<Border {ns} x:Name="RowRoot" CornerRadius="14" Padding="6,7,6,7" Margin="0,0,0,6" BorderThickness="1"
        AllowDrop="True" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource LineBrush}">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <TextBlock x:Name="Handle" Text="&#xE76F;" FontFamily="{DynamicResource IconFont}" Foreground="{DynamicResource MutedBrush}"
               VerticalAlignment="Center" Margin="6,0,8,0" Cursor="SizeAll" Opacity="0.6" ToolTip="Glisser pour réordonner"/>
    <Border x:Name="CatChip" Grid.Column="1" Width="30" Height="30" CornerRadius="10" Margin="0,0,10,0" Background="{DynamicResource SurfaceAltBrush}">
      <TextBlock x:Name="CatEmoji" FontFamily="{DynamicResource EmojiFont}" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="2" VerticalAlignment="Center">
      <TextBlock x:Name="Title" FontSize="15" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource TextBrush}"/>
      <TextBlock x:Name="Sub" FontSize="12" Foreground="{DynamicResource MutedBrush}" Visibility="Collapsed" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <Button x:Name="DurationButton" Grid.Column="3" Style="{DynamicResource PillButton}" Padding="10,3" Margin="8,0,4,0" FontSize="13" ToolTip="Changer la durée"/>
    <StackPanel Grid.Column="4" Orientation="Horizontal" VerticalAlignment="Center" Margin="6,0,6,0" ToolTip="Heure de fin prévue">
      <TextBlock Text="→" Foreground="{DynamicResource MutedBrush}" Margin="0,0,5,0"/>
      <TextBlock x:Name="EndTime" FontWeight="SemiBold" Typography.NumeralAlignment="Tabular" Foreground="{DynamicResource TextBrush}"/>
    </StackPanel>
    <StackPanel x:Name="Actions" Grid.Column="5" Orientation="Horizontal" VerticalAlignment="Center">
      <StackPanel.Style>
        <Style TargetType="StackPanel">
          <Setter Property="Opacity" Value="0.35"/>
          <Style.Triggers>
            <DataTrigger Binding="{Binding IsMouseOver, ElementName=RowRoot}" Value="True">
              <Setter Property="Opacity" Value="1"/>
            </DataTrigger>
          </Style.Triggers>
        </Style>
      </StackPanel.Style>
      <Button x:Name="BtnStart" Style="{DynamicResource SmallIconButton}" Content="&#xE768;" ToolTip="Commencer maintenant"/>
      <Button x:Name="BtnComplete" Style="{DynamicResource SmallIconButton}" Content="&#xE73E;" ToolTip="Marquer comme faite"/>
      <Button x:Name="BtnEdit" Style="{DynamicResource SmallIconButton}" Content="&#xE70F;" ToolTip="Modifier"/>
      <Button x:Name="BtnDelete" Style="{DynamicResource SmallIconButton}" Content="&#xE74D;" ToolTip="Supprimer"/>
    </StackPanel>
  </Grid>
</Border>
'@

$script:TdEditorXaml = @'
<Border {ns} CornerRadius="14" Padding="14" Margin="0,0,0,8" Background="{DynamicResource SurfaceAltBrush}" BorderBrush="{DynamicResource AccentBrush}" BorderThickness="1.5">
  <StackPanel>
    <TextBlock x:Name="EditHeading" Text="Modifier la tâche" FontWeight="SemiBold" Margin="2,0,0,8" Foreground="{DynamicResource TextBrush}"/>
    <TextBox x:Name="EditTitle" Style="{DynamicResource Field}" Background="{DynamicResource SurfaceBrush}"/>
    <WrapPanel Margin="0,10,0,0">
      <StackPanel Orientation="Horizontal" Margin="0,0,18,6">
        <TextBlock Text="Durée" VerticalAlignment="Center" Margin="2,0,8,0" Foreground="{DynamicResource MutedBrush}"/>
        <TextBox x:Name="EditMinutes" Style="{DynamicResource Field}" Width="64" Background="{DynamicResource SurfaceBrush}" Padding="10,6"/>
        <TextBlock Text="min" VerticalAlignment="Center" Margin="6,0,0,0" Foreground="{DynamicResource MutedBrush}"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,6" ToolTip="Créneau figé : laisser vide pour une tâche flottante">
        <TextBlock Text="Heure fixe" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="{DynamicResource MutedBrush}"/>
        <TextBox x:Name="EditFixed" Style="{DynamicResource Field}" Width="76" Background="{DynamicResource SurfaceBrush}" Padding="10,6"/>
      </StackPanel>
    </WrapPanel>
    <WrapPanel x:Name="EditCategories" Margin="0,8,0,0"/>
    <TextBlock Text="Sous-étapes (une par ligne, facultatif)" Margin="2,6,0,4" Foreground="{DynamicResource MutedBrush}"/>
    <TextBox x:Name="EditSteps" Style="{DynamicResource Field}" Background="{DynamicResource SurfaceBrush}" AcceptsReturn="True" TextWrapping="Wrap" MinHeight="64" VerticalContentAlignment="Top" ToolTip="Découpe la tâche en petits pas : TDfocus n'affichera que l'étape en cours. « [x] » devant une étape = déjà faite."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,6,0,0">
      <Button x:Name="EditCancel" Style="{DynamicResource GhostButton}" Content="Annuler" Margin="0,0,6,0"/>
      <Button x:Name="EditSave" Style="{DynamicResource PrimaryButton}" Content="Enregistrer" Padding="18,7"/>
    </StackPanel>
  </StackPanel>
</Border>
'@

$script:TdDoneRowXaml = @'
<Border {ns} x:Name="RowRoot" CornerRadius="12" Padding="10,6,6,6" Margin="0,0,0,4" Background="Transparent">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Border Width="24" Height="24" CornerRadius="12" Background="{DynamicResource SuccessSoftBrush}" Margin="0,0,10,0" VerticalAlignment="Center">
      <TextBlock Text="&#xE73E;" FontFamily="{DynamicResource IconFont}" FontSize="11" Foreground="{DynamicResource SuccessTextBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <TextBlock x:Name="Title" Grid.Column="1" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource MutedBrush}"/>
    <TextBlock x:Name="Meta" Grid.Column="2" VerticalAlignment="Center" FontSize="12" Margin="10,0,6,0" Foreground="{DynamicResource MutedBrush}"/>
    <Button x:Name="BtnUndo" Grid.Column="3" Style="{DynamicResource SmallIconButton}" Content="&#xE7A7;" ToolTip="Remettre dans la liste"/>
  </Grid>
</Border>
'@

function Get-TdRowElements {
    param([Parameter(Mandatory)][string]$Xaml)
    $root = ConvertFrom-TdXaml $Xaml
    $map = @{ Root = $root }
    foreach ($m in [regex]::Matches($Xaml, 'x:Name="([^"]+)"')) {
        $element = $root.FindName($m.Groups[1].Value)
        if ($null -ne $element) { $map[$m.Groups[1].Value] = $element }
    }
    $map
}

function Update-TdUpNext {
    param([long]$NowMs, $Schedule)
    $ui = $script:Td.Ui
    $state = Get-TdState
    $settings = Get-TdSettings
    $list = $ui.UpNextList
    $list.Children.Clear()
    $script:Td.RowRefs = @{}

    $current = Get-TdCurrentTask $state
    if ($current -and $script:Td.EditingId -eq $current.id) {
        [void]$list.Children.Add((New-TdEditor -Task $current -Heading 'Modifier la tâche en cours'))
    }

    $count = $state.tasks.Count
    for ($i = 1; $i -lt $count; $i++) {
        $task = $state.tasks[$i]
        $item = $Schedule.items[$i]
        if ($item.gapMs -ge 60000) {
            $gap = New-TdText -Text ('Temps libre · {0} avant {1}' -f (Format-TdDurationMs $item.gapMs), $task.fixedStart) -Size 12 -Brush 'MutedBrush' -Margin '46,0,0,6'
            $gap.FontStyle = [System.Windows.FontStyles]::Italic
            [void]$list.Children.Add($gap)
        }
        if ($script:Td.EditingId -eq $task.id) {
            [void]$list.Children.Add((New-TdEditor -Task $task))
            continue
        }
        [void]$list.Children.Add((New-TdTaskRow -Task $task -Item $item -Settings $settings))
    }

    $upcoming = [Math]::Max(0, $count - 1)
    if ($upcoming -gt 0) {
        $rest = [long]0
        for ($i = 1; $i -lt $count; $i++) { $rest += [long]$Schedule.items[$i].remainingMs }
        $plural = ''
        if ($upcoming -gt 1) { $plural = 'S' }
        $ui.UpNextHeader.Text = 'ENSUITE · {0} TÂCHE{1} · {2}' -f $upcoming, $plural, (Format-TdDurationMs $rest).ToUpperInvariant()
        $ui.UpNextEmpty.Visibility = 'Collapsed'
    }
    else {
        $ui.UpNextHeader.Text = 'ENSUITE'
        $ui.UpNextEmpty.Visibility = 'Visible'
        if ($count -eq 0) { $ui.UpNextEmpty.Text = 'La file est vide.' } else { $ui.UpNextEmpty.Text = "Rien d'autre pour l'instant. C'est très bien comme ça." }
    }
    $hasTasks = $count -gt 0
    $ui.BtnClearList.Visibility = $(if ($hasTasks) { 'Visible' } else { 'Collapsed' })
    $ui.BtnSaveAsTemplate.Visibility = $(if ($hasTasks) { 'Visible' } else { 'Collapsed' })
    $parked = $state.parked.Count
    if ($parked -gt 0) {
        $ui.ParkedBar.Visibility = 'Visible'
        $ui.ParkedText.Text = $(if ($parked -gt 1) { "$parked tâches reportées à demain" } else { '1 tâche reportée à demain' })
    }
    else { $ui.ParkedBar.Visibility = 'Collapsed' }
    $script:Td.StructureKey = Get-TdStructureKey $Schedule
}

function Update-TdRowTimes {
    # Mise à jour légère : seules les heures de fin projetées changent.
    param($Schedule)
    foreach ($item in $Schedule.items) {
        $ref = $script:Td.RowRefs[$item.id]
        if (-not $ref) { continue }
        $text = Format-TdClock $item.endMs
        if ($ref.EndTime.Text -ne $text) { $ref.EndTime.Text = $text }
        if ($item.lateMs -gt 0) {
            $late = 'Créneau {0} · décalé de {1}' -f $ref.Fixed, (Format-TdDurationMs $item.lateMs)
            if ($ref.Sub.Text -ne $late) { $ref.Sub.Text = $late }
        }
    }
}

function New-TdTaskRow {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings)
    $r = Get-TdRowElements $script:TdRowXaml
    $root = $r.Root
    $id = $Task.id
    foreach ($name in @('RowRoot', 'Handle', 'DurationButton', 'BtnStart', 'BtnComplete', 'BtnEdit', 'BtnDelete')) { $r[$name].Tag = $id }
    $root.Tag = $id

    $r.Title.Text = $Task.title
    $r.Title.ToolTip = $Task.title
    $category = Get-TdCategory $Settings $Task.categoryId
    if ($category) {
        $r.CatEmoji.Text = $category.emoji
        $brush = Get-TdCategoryBrush $category $script:Td.DarkActive
        if ($brush) { $r.CatChip.Background = $brush }
        $r.CatChip.ToolTip = $category.name
    }
    else {
        $r.CatEmoji.Text = [string][char]0x2022
        $r.CatEmoji.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'MutedBrush')
    }
    $r.DurationButton.Content = Format-TdDurationMs $Task.plannedMs
    $r.EndTime.Text = Format-TdClock $Item.endMs

    $subParts = @()
    if ($Task.fixedStart) {
        if ($Item.lateMs -gt 0) {
            $subParts += 'Créneau {0} · décalé de {1}' -f $Task.fixedStart, (Format-TdDurationMs $Item.lateMs)
            $r.Sub.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OvertimeBrush')
        }
        else {
            $subParts += 'Créneau figé à {0}' -f $Task.fixedStart
        }
    }
    $progress = Get-TdStepProgress $Task
    if ($progress.total -gt 0) { $subParts += 'étapes {0}/{1}' -f $progress.done, $progress.total }
    if ($Task.elapsedMs -ge 60000) { $subParts += 'déjà {0}' -f (Format-TdDurationMs $Task.elapsedMs) }
    if ($Task.note) { $subParts += 'note' }
    if ($subParts.Count -gt 0) {
        $r.Sub.Text = $subParts -join ' · '
        $r.Sub.Visibility = 'Visible'
    }
    $script:Td.RowRefs[$id] = @{ EndTime = $r.EndTime; Sub = $r.Sub; Fixed = $Task.fixedStart }

    $r.BtnStart.Add_Click({ Start-TdTaskNowById ([string]$this.Tag) })
    $r.BtnComplete.Add_Click({ Complete-TdCurrentNow -Id ([string]$this.Tag) })
    $r.BtnEdit.Add_Click({ Open-TdEditor ([string]$this.Tag) })
    $r.BtnDelete.Add_Click({ Remove-TdTaskNow ([string]$this.Tag) })
    $r.DurationButton.Add_Click({ Show-TdDurationMenu $this })

    $root.Add_MouseLeftButtonDown({
            param($s, $e)
            if ($e.ClickCount -ge 2 -and -not (Test-TdInsideButton $e.OriginalSource $s)) {
                Open-TdEditor ([string]$s.Tag)
                $e.Handled = $true
            }
        })
    $root.ContextMenu = New-TdRowContextMenu $id
    Register-TdRowDrag $root
    $root
}

function Test-TdInsideButton {
    param($Source, $Stop)
    $node = $Source
    while ($node -and $node -ne $Stop) {
        if ($node -is [System.Windows.Controls.Primitives.ButtonBase] -or $node -is [System.Windows.Controls.TextBox]) { return $true }
        if ($node -is [System.Windows.Media.Visual] -or $node -is [System.Windows.Media.Media3D.Visual3D]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        else {
            $node = [System.Windows.LogicalTreeHelper]::GetParent($node)
        }
    }
    $false
}

function New-TdRowContextMenu {
    param([Parameter(Mandatory)][string]$Id)
    $menu = New-Object System.Windows.Controls.ContextMenu
    $entries = @(
        @('Commencer maintenant', 'start'),
        @('Monter', 'up'),
        @('Descendre', 'down'),
        @('Reporter en fin de liste', 'end'),
        @('Modifier…', 'edit'),
        @('Marquer comme faite', 'done'),
        @('Supprimer', 'delete')
    )
    foreach ($entry in $entries) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $entry[0]
        $mi.Tag = '{0}|{1}' -f $entry[1], $Id
        $mi.Add_Click({
                $parts = ([string]$this.Tag).Split('|')
                Invoke-TdRowCommand -Command $parts[0] -Id $parts[1]
            })
        [void]$menu.Items.Add([System.Windows.Controls.MenuItem]$mi)
    }
    $menu
}

function Invoke-TdRowCommand {
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$Id)
    $state = Get-TdState
    $found = Find-TdTask $state $Id
    if (-not $found) { return }
    switch ($Command) {
        'start' { Start-TdTaskNowById $Id }
        'up' {
            if ($found.index -gt 1) {
                Move-TdTask -State $state -From $found.index -To ($found.index - 1) -NowMs (Get-TdNowMs)
                Complete-TdChange -Replan
            }
        }
        'down' {
            if ($found.index -lt $state.tasks.Count - 1) {
                Move-TdTask -State $state -From $found.index -To ($found.index + 1) -NowMs (Get-TdNowMs)
                Complete-TdChange -Replan
            }
        }
        'end' { Move-TdTaskRelative -DraggedId $Id -ToEnd }
        'edit' { Open-TdEditor $Id }
        'done' { Complete-TdCurrentNow -Id $Id }
        'delete' { Remove-TdTaskNow $Id }
    }
}

function Show-TdDurationMenu {
    param([Parameter(Mandatory)]$Button)
    $id = [string]$Button.Tag
    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($m in @(5, 10, 15, 20, 25, 30, 45, 60, 90)) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = Format-TdMinutes $m
        $mi.Tag = '{0}|{1}' -f $m, $id
        $mi.Add_Click({
                $parts = ([string]$this.Tag).Split('|')
                [void](Update-TdTask -State (Get-TdState) -Id $parts[1] -Changes @{ minutes = [double]$parts[0] })
                Complete-TdChange -Replan
            })
        [void]$menu.Items.Add([System.Windows.Controls.MenuItem]$mi)
    }
    $menu.PlacementTarget = $Button
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
}

function Register-TdRowDrag {
    param([Parameter(Mandatory)]$Row)
    $Row.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            if (Test-TdInsideButton $e.OriginalSource $s) { $script:Td.DragStart = $null; return }
            $script:Td.DragStart = $e.GetPosition($script:Td.Window)
            $script:Td.DragId = [string]$s.Tag
        })
    $Row.Add_PreviewMouseMove({
            param($s, $e)
            if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
            if ($null -eq $script:Td.DragStart -or $script:Td.DragId -ne [string]$s.Tag -or $script:Td.Dragging) { return }
            $p = $e.GetPosition($script:Td.Window)
            $dx = [Math]::Abs($p.X - $script:Td.DragStart.X)
            $dy = [Math]::Abs($p.Y - $script:Td.DragStart.Y)
            if ($dx -lt [System.Windows.SystemParameters]::MinimumHorizontalDragDistance -and $dy -lt [System.Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
            $script:Td.Dragging = $true
            $script:Td.PendingDrop = $null
            $s.Opacity = 0.45
            try {
                $data = [System.Windows.DataObject](New-Object System.Windows.DataObject ('TDfocusTask', [string]$s.Tag))
                [void][System.Windows.DragDrop]::DoDragDrop([System.Windows.DependencyObject]$s, [System.Windows.DataObject]$data, [System.Windows.DragDropEffects]::Move)
            }
            finally {
                $s.Opacity = 1
                $script:Td.Dragging = $false
                $script:Td.DragStart = $null
                $script:Td.DragId = $null
            }
            $drop = $script:Td.PendingDrop
            $script:Td.PendingDrop = $null
            if ($drop) {
                Move-TdTaskRelative -DraggedId $drop.Id -TargetId $drop.TargetId -Before ([bool]$drop.Before) -ToEnd:([bool]$drop.End) -ToFront:([bool]$drop.Front)
            }
            else {
                Update-TdView
            }
        })
    $Row.Add_DragOver({
            param($s, $e)
            if (-not $e.Data.GetDataPresent('TDfocusTask')) { $e.Effects = 'None'; $e.Handled = $true; return }
            $e.Effects = 'Move'
            $before = $e.GetPosition($s).Y -lt ($s.ActualHeight / 2)
            Set-TdDropIndicator $s $before
            $e.Handled = $true
        })
    $Row.Add_DragLeave({
            param($s, $e)
            Set-TdDropIndicator $s $null
        })
    $Row.Add_Drop({
            param($s, $e)
            Set-TdDropIndicator $s $null
            if (-not $e.Data.GetDataPresent('TDfocusTask')) { return }
            $before = $e.GetPosition($s).Y -lt ($s.ActualHeight / 2)
            $script:Td.PendingDrop = @{ Id = [string]$e.Data.GetData('TDfocusTask'); TargetId = [string]$s.Tag; Before = $before }
            $e.Handled = $true
        })
}

function Set-TdDropIndicator {
    param([Parameter(Mandatory)]$Row, $Before)
    if ($null -eq $Before) {
        $Row.BorderThickness = New-Object System.Windows.Thickness 1
        $Row.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'LineBrush')
        return
    }
    if ($Before) { $Row.BorderThickness = New-Object System.Windows.Thickness 1, 3, 1, 1 }
    else { $Row.BorderThickness = New-Object System.Windows.Thickness 1, 1, 1, 3 }
    $Row.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'AccentBrush')
}

# ---------------------------------------------------------------- édition en ligne

function Open-TdEditor {
    param([Parameter(Mandatory)][string]$Id)
    $script:Td.EditingId = $Id
    if ($script:Td.FocusMode) { Set-TdFocusMode $false }
    Update-TdView
}

function New-TdEditor {
    param([Parameter(Mandatory)]$Task, [string]$Heading = 'Modifier la tâche')
    $r = Get-TdRowElements $script:TdEditorXaml
    $r.EditHeading.Text = $Heading
    $r.EditTitle.Text = $Task.title
    $r.EditMinutes.Text = [string][Math]::Round([long]$Task.plannedMs / 60000)
    $r.EditFixed.Text = [string]$Task.fixedStart
    $r.EditSteps.Text = ConvertTo-TdStepsText $Task
    $r.EditSave.Tag = $Task.id
    $script:Td.EditorRefs = $r
    $script:Td.EditorCategory = $Task.categoryId
    foreach ($cat in (Get-TdSettings).categories) {
        $chip = New-TdChip -Content ('{0} {1}' -f $cat.emoji, $cat.name) -Tag $cat.id -Checked ($cat.id -eq $Task.categoryId) -OnClick {
            if ($this.IsChecked) {
                foreach ($c in $script:Td.EditorRefs.EditCategories.Children) { if ($c -ne $this) { $c.IsChecked = $false } }
                $script:Td.EditorCategory = [string]$this.Tag
            }
            else { $script:Td.EditorCategory = $null }
        }
        [void]$r.EditCategories.Children.Add($chip)
    }
    $r.EditSave.Add_Click({ Save-TdEditor })
    $r.EditCancel.Add_Click({ $script:Td.EditingId = $null; Update-TdView })
    $keyHandler = {
        param($s, $e)
        if ($e.Key -eq 'Return') { Save-TdEditor; $e.Handled = $true }
    }
    foreach ($box in @($r.EditTitle, $r.EditMinutes, $r.EditFixed)) { $box.Add_KeyDown($keyHandler) }
    $editTitle = $r.EditTitle
    [void]$r.Root.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [Action] {
            try { $editTitle.Focus() | Out-Null; $editTitle.SelectAll() } catch { $null = $_ }
        }.GetNewClosure())
    $r.Root
}

function Save-TdEditor {
    $r = $script:Td.EditorRefs
    if (-not $r) { return }
    $id = [string]$r.EditSave.Tag
    $changes = @{ categoryId = $script:Td.EditorCategory; stepsText = $r.EditSteps.Text }
    $title = $r.EditTitle.Text.Trim()
    if ($title) { $changes.title = $title }
    $minutesText = $r.EditMinutes.Text.Trim().Replace(',', '.')
    $minutes = 0.0
    if ([double]::TryParse($minutesText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$minutes) -and $minutes -ge 1) {
        $changes.minutes = $minutes
    }
    $fixedText = $r.EditFixed.Text.Trim()
    if ($fixedText) {
        $fixed = ConvertTo-TdClockText $fixedText
        if (-not $fixed) {
            Show-TdToast -Text 'Heure fixe non reconnue : utilise le format 14:30 (ou laisse vide).'
            return
        }
        $changes.fixedStart = $fixed
    }
    else {
        $changes.fixedStart = $null
    }
    [void](Update-TdTask -State (Get-TdState) -Id $id -Changes $changes)
    $script:Td.EditingId = $null
    $script:Td.EditorRefs = $null
    Complete-TdChange -Replan
}

# ---------------------------------------------------------------- terminées

function Update-TdDoneList {
    $ui = $script:Td.Ui
    $state = Get-TdState
    $list = $ui.DoneList
    $list.Children.Clear()
    $count = $state.done.Count
    if ($count -eq 0) {
        $ui.BtnDoneToggle.Visibility = 'Collapsed'
        return
    }
    $ui.BtnDoneToggle.Visibility = 'Visible'
    $focus = [long]0
    foreach ($t in $state.done) { $focus += [long]$t.elapsedMs }
    $ui.DoneHeader.Text = "TERMINÉ AUJOURD'HUI · {0} · {1} DE FOCUS" -f $count, (Format-TdDurationMs $focus).ToUpperInvariant()
    if ($script:Td.DoneExpanded) { $ui.DoneChevron.Text = [string][char]0xE70D } else { $ui.DoneChevron.Text = [string][char]0xE76C }
    if (-not $script:Td.DoneExpanded) { return }
    for ($i = $count - 1; $i -ge 0; $i--) {
        $task = $state.done[$i]
        $r = Get-TdRowElements $script:TdDoneRowXaml
        $r.Title.Text = $task.title
        $r.Title.ToolTip = $task.title
        $actual = 'non chronométrée'
        if ($task.elapsedMs -ge 30000) { $actual = 'réel ' + (Format-TdDurationMs $task.elapsedMs) }
        $r.Meta.Text = 'prévu {0} · {1} · {2}' -f (Format-TdDurationMs $task.estimateMs), $actual, (Format-TdClock ([long]$task.completedAt))
        $r.BtnUndo.Tag = $task.id
        $r.BtnUndo.Add_Click({ Undo-TdCompleteNow -Id ([string]$this.Tag) })
        [void]$list.Children.Add($r.Root)
    }
}

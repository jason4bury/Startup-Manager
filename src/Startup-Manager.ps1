<#
.SYNOPSIS
    Startup Manager - See what runs when Windows starts, and turn things off safely.

.DESCRIPTION
    PowerShell/WPF tool for seeing and turning off what runs when Windows starts.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "Startup Manager v<version>\" release folders, their zips and
                                        "Startup Manager.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\Startup Manager

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Startup Manager v<version>".
$script:AppName     = 'Startup Manager'
$script:AppVersion  = '1.00'
$script:Description = 'PowerShell/WPF tool for seeing and turning off what runs when Windows starts'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Startup-Manager'
$script:IsPrivate   = $false  # public tool: settings and data in %APPDATA%\<App Name>
$script:AppId       = 'jason4bury.Startup-Manager'   # taskbar ID; the shortcut made by New-StartupManagerShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\Startup Manager v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or a release folder (each version has its own, so data kept
       there would be left behind by the next version). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    # Source\src\<script> or Builds\<App> v<x.yy>\<script>: <project> is two levels up.
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')   # an unpacked release zip somewhere else
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}


function Get-AppSetting {
    <# Settings from settings.json in the data folder: the look. #>
    $s = @{ Look = 'Light' }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = [string]$p.Value }
        } catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Save-AppSetting {
    try { [pscustomobject]$script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look: Light, Dark or System (follow Windows). Used from the next start.
# ---------------------------------------------------------------------------
$script:Settings = Get-AppSetting
function Test-DarkLook {
    switch ($script:Settings.Look) {
        'Dark' { return $true }
        'System' {
            try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) }
            catch { return $false }
        }
        default { return $false }
    }
}
$script:Dark = Test-DarkLook
$script:Palette = if ($script:Dark) {
    @{ Page = '#16191E'; Card = '#1F242B'; Line = '#343B45'; Ink = '#E6E9EE'; Soft = '#9AA3AE'; Accent = '#4C9BE8'; AccentInk = '#FFFFFF'
       Field = '#14171B'; UpdateBack = '#3A3022'; Hover = '#2A313A'; Select = '#24425F'; Good = '#4CC38A'; Warn = '#E0A040'; Bad = '#F07178'; Changed = '#2B3A2E' }
} else {
    @{ Page = '#F3F5F8'; Card = '#FFFFFF'; Line = '#D7DCE3'; Ink = '#1E2530'; Soft = '#5E6875'; Accent = '#1F6FBF'; AccentInk = '#FFFFFF'
       Field = '#FFFFFF'; UpdateBack = '#FFF4E0'; Hover = '#EAF0F7'; Select = '#D6E6F7'; Good = '#1E8A57'; Warn = '#9A5B00'; Bad = '#B3261E'; Changed = '#E7F5EC' }
}
$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Key) { return $script:BrushConv.ConvertFromString($script:Palette[$Key]) }

function Set-TitleBar([Windows.Window]$Window) {
    <# A dark title bar in the dark look (Windows 10 20H1 and later; older Windows ignores it). #>
    if (-not $script:Dark) { return }
    try {
        if (-not ('SmDwm' -as [type])) { Add-Type -Namespace '' -Name 'SmDwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = 1; [void][SmDwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { Write-Verbose 'no dark title bar' }
}

function Expand-Xaml([string]$Xaml) {
    <# Puts the look's colours into a window's XAML ({Page}, {Ink} ...). #>
    foreach ($k in $script:Palette.Keys) { $Xaml = $Xaml.Replace("{$k}", $script:Palette[$k]) }
    return $Xaml
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $Xaml))))
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $w.Add_SourceInitialized({ Set-TitleBar $this })
    return $w
}

# Shared styles: rounded buttons (normal and accent), text boxes and the list.
$script:Styles = @'
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Background" Value="{Card}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Select}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{Accent}"/><Setter Property="Foreground" Value="{AccentInk}"/><Setter Property="BorderBrush" Value="{Accent}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Opacity" Value="0.7"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <!-- Slim rounded scroll bars: a thin handle on a clear track, no arrow buttons. It widens a
         little while the pointer is over it and darkens on hover and drag. -->
    <Style x:Key="BuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="T" CornerRadius="4" Background="{Line}"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Soft}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center" Margin="0,3">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Width" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Height="6" VerticalAlignment="Center" Margin="3,0">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Height" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="Padding" Value="6,4"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
'@

#region MESSAGES
# ---------------------------------------------------------------------------
#  Messages and questions in the app's own look (not Windows' grey MessageBox)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="460" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <TextBlock x:Name="MsgText" TextWrapping="Wrap" LineHeight="20"/>
    <TextBox x:Name="MsgInput" Margin="0,12,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="MsgYes" Style="{StaticResource Accent}" MinWidth="80" IsDefault="True"/>
      <Button x:Name="MsgNo" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-AppMessage {
    <# A message, a question (with -NoText: $true for the first button) or, with -Ask,
       a question with a text box (returns the text, or $null when cancelled). #>
    param([Parameter(Mandatory)][string]$Text, [string]$Title = $script:AppName, [string]$YesText = 'OK', [string]$NoText,
          [switch]$Ask, [string]$Default = '', [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:MessageXaml $Owner
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo'); $box = $w.FindName('MsgInput')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText } else { $no.Visibility = 'Collapsed'; $yes.Margin = '0'; $yes.IsCancel = $true }
    if ($Ask) { $box.Visibility = 'Visible'; $box.Text = $Default; $w.Add_ContentRendered({ $box.Focus(); $box.SelectAll() }) }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; $w.Close() })
    $no.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    if ($Ask) { if ($script:MsgAnswer) { return $box.Text.Trim() } else { return $null } }
    return $script:MsgAnswer
}
#endregion MESSAGES

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style): logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22" MaxWidth="440">
    <StackPanel Orientation="Horizontal">
      <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AboutVersion" Foreground="{Soft}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
    <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{Soft}"/>
    <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
    <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{Soft}"/>
    <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Startup-Manager.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

#region STARTUP
# ---------------------------------------------------------------------------
#  What starts with Windows. Turning something off works the way Task Manager's
#  Startup page does: the entry stays where it is and Windows is told to skip it
#  (StartupApproved), so it can be turned on again at any time. Nothing is deleted.
# ---------------------------------------------------------------------------
if (-not ('SmItem' -as [type])) {
    Add-Type -TypeDefinition @'
public class SmItem {
    public string Name { get; set; }
    public string Publisher { get; set; }
    public string Command { get; set; }
    public string File { get; set; }
    public string Where { get; set; }        // shown: Run key / Startup folder / Scheduled task
    public string Kind { get; set; }         // RunUser, RunMachine, RunMachine32, FolderUser, FolderCommon, Task
    public bool Enabled { get; set; }
    public string State { get; set; }        // On / Off
    public bool NeedsAdmin { get; set; }
    public string Approved { get; set; }     // StartupApproved key (registry path)
    public string ApprovedName { get; set; }
    public string TaskPath { get; set; }
    public string TaskName { get; set; }
    public string Note { get; set; }         // why to think twice before turning it off
    public string Tip { get { return ApprovedName != null && ApprovedName != "" && ApprovedName != Name ? (Note != null ? Note + " " : "") + "(Entry: " + ApprovedName + ")" : Note; } }
    public int Severity { get; set; }        // 0 normal, 1 think twice, 2 file missing
}
'@
}

$script:ApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
# Turning these off can weaken security or break the PC, so the app asks first.
$script:Careful = 'SecurityHealth|Windows Security|Defender|ESET|Norton|McAfee|Avast|AVG|Bitdefender|Kaspersky|Malwarebytes|Sophos|Trend Micro|Realtek|Intel|NVIDIA|AMD|Synaptics|Logitech'
# Programs that only run a script: the script is what starts, not Microsoft's program.
$script:ScriptHosts = 'powershell.exe|pwsh.exe|cmd.exe|wscript.exe|cscript.exe|conhost.exe|mshta.exe|rundll32.exe'

function Get-CommandFile([string]$Command) {
    <# The program a start-up command runs: the quoted path, or the text up to .exe. #>
    if (-not $Command) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); if ($end -gt 1) { return $c.Substring(1, $end - 1) } }
    $m = [regex]::Match($c, '^(.+?\.(exe|cmd|bat|com|lnk|vbs|ps1))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($c -split '\s')[0]
}

function Get-Publisher([string]$File) {
    if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    try { return [string][Diagnostics.FileVersionInfo]::GetVersionInfo($File).CompanyName } catch { return '' }
}

function Test-Approved([string]$Hive, [string]$Sub, [string]$Name) {
    <# $true when Windows will start it: no StartupApproved value, or one whose first byte is even. #>
    try {
        $k = [Microsoft.Win32.Registry]::$Hive.OpenSubKey("$script:ApprovedBase\$Sub")
        if (-not $k) { return $true }
        $v = $k.GetValue($Name); $k.Close()
        if ($v -is [byte[]] -and $v.Length) { return (($v[0] -band 1) -eq 0) }
    } catch { Write-AppLog "StartupApproved read: $($_.Exception.Message)" }
    return $true
}

function New-Item2($Name, $Command, $File, $Where, $Kind, $Enabled, $NeedsAdmin, $Approved, $ApprovedName) {
    $i = New-Object SmItem
    $i.Name = $Name; $i.Command = $Command; $i.File = $File; $i.Where = $Where; $i.Kind = $Kind
    $i.Enabled = $Enabled; $i.State = if ($Enabled) { 'On' } else { 'Off' }
    $i.NeedsAdmin = $NeedsAdmin; $i.Approved = $Approved; $i.ApprovedName = $ApprovedName
    $i.Publisher = Get-Publisher $File
    if ($File -and [IO.Path]::GetFileName($File) -match "^($script:ScriptHosts)$") { $i.Publisher = "Script ($([IO.Path]::GetFileName($File)))" }
    elseif ($File -and $Kind -ne 'Task' -and (Test-Path -LiteralPath $File -PathType Leaf)) {
        # The program's own name, as Task Manager shows it (IDMan -> Internet Download Manager)
        try { $d = [Diagnostics.FileVersionInfo]::GetVersionInfo($File).FileDescription; if ($d -and $d.Trim().Length -gt 2) { $i.Name = $d.Trim() } } catch { Write-Verbose 'no description' }
    }
    $i.Name = $i.Name -replace '-S-1-5-[\d-]+$', ''   # tasks named after your account's ID
    if ($File -and -not (Test-Path -LiteralPath $File)) { $i.Note = "The program isn't there any more: $File"; $i.Severity = 2 }
    elseif ("$($i.Publisher) $Name $($i.Name)" -match $script:Careful) { $i.Note = 'Part of Windows, security software or a device driver: think twice before turning it off.'; $i.Severity = 1 }
    return $i
}

function Get-StartupItems {
    $list = New-Object Collections.Generic.List[SmItem]
    # 1. Run keys: this account, then all users (64-bit and 32-bit programs)
    $runs = @(
        @{ Hive = 'CurrentUser'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run'; Kind = 'RunUser'; Where = 'Your account (registry)'; Admin = $false },
        @{ Hive = 'LocalMachine'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run'; Kind = 'RunMachine'; Where = 'All users (registry)'; Admin = $true },
        @{ Hive = 'LocalMachine'; Key = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Sub = 'Run32'; Kind = 'RunMachine32'; Where = 'All users (registry, 32-bit)'; Admin = $true }
    )
    foreach ($r in $runs) {
        try {
            $k = [Microsoft.Win32.Registry]::($r.Hive).OpenSubKey($r.Key)
            if (-not $k) { continue }
            foreach ($n in $k.GetValueNames()) {
                if (-not $n) { continue }
                $cmd = [string]$k.GetValue($n)
                $hivePath = if ($r.Hive -eq 'CurrentUser') { 'HKCU' } else { 'HKLM' }
                $list.Add((New-Item2 $n $cmd (Get-CommandFile $cmd) $r.Where $r.Kind (Test-Approved $r.Hive $r.Sub $n) $r.Admin "${hivePath}:\$script:ApprovedBase\$($r.Sub)" $n))
            }
            $k.Close()
        } catch { Write-AppLog "Run key $($r.Key): $($_.Exception.Message)" }
    }
    # 2. Startup folders: yours, then all users'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($f in @(@{ Dir = [Environment]::GetFolderPath('Startup'); Kind = 'FolderUser'; Where = 'Your Startup folder'; Hive = 'CurrentUser'; Admin = $false },
                     @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Kind = 'FolderCommon'; Where = 'All users'' Startup folder'; Hive = 'LocalMachine'; Admin = $true })) {
        if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $target = $file.FullName; $cmd = $file.FullName
            if ($file.Extension -eq '.lnk') { try { $l = $shell.CreateShortcut($file.FullName); if ($l.TargetPath) { $target = $l.TargetPath; $cmd = "`"$($l.TargetPath)`" $($l.Arguments)".Trim() } } catch { Write-Verbose 'no target' } }
            $hivePath = if ($f.Hive -eq 'CurrentUser') { 'HKCU' } else { 'HKLM' }
            $list.Add((New-Item2 ([IO.Path]::GetFileNameWithoutExtension($file.Name)) $cmd $target $f.Where $f.Kind (Test-Approved $f.Hive 'StartupFolder' $file.Name) $f.Admin "${hivePath}:\$script:ApprovedBase\StartupFolder" $file.Name))
        }
    }
    # 3. Scheduled tasks that start when you sign in or the PC starts (not Windows' own)
    try {
        foreach ($t in Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) {
            $starts = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' })
            if (-not $starts.Count) { continue }
            $act = @($t.Actions)[0]
            $cmd = if ($act.Execute) { "`"$($act.Execute)`" $($act.Arguments)".Trim() } else { '(not a program)' }
            $file = if ($act.Execute) { [Environment]::ExpandEnvironmentVariables($act.Execute.Trim('"')) } else { $null }
            $when = if (@($starts | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count) { 'Scheduled task (when the PC starts)' } else { 'Scheduled task (when you sign in)' }
            $i = New-Item2 $t.TaskName $cmd $file $when 'Task' ($t.State -ne 'Disabled') $true '' ''
            $i.TaskPath = $t.TaskPath; $i.TaskName = $t.TaskName
            $list.Add($i)
        }
    } catch { Write-AppLog "Scheduled tasks: $($_.Exception.Message)" }
    return , $list.ToArray()
}

function Invoke-Elevated([string]$Script) {
    <# Runs a short script as administrator (Windows asks first). Returns $false if the prompt was cancelled. #>
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'; $Script"))
    try {
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
        if ($p.ExitCode -ne 0) { throw "the change didn't work (exit code $($p.ExitCode))" }
        return $true
    } catch [ComponentModel.Win32Exception] { return $false }
}

function Set-StartupItem([SmItem]$Item, [bool]$On) {
    <# Turns one item on or off. Registry and Startup-folder items: a StartupApproved value
       (2 = on, 3 = off, then the time), as Task Manager writes it. Tasks: enabled or disabled. #>
    if ($Item.Kind -eq 'Task') {
        $cmd = if ($On) { 'Enable-ScheduledTask' } else { 'Disable-ScheduledTask' }
        $tp = $Item.TaskPath.Replace("'", "''"); $tn = $Item.TaskName.Replace("'", "''")
        try { & $cmd -TaskPath $Item.TaskPath -TaskName $Item.TaskName -ErrorAction Stop | Out-Null; return $true }
        catch { return (Invoke-Elevated "$cmd -TaskPath '$tp' -TaskName '$tn' | Out-Null") }
    }
    $bytes = New-Object byte[] 12
    $bytes[0] = if ($On) { 2 } else { 3 }
    if (-not $On) { [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($bytes, 4) }
    if (-not $Item.NeedsAdmin) {
        $sub = $Item.Approved.Substring(6)   # after "HKCU:\"
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub)
        $k.SetValue($Item.ApprovedName, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary); $k.Close()
        return $true
    }
    $list = ($bytes | ForEach-Object { $_ }) -join ','
    $key = $Item.Approved.Replace("'", "''"); $name = $Item.ApprovedName.Replace("'", "''")
    return (Invoke-Elevated "if (-not (Test-Path '$key')) { New-Item -Path '$key' -Force | Out-Null }; Set-ItemProperty -Path '$key' -Name '$name' -Value ([byte[]]@($list)) -Type Binary")
}
#endregion STARTUP

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @'
WHAT IT DOES
Startup Manager lists everything that starts when Windows starts or when you sign in, and lets you turn things off (and on again) safely.

WHERE THINGS COME FROM
Your account (registry): programs set to start for you. All users (registry): programs set to start for everyone on this PC. Startup folders: shortcuts in your Startup folder or the all-users one. Scheduled tasks: tasks (not Windows' own) that run when you sign in or the PC starts.

TURNING THINGS OFF
Select a line and press Turn off; Turn on puts it back. It works the same way as Task Manager's Startup page: nothing is deleted or uninstalled, Windows just skips it at the next start. Items for all users and scheduled tasks need administrator rights, so Windows asks first. The change takes effect the next time you sign in or restart.

THINK TWICE
Lines in amber are part of Windows, security software (such as your antivirus) or a device driver; the app asks before turning them off. Lines in red point at a program that isn't there any more: they are safe to turn off.

THE LIST
Type in the search box to find something. Open file location shows the program in Explorer. Refresh reads the list again (F5).

LOOK
The Look button switches between Light, Dark and the same as Windows, from the next start.
'@

function Show-Help {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="560" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,18,22,16">
    <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="HelpText" TextWrapping="Wrap" LineHeight="20"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Title = "$script:AppName Help"
    $w.FindName('HelpText').Text = $script:HelpText
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1180" Height="680" MinWidth="760" MinHeight="400" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
    <Style x:Key="StateText" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="{Good}"/>
      <Style.Triggers><DataTrigger Binding="{Binding Enabled}" Value="False"><Setter Property="Foreground" Value="{Soft}"/></DataTrigger></Style.Triggers>
    </Style>
    <Style x:Key="NameText" TargetType="TextBlock">
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Tip}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Severity}" Value="1"><Setter Property="Foreground" Value="{Warn}"/></DataTrigger>
        <DataTrigger Binding="{Binding Severity}" Value="2"><Setter Property="Foreground" Value="{Bad}"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Cell" TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="ToolTip" Value="{Binding Text, RelativeSource={RelativeSource Self}}"/></Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{Card}"/><Setter Property="Foreground" Value="{Soft}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,7"/><Setter Property="BorderBrush" Value="{Line}"/><Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="{Card}"/><Setter Property="Foreground" Value="{Ink}"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{Hover}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="DataGridCell">
        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{Select}"/><Setter Property="Foreground" Value="{Ink}"/></Trigger></Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="{Card}" BorderBrush="{Line}" BorderThickness="0,1,0,0" Padding="18,10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="BtnLook"/>
          <Button x:Name="BtnHelp" Content="Help"/>
          <Button x:Name="BtnAbout" Content="About" Margin="0"/>
        </StackPanel>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Foreground="{Soft}"/>
      </DockPanel>
    </Border>
    <DockPanel DockPanel.Dock="Top" Margin="18,14,18,0">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Grid Width="220" Margin="0,0,8,0">
          <TextBox x:Name="TxtSearch" ToolTip="Find a program"/>
          <TextBlock x:Name="TxtHint" Text="Search" Foreground="{Soft}" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Grid>
        <Button x:Name="BtnRefresh" Content="Refresh" ToolTip="Read the list again (F5)" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="TxtSummary" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <DockPanel DockPanel.Dock="Bottom" Margin="18,0,18,12">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <Button x:Name="BtnOpen" Content="Open file location" IsEnabled="False"/>
        <Button x:Name="BtnOn" Content="Turn on" IsEnabled="False"/>
        <Button x:Name="BtnOff" Content="Turn off" Style="{StaticResource Accent}" IsEnabled="False" Margin="0"/>
      </StackPanel>
      <TextBlock x:Name="TxtNote" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="{Soft}" Margin="0,0,12,0"/>
    </DockPanel>
    <DataGrid x:Name="Grid" Margin="18,12,18,12" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" HeadersVisibility="Column" RowHeaderWidth="0"
              Background="{Card}" RowBackground="{Card}" Foreground="{Ink}" BorderBrush="{Line}" BorderThickness="1"
              GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{Line}" CanUserResizeRows="False">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Starts" Width="70" Binding="{Binding State}" ElementStyle="{StaticResource StateText}" SortMemberPath="Enabled"/>
        <DataGridTextColumn Header="Name" Width="1.6*" Binding="{Binding Name}" ElementStyle="{StaticResource NameText}"/>
        <DataGridTextColumn Header="Publisher" Width="1.3*" Binding="{Binding Publisher}" ElementStyle="{StaticResource Cell}"/>
        <DataGridTextColumn Header="From" Width="1.6*" Binding="{Binding Where}" ElementStyle="{StaticResource Cell}"/>
        <DataGridTextColumn Header="Command" Width="3*" Binding="{Binding Command}" ElementStyle="{StaticResource Cell}"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Set-Status([string]$Text, [string]$Tone = 'Soft') {
    $script:UI.TxtStatus.Text = $Text
    $script:UI.TxtStatus.Foreground = Get-Brush $Tone
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { Write-AppLog "Error: $($_.Exception.Message)"; [void](Show-AppMessage "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath") }
}

$script:Items = New-Object Collections.ObjectModel.ObservableCollection[SmItem]

function Update-List([string]$Keep) {
    $script:Items.Clear()
    $all = Get-StartupItems   # one array: Windows PowerShell would pass it down a pipe as a single item
    foreach ($i in ($all | Sort-Object @{ e = { -not $_.Enabled } }, Name)) { $script:Items.Add($i) }
    $on = @($script:Items | Where-Object Enabled).Count; $off = $script:Items.Count - $on
    $script:UI.TxtSummary.Text = "$($script:Items.Count) things start with Windows: $on on, $off off"
    if ($Keep) { $script:UI.Grid.SelectedItem = @($script:Items | Where-Object { "$($_.Kind)|$($_.Name)" -eq $Keep }) | Select-Object -First 1 }
    Update-Buttons
}

function Update-Filter {
    $q = $script:UI.TxtSearch.Text.Trim()
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $test = { param($i) (-not $q) -or ($i.Name -like "*$q*") -or ($i.Publisher -like "*$q*") -or ($i.Command -like "*$q*") }.GetNewClosure()
    $view.Filter = [Predicate[object]]$test
}

function Update-Buttons {
    $i = $script:UI.Grid.SelectedItem
    $ui = $script:UI
    $has = $i -is [SmItem]
    $ui.BtnOff.IsEnabled = $has -and $i.Enabled
    $ui.BtnOn.IsEnabled = $has -and -not $i.Enabled
    $ui.BtnOpen.IsEnabled = $has -and $i.File -and (Test-Path -LiteralPath $i.File)
    $shield = if ($has -and $i.NeedsAdmin) { '  (Windows asks for administrator rights)' } else { '' }
    $ui.TxtNote.Text = if (-not $has) { 'Select a line to turn it off or on. Nothing is deleted: it can always be turned on again.' }
                       elseif ($i.Note) { "$($i.Note)$shield" } else { "$($i.Where).$shield" }
    $ui.TxtNote.Foreground = Get-Brush $(if ($has -and $i.Severity -eq 2) { 'Bad' } elseif ($has -and $i.Severity -eq 1) { 'Warn' } else { 'Soft' })
}

function Switch-Selected([bool]$On) {
    $i = $script:UI.Grid.SelectedItem
    if (-not ($i -is [SmItem])) { return }
    if (-not $On -and $i.Severity -eq 1) {
        if (-not (Show-AppMessage "$($i.Name) is part of Windows, security software or a device driver.`n`nTurning it off can stop it protecting the PC or a device working properly. Turn it off anyway?" -YesText 'Turn it off' -NoText 'Leave it on')) { return }
    }
    $verb = if ($On) { 'on' } else { 'off' }
    Set-Status "Turning $($i.Name) $verb..."
    $ok = Set-StartupItem $i $On
    if (-not $ok) { Set-Status "Nothing changed: the administrator prompt was cancelled." 'Warn'; return }
    Write-AppLog "Turned ${verb}: $($i.Name) ($($i.Where))"
    Update-List "$($i.Kind)|$($i.Name)"
    Set-Status "$($i.Name) is turned $verb. It takes effect the next time you sign in or restart." 'Good'
}

try {
    $window = New-XamlWindow $mainXaml
    $script:Window = $window
    $window.Title = "$script:AppName v$script:AppVersion"
    $icon = Get-AssetImage 'Startup-Manager.ico'
    if ($icon) { $window.Icon = $icon }
    $ui = @{}
    foreach ($n in 'BtnLook', 'BtnHelp', 'BtnAbout', 'TxtStatus', 'TxtSummary', 'TxtSearch', 'TxtHint', 'BtnRefresh', 'BtnOpen', 'BtnOn', 'BtnOff', 'TxtNote', 'Grid') { $ui[$n] = $window.FindName($n) }
    $script:UI = $ui
    $setLook = { $ui.BtnLook.Content = switch ($script:Settings.Look) { 'Dark' { 'Look: Dark' } 'System' { 'Look: Auto' } default { 'Look: Light' } } }
    & $setLook
    $ui.BtnLook.ToolTip = 'Light, dark, or the same as Windows. Used the next time the app starts.'
    $ui.BtnLook.Add_Click({
        $script:Settings.Look = switch ($script:Settings.Look) { 'Light' { 'Dark' } 'Dark' { 'System' } default { 'Light' } }
        Save-AppSetting; & $setLook
        Set-Status 'Look saved. It is used the next time the app starts.'
    })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $window })
    $ui.Grid.ItemsSource = $script:Items
    $ui.Grid.Add_SelectionChanged({ Update-Buttons })
    $ui.BtnOff.Add_Click({ Invoke-Safely { Switch-Selected $false } })
    $ui.BtnOn.Add_Click({ Invoke-Safely { Switch-Selected $true } })
    $ui.BtnOpen.Add_Click({ Invoke-Safely { $f = $ui.Grid.SelectedItem.File; Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$f`"" } })
    $ui.BtnRefresh.Add_Click({ Invoke-Safely { Update-List; Set-Status "Read again at $((Get-Date).ToString('HH:mm'))." } })
    $ui.TxtSearch.Add_TextChanged({ $ui.TxtHint.Visibility = if ($ui.TxtSearch.Text) { 'Collapsed' } else { 'Visible' }; Update-Filter })
    $window.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'F5') { Invoke-Safely { Update-List }; $e.Handled = $true } })
    $window.Add_ContentRendered({
        Invoke-Safely {
            Set-Status 'Reading what starts with Windows...'
            $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
            Update-List
            Set-Status 'Select a line to turn it off or on.'
        }
    })
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}

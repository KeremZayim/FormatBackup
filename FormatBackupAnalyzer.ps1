

# Windows Presentation Foundation (WPF) ve Windows Forms derlemelerini yükle
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# .NET'in bu tipleri belleğe yüklemesini zorla (XamlReader için kritik)
[void][System.Windows.Window]
[void][System.Windows.Controls.Grid]
[void][System.Windows.Markup.XamlReader]

[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null

# WPF Application ShutdownMode: Splash kapandığında uygulamanın kapanmaması için
$wpfApp = [System.Windows.Application]::Current
if (-not $wpfApp) {
    $wpfApp = New-Object System.Windows.Application
}
$wpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

# Hata ayıklama modunu aç
$ErrorActionPreference = "Continue"

# UTF-8 Çıktı Desteği
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ==========================================
# 1. SPLASH SCREEN (YÜKLENİYOR EKRANI) XAML
# ==========================================
$SplashXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Yükleniyor" Height="250" Width="450" 
        WindowStartupLocation="CenterScreen" WindowStyle="None" 
        AllowsTransparency="False" Background="#121214">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" ResizeBorderThickness="0" GlassFrameThickness="0"/>
    </WindowChrome.WindowChrome>
    <Border Background="#121214" BorderBrush="#29292E" BorderThickness="1.5" CornerRadius="0">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <!-- Logo / Başlık -->
            <StackPanel Grid.Row="0" Margin="25,25,25,10" Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock Text="⚡" FontSize="26" Foreground="#9D4EDD" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock Text="FormatBackup" FontSize="24" FontWeight="Bold" Foreground="#E1E1E6" VerticalAlignment="Center"/>
                <TextBlock Text=" Analiz Aracı" FontSize="24" FontWeight="Light" Foreground="#00B4D8" VerticalAlignment="Center"/>
            </StackPanel>
            
            <!-- Bilgi Mesajı -->
            <StackPanel Grid.Row="1" VerticalAlignment="Center" Margin="30,0">
                <TextBlock Name="lblStatus" Text="Sistem taranıyor, lütfen bekleyin..." 
                           Foreground="#A8A8B3" FontSize="14" HorizontalAlignment="Center" Margin="0,0,0,15" TextAlignment="Center"/>
                <ProgressBar Name="progress" Height="10" Value="10" Minimum="0" Maximum="100" Background="#1D1D22" Foreground="#9D4EDD" BorderThickness="0">
                    <ProgressBar.Template>
                        <ControlTemplate TargetType="ProgressBar">
                            <Grid Name="TemplateRoot">
                                <Border Background="{TemplateBinding Background}" CornerRadius="5"/>
                                <Border Name="PART_Indicator" CornerRadius="5" HorizontalAlignment="Left">
                                    <Border.Background>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                            <GradientStop Color="#9D4EDD" Offset="0.0"/>
                                            <GradientStop Color="#00B4D8" Offset="1.0"/>
                                        </LinearGradientBrush>
                                    </Border.Background>
                                </Border>
                            </Grid>
                        </ControlTemplate>
                    </ProgressBar.Template>
                </ProgressBar>
            </StackPanel>
            
            <!-- Sürüm Bilgisi -->
            <TextBlock Grid.Row="2" Text="v1.0.0 • Sistem Analiz Aracı" 
                       Foreground="#737380" FontSize="11" HorizontalAlignment="Center" Margin="0,0,0,15"/>
        </Grid>
    </Border>
</Window>
"@

try {
    $StringReader = New-Object System.IO.StringReader($SplashXaml.Trim())
    $XmlReader = [System.Xml.XmlReader]::Create($StringReader)
    $SplashForm = [Windows.Markup.XamlReader]::Load($XmlReader)
    $lblStatus = $SplashForm.FindName("lblStatus")
    $progressBar = $SplashForm.FindName("progress")
}
catch {
    [System.Windows.MessageBox]::Show("Splash Arayüz Yükleme Hatası:`n$($_.Exception.Message)", "Hata", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit
}

# ==========================================
# 2. ASENKRON VERİ TOPLAMA ALTYAPISI (RUNSPACE)
# ==========================================
$SharedData = [hashtable]::Synchronized(@{
        Progress    = 5
        StatusText  = "Başlatılıyor..."
        IsCompleted = $false
        GlobalData  = @{}
        Error       = $null
    })

$ScanScript = {
    param($SharedData, $userProfile, $extraProjectRoots = @())
    
    # UTF-8 Desteği
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    
    # Klasör boyutu hesaplama fonksiyonu (Arka planda çalışacağı için UI dondurmaz)
    function Get-DirSize($path) {
        if (-not (Test-Path $path)) { return 0 }
        [long]$size = 0
        try {
            $dir = New-Object System.IO.DirectoryInfo($path)
            $files = $dir.EnumerateFiles("*", [System.IO.SearchOption]::AllDirectories)
            foreach ($f in $files) {
                $size += $f.Length
            }
        }
        catch {}
        return $size
    }
    
    # Kapsamlı ve Öncelikli Proje Sınıflandırma Sistemi
    function Get-ProjectTypeName($path) {
        $hasGit = Test-Path (Join-Path $path ".git")
        
        # 1. En Özel / Büyük Teknolojiler (Oyun, Mobil vb.)
        if (Test-Path (Join-Path $path "Assets\ProjectSettings")) {
            return "Unity Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        if (Test-Path (Join-Path $path "pubspec.yaml")) {
            return "Flutter Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 2. Android Studio (Özel Android belirtileri)
        $hasAndroidManifest = (Test-Path (Join-Path $path "AndroidManifest.xml")) -or 
        (Get-ChildItem $path -Filter "AndroidManifest.xml" -ErrorAction SilentlyContinue)
        $hasLocalProperties = Test-Path (Join-Path $path "local.properties")
        $isAndroidGradle = $false
        if (Test-Path (Join-Path $path "build.gradle")) {
            $gradleContent = Get-Content (Join-Path $path "build.gradle") -Raw -ErrorAction SilentlyContinue
            if ($gradleContent -match "com\.android" -or $gradleContent -match "android\s*\{") {
                $isAndroidGradle = $true
            }
        }
        if (Test-Path (Join-Path $path "build.gradle.kts")) {
            $gradleContent = Get-Content (Join-Path $path "build.gradle.kts") -Raw -ErrorAction SilentlyContinue
            if ($gradleContent -match "com\.android" -or $gradleContent -match "android\s*\{") {
                $isAndroidGradle = $true
            }
        }
        if ($hasAndroidManifest -or $hasLocalProperties -or $isAndroidGradle) {
            return "Android Studio Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 3. Web / Node.js
        if (Test-Path (Join-Path $path "package.json")) {
            return "Node.js Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 4. .NET / C# / Visual Studio
        if ((Get-ChildItem $path -Filter "*.sln" -ErrorAction SilentlyContinue) -or 
            (Get-ChildItem $path -Filter "*.csproj" -ErrorAction SilentlyContinue) -or 
            (Test-Path (Join-Path $path ".vs"))) {
            return "Visual Studio Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 5. Java Maven
        if (Test-Path (Join-Path $path "pom.xml")) {
            return "Java Maven Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 6. Python
        if ((Test-Path (Join-Path $path "requirements.txt")) -or 
            (Test-Path (Join-Path $path "pyproject.toml")) -or 
            (Test-Path (Join-Path $path "Pipfile")) -or
            (Test-Path (Join-Path $path "setup.py")) -or
            (Test-Path (Join-Path $path "manage.py"))) {
            return "Python Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 7. Rust
        if (Test-Path (Join-Path $path "Cargo.toml")) {
            return "Rust Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 8. Go
        if (Test-Path (Join-Path $path "go.mod")) {
            return "Go Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 9. C++ / CMake
        if (Test-Path (Join-Path $path "CMakeLists.txt")) {
            return "C++ (CMake) Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 10. Java Gradle / IntelliJ IDEA (Android değilse ve yukarıdakiler uymadıysa)
        if ((Test-Path (Join-Path $path "build.gradle")) -or 
            (Test-Path (Join-Path $path "build.gradle.kts")) -or 
            (Test-Path (Join-Path $path ".idea")) -or 
            (Get-ChildItem $path -Filter "*.iml" -ErrorAction SilentlyContinue)) {
            return "IntelliJ IDEA Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 11. Eclipse
        if ((Test-Path (Join-Path $path ".project")) -or (Test-Path (Join-Path $path ".classpath"))) {
            return "Eclipse Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 12. VS Code (Editör klasörü var ama diğerleri yok)
        if (Test-Path (Join-Path $path ".vscode")) {
            return "VS Code Projesi" + (if ($hasGit) { " (Git)" } else { "" })
        }
        
        # 13. Sadece Git klasörü var
        if ($hasGit) {
            return "Git Projesi"
        }
        

        
        return $null
    }
    
    # Projeleri Taramak İçin Rekürsif Fonksiyon
    function Scan-ProjectsRecursive($path, $currentDepth, $maxDepth) {
        if ($currentDepth -gt $maxDepth) { return }
        
        $projType = Get-ProjectTypeName $path
        
        if ($projType) {
            $dirInfo = Get-Item $path
            $SharedData.StatusText = "Analiz ediliyor: $($dirInfo.Name)..."
            
            $sizeBytes = Get-DirSize $path
            $sizeMB = [Math]::Round($sizeBytes / 1MB, 1)
            $sizeText = if ($sizeMB -gt 1024) { "$([Math]::Round($sizeMB / 1024, 2)) GB" } else { "$sizeMB MB" }
            
            # Global veriye güvenli bir şekilde ekle
            $script:GlobalData.Projects.Add([PSCustomObject]@{
                    Name         = $dirInfo.Name
                    Path         = $dirInfo.FullName
                    Type         = $projType
                    Size         = $sizeText
                    SizeBytes    = $sizeBytes
                    LastModified = $dirInfo.LastWriteTime.ToString("dd.MM.yyyy HH:mm")
                })
            return
        }
        
        if ($currentDepth -lt $maxDepth) {
            try {
                $subDirs = Get-ChildItem -Path $path -Directory -ErrorAction SilentlyContinue
                foreach ($sub in $subDirs) {
                    if ($sub.Name -match "^(node_modules|\.git|bin|obj|dist|venv|\.venv|\.idea|\.vscode|\.gradle|packages|build)$") {
                        continue
                    }
                    Scan-ProjectsRecursive $sub.FullName ($currentDepth + 1) $maxDepth
                }
            }
            catch {}
        }
    }
    
    try {
        $script:GlobalData = @{
            SystemInfo       = @{}
            Disks            = [System.Collections.Generic.List[PSCustomObject]]::new()
            InstalledApps    = @()
            StoreApps        = [System.Collections.Generic.List[PSCustomObject]]::new()
            DeveloperFolders = [System.Collections.Generic.List[PSCustomObject]]::new()
            Projects         = [System.Collections.Generic.List[PSCustomObject]]::new()
            BackupApps       = [System.Collections.Generic.List[PSCustomObject]]::new()
            Browsers         = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        
        # Adım 1: Sistem Bilgileri
        $SharedData.StatusText = "Sistem donanım bilgileri okunuyor..."
        $SharedData.Progress = 15
        
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor
        $gpu = Get-CimInstance Win32_VideoController
        $motherboard = Get-CimInstance Win32_BaseBoard
        $bios = Get-CimInstance Win32_BIOS
        $comp = Get-CimInstance Win32_ComputerSystem
        
        $compModel = "$($comp.Manufacturer.Trim()) $($comp.Model.Trim())"
        
        $ramTotalBytes = 0
        $ramModules = Get-CimInstance Win32_PhysicalMemory
        if ($ramModules) {
            foreach ($rm in $ramModules) { $ramTotalBytes += $rm.Capacity }
        }
        $ramTotalGB = [Math]::Round($ramTotalBytes / 1GB, 1)
        $ramSpeed = if ($ramModules) { $ramModules[0].Speed } else { 0 }
        $ramCount = if ($ramModules) { $ramModules.Count } else { 0 }
        $ramManufacturer = if ($ramModules) { $ramModules[0].Manufacturer.Trim() } else { "" }
        $gpuVRAMBytes = 0
        try {
            # Once kayıt defterinden dene (REG_BINARY olarak saklanır)
            $gpuKey0 = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}\0000" -EA SilentlyContinue
            if ($gpuKey0) {
                $rawMem = $gpuKey0.GetValue("HardwareInformation.MemorySize")
                if ($rawMem -is [byte[]] -and $rawMem.Length -gt 0) {
                    $padded = $rawMem + (New-Object byte[] 8)
                    $gpuVRAMBytes = [System.BitConverter]::ToInt64($padded, 0)
                }
                elseif ($rawMem) {
                    $gpuVRAMBytes = [long]$rawMem
                }
            }
        }
        catch {}
        
        $gpuVRAM = 0
        if ($gpuVRAMBytes -gt 0) {
            $gpuVRAM = [Math]::Round($gpuVRAMBytes / 1GB, 0)
        }
        else {
            # WMI'den al - AdapterRAM UINT32 tasiyor, 4GB'dan buyuk GPU'larda yanlis gelebilir
            $vramRaw = 0
            if ($gpu) { $vramRaw = if ($gpu.Length -gt 1) { $gpu[0].AdapterRAM } else { $gpu.AdapterRAM } }
            if ($vramRaw -ge 4000000000) {
                # Muhtemelen tasma var - GPU adından parse et (örn: "RTX 4060 8GB")
                $gpuNameStr = if ($gpu.Length -gt 1) { $gpu[0].Name } else { $gpu.Name }
                if ($gpuNameStr -match '(\d+)\s*GB') {
                    $gpuVRAM = [int]$Matches[1]
                }
                else {
                    # Bilinenler: RTX 3060=8GB, RTX 3070=8GB, RTX 3080=10GB, RTX 4070=8GB, RTX 4080=16GB
                    $gpuVRAM = 8  # Varsayılan tahmin (4GB+ GPU için)
                }
            }
            else {
                $gpuVRAM = [Math]::Round($vramRaw / 1GB, 1)
            }
        }
        
        $resolution = "-"
        if ($gpu) {
            $resWidth = if ($gpu.Length -gt 1) { $gpu[0].CurrentHorizontalResolution } else { $gpu.CurrentHorizontalResolution }
            $resHeight = if ($gpu.Length -gt 1) { $gpu[0].CurrentVerticalResolution } else { $gpu.CurrentVerticalResolution }
            $refresh = if ($gpu.Length -gt 1) { $gpu[0].CurrentRefreshRate } else { $gpu.CurrentRefreshRate }
            if ($resWidth -and $resHeight) {
                $resolution = "$($resWidth)x$($resHeight) @ $($refresh)Hz"
            }
        }
        
        $uptime = "Bilinmiyor"
        try {
            $lastBoot = $os.LastBootUpTime
            $diff = (Get-Date) - $lastBoot
            $uptime = "$($diff.Days) Gün, $($diff.Hours) Saat, $($diff.Minutes) Dakika"
        }
        catch {}
        
        # Hesap türünü kontrol et - net localgroup komutu UAC'dan bağımsız
        $isAdmin = "Standart Kullanıcı"
        try {
            $adminMembers = net localgroup Administrators 2>&1
            $currentUser = $env:USERNAME
            # net localgroup ciktisindan kullanici adini ara
            $isInAdminGroup = $adminMembers | Where-Object { $_ -and $_.Trim() -eq $currentUser }
            if ($isInAdminGroup) {
                $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
                if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                    $isAdmin = "Yönetici (Yükseltilmiş / UAC Aktif)"
                } else {
                    $isAdmin = "Yönetici Hesabı"
                }
            }
        } catch {}
        
        $productID = if ($os.SerialNumber) { $os.SerialNumber } else { "Bilinmiyor" }
        
        $antivirus = "Windows Defender"
        try {
            $avProduct = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName "AntiVirusProduct" -ErrorAction SilentlyContinue
            if ($avProduct) {
                $avList = @($avProduct)
                $avItems = @()
                foreach ($av in $avList) {
                    # Kaldirilmis/hayalet kayitlari atla: yurutucusu yoksa gostermemek
                    $exePath = $av.pathToSignedProductExe
                    if ($exePath -and $exePath -ne '' -and -not (Test-Path $exePath -EA SilentlyContinue)) {
                        continue  # Dosya yok = kaldirilmis urun, gosterme
                    }
                    # productState: byte 1 (bits 8-15) = 0x10 ise gercek zamanli koruma aktif
                    $rtActive = (($av.productState -shr 8) -band 0x10) -eq 0x10
                    $label = $av.displayName
                    if ($avList.Count -gt 1 -and $rtActive) { $label += " (Aktif)" }
                    if ($avList.Count -gt 1 -and -not $rtActive) { $label += " (Pasif)" }
                    $avItems += $label
                }
                if ($avItems.Count -gt 0) {
                    $antivirus = $avItems -join " | "
                }
            }
        } catch {}
        
        $netIP = "-"
        $netMAC = "-"
        $netName = "-"
        try {
            $netAdapters = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True"
            if ($netAdapters) {
                $activeNet = $netAdapters | Select-Object -First 1
                $netIP = ($activeNet.IPAddress -join ", ")
                $netMAC = $activeNet.MACAddress
                $netAdapterName = Get-CimInstance Win32_NetworkAdapter -Filter "DeviceID=$($activeNet.Index)"
                $netName = $netAdapterName.NetConnectionID
            }
        }
        catch {}
        
        $physicalDisksInfo = @()
        try {
            $disks = Get-CimInstance Win32_DiskDrive
            foreach ($d in $disks) {
                $diskGB = [Math]::Round($d.Size / 1GB, 1)
                $physicalDisksInfo += "$($d.Model) ($diskGB GB, $($d.InterfaceType))"
            }
        }
        catch {}
        $diskListStr = if ($physicalDisksInfo) { $physicalDisksInfo -join " | " } else { "-" }
        
        $script:GlobalData.SystemInfo = @{
            ComputerName     = $env:COMPUTERNAME
            UserName         = $env:USERNAME
            OSName           = $os.Caption
            OSVersion        = "$($os.Version) (Build $($os.BuildNumber))"
            OSArchitecture   = $os.OSArchitecture
            OSInstallDate    = if ($os.InstallDate) { $os.InstallDate.ToString("dd.MM.yyyy") } else { "Bilinmiyor" }
            CPUName          = $cpu.Name.Trim()
            CPUCores         = $cpu.NumberOfCores
            CPULogical       = $cpu.NumberOfLogicalProcessors
            CPUSpeed         = "$([Math]::Round($cpu.MaxClockSpeed / 1000, 2)) GHz"
            RAMSize          = "$ramTotalGB GB"
            RAMSpeed         = if ($ramSpeed -gt 0) { "$ramSpeed MHz" } else { "Bilinmiyor" }
            RAMSlots         = "$ramCount Modül"
            RAMManufacturer  = if ($ramManufacturer) { $ramManufacturer } else { "Bilinmiyor" }
            Motherboard      = "$($motherboard.Manufacturer) $($motherboard.Product)"
            BIOSVersion      = $bios.SMBIOSBIOSVersion
            BIOSDate         = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString("dd.MM.yyyy") } else { "Bilinmiyor" }
            GPUName          = if ($gpu.Length -gt 1) { ($gpu | Select-Object -ExpandProperty Name) -join ", " } else { $gpu.Name }
            GPUVRAM          = if ($gpuVRAM -gt 0) { "$gpuVRAM GB" } else { "Bilinmiyor" }
            NetworkName      = $netName
            NetworkIP        = $netIP
            NetworkMAC       = $netMAC
            PhysicalDisks    = $diskListStr
            ComputerModel    = $compModel
            ScreenResolution = $resolution
            SystemUptime     = $uptime
            IsAdminStatus    = $isAdmin
            ProductID        = $productID
            AntivirusStatus  = $antivirus
        }
        
        # Adım 2: Diskler ve SSD
        $SharedData.StatusText = "Sürücüler ve SSD doluluk oranları analiz ediliyor..."
        $SharedData.Progress = 30
        
        try {
            $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
            $logicalDisks = Get-CimInstance Win32_LogicalDisk
            
            # Fiziksel disk - mantıksal disk eşleştirme
            $diskToDriveMap = @{}
            try {
                $partitions = Get-CimInstance Win32_DiskDriveToDiskPartition
                $logParts = Get-CimInstance Win32_LogicalDiskToPartition
                foreach ($lp in $logParts) {
                    $partNum = ($lp.Antecedent -split 'DiskIndex=(\d+)')[1] -replace '".*', ''
                    $driveLetter = ($lp.Dependent -split 'DeviceID="([A-Z]:)"')[1]
                    if ($driveLetter) { $diskToDriveMap[$driveLetter] = $partNum }
                }
            }
            catch {}
            
            foreach ($ld in $logicalDisks) {
                if (-not $ld.Size -or $ld.Size -eq 0) { continue }
                $sizeGB = [Math]::Round($ld.Size / 1GB, 1)
                $freeGB = [Math]::Round($ld.FreeSpace / 1GB, 1)
                $usedGB = [Math]::Round($sizeGB - $freeGB, 1)
                $usedPercent = if ($sizeGB -gt 0) { [Math]::Round(($usedGB / $sizeGB) * 100, 1) } else { 0 }
                
                # Disk türünü akıllıca tespit et
                $diskType = "Bilinmiyor"
                $driveLet = $ld.DeviceID -replace ':', ''
                if ($physicalDisks) {
                    # Seri numarası veya model eşleştirme yerine en yakın diski bul
                    $matchedDisk = $null
                    try {
                        $matchedDisk = $physicalDisks | Where-Object { $_.BusType -ne 'USB' } | Select-Object -First 1
                        if ($physicalDisks.Count -gt 1) {
                            # Birden fazla disk varsa, mantıksal diske uygun olanı bulmaya çalış
                            $matchedDisk = $physicalDisks[0]
                        }
                    }
                    catch { $matchedDisk = $physicalDisks | Select-Object -First 1 }
                    
                    if ($matchedDisk) {
                        $rawType = $matchedDisk.MediaType.ToString()
                        if ($rawType -eq "SSD") { $diskType = "SSD" }
                        elseif ($rawType -eq "HDD") { $diskType = "HDD" }
                        elseif ($rawType -eq "Unspecified" -or $rawType -eq "0") { $diskType = "SSD/NVMe" }
                        elseif ($rawType -eq "Removable" -or $ld.DriveType -eq 2) { $diskType = "Taşınabilir" }
                        else { $diskType = "Disk" }
                    }
                }
                if ($ld.DriveType -eq 5) { $diskType = "CD/DVD" }
                if ($ld.DriveType -eq 4) { $diskType = "Ağ Diski" }
                
                $script:GlobalData.Disks += [PSCustomObject]@{
                    Letter      = $ld.DeviceID
                    Label       = if ($ld.VolumeName) { $ld.VolumeName } else { "Yerel Disk" }
                    Type        = $diskType
                    FileSystem  = $ld.FileSystem
                    TotalSize   = "$sizeGB GB"
                    FreeSpace   = "$freeGB GB"
                    UsedSpace   = "$usedGB GB"
                    UsedPercent = $usedPercent
                }
            }
        }
        catch { <# Disk bilgisi okunamadı - sessizce devam #> }
        
        # Adım 3: Yüklü Uygulamalar (Registry)
        $SharedData.StatusText = "Yüklü masaüstü uygulamaları taranıyor (Registry)..."
        $SharedData.Progress = 50
        
        $installedAppsList = New-Object System.Collections.Generic.List[PSCustomObject]
        $regPaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        
        foreach ($path in $regPaths) {
            if (Test-Path (Split-Path $path)) {
                try {
                    $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue
                    foreach ($app in $apps) {
                        if ($app.DisplayName -and $app.SystemComponent -ne 1 -and $app.ParentKeyName -eq $null) {
                            $installDate = ""
                            if ($app.InstallDate) {
                                try {
                                    if ($app.InstallDate -match "^\d{8}$") {
                                        $installDate = [DateTime]::ParseExact($app.InstallDate, "yyyyMMdd", $null).ToString("dd.MM.yyyy")
                                    }
                                    else {
                                        $installDate = $app.InstallDate
                                    }
                                }
                                catch { $installDate = $app.InstallDate }
                            }
                            
                            $appObj = [PSCustomObject]@{
                                Name        = $app.DisplayName.Trim()
                                Version     = if ($app.DisplayVersion) { $app.DisplayVersion.ToString().Trim() } else { "Bilinmiyor" }
                                Publisher   = if ($app.Publisher) { $app.Publisher.ToString().Trim() } else { "Bilinmiyor" }
                                InstallPath = if ($app.InstallLocation) { $app.InstallLocation.ToString().Trim() } else { "Belirtilmemiş" }
                                InstallDate = $installDate
                                Type        = "Masaüstü"
                            }
                            $installedAppsList.Add($appObj)
                        }
                    }
                }
                catch {}
            }
        }
        
        $script:GlobalData.InstalledApps = $installedAppsList | Group-Object Name | ForEach-Object { $_.Group[0] } | Sort-Object Name
        
        # Adım 4: Microsoft Store Uygulamaları
        $SharedData.StatusText = "Microsoft Store uygulamaları listeleniyor..."
        $SharedData.Progress = 65
        
        try {
            # Sadece kullanicinin kendi kurdugu Store uygulamalarini goster
            # Microsoft yayincili paketler (Windows ile gelen) tamamen hariç tutuluyor
            $allStoreApps = Get-AppxPackage -ErrorAction SilentlyContinue
            foreach ($sa in $allStoreApps) {
                if ($sa.IsFramework) { continue }
                if (-not $sa.InstallLocation) { continue }
                
                # Sistem imzali veya kaldirilmaz paketleri atla
                $sigKind = $null
                try { $sigKind = $sa.SignatureKind.ToString() } catch {}
                if ($sigKind -eq 'System') { continue }
                try { if ($sa.NonRemovable -eq $true) { continue } } catch {}
                
                # Microsoft veya MicrosoftWindows yayincisi olan tum paketleri atla
                # (Windows ile birlikte gelen uygulamalar)
                $pubRaw = $sa.Publisher
                if ($pubRaw -match 'O=Microsoft') { continue }
                
                # Kullanici tarafindan yuklenmis ucuncu taraf uygulama
                $friendlyName = $sa.Name
                try {
                    $mf = Join-Path $sa.InstallLocation 'AppxManifest.xml'
                    if (Test-Path $mf) {
                        [xml]$mfXml = Get-Content $mf -Encoding UTF8 -ErrorAction SilentlyContinue
                        $dn = $mfXml.Package.Properties.DisplayName
                        if ($dn -and $dn -notmatch '^ms-resource:') { $friendlyName = $dn }
                    }
                }
                catch {}
                
                $script:GlobalData.StoreApps.Add([PSCustomObject]@{
                        Name        = $friendlyName
                        Publisher   = ($pubRaw -replace 'CN=', '' -replace ',.*', '')
                        Version     = $sa.Version
                        InstallPath = $sa.InstallLocation
                        InstallDate = 'Bilinmiyor'
                        Type        = 'Windows Magaza'
                    })
            }
        }
        catch {}
        
        # Adım 5: Yazılım Önbellekleri ve Önemli Kullanıcı Klasörleri
        $SharedData.StatusText = "Yazılım önbellek klasörleri (Gradle, NuGet, Maven vb.) aranıyor..."
        $SharedData.Progress = 75
        
        $devFoldersToScan = @(
            @{ Path = "$userProfile\.gradle"; Name = "Gradle Önbelleği"; Recommended = "Gereksiz (Format sonrası otomatik iner)"; Type = "Önbellek" },
            @{ Path = "$userProfile\.m2"; Name = "Maven Deposu"; Recommended = "Gereksiz (Format sonrası otomatik iner)"; Type = "Önbellek" },
            @{ Path = "$userProfile\.nuget\packages"; Name = "NuGet Paket Önbelleği"; Recommended = "Gereksiz (Format sonrası otomatik iner)"; Type = "Önbellek" },
            @{ Path = "$userProfile\.conda"; Name = "Conda Ortamları"; Recommended = "Projelerinize göre yedekleyebilirsiniz"; Type = "Ortam/Paket" },
            @{ Path = "$userProfile\.vscode\extensions"; Name = "VS Code Eklentileri"; Recommended = "Yedeklenebilir (Ayarlar buluttan senkronize edilebilir)"; Type = "Eklenti" },
            @{ Path = "$userProfile\AppData\Local\Android\Sdk"; Name = "Android SDK"; Recommended = "Boyutu büyük! Hızlı kurulum için yedeklenebilir"; Type = "SDK" },
            @{ Path = "$userProfile\AppData\Local\Unity"; Name = "Unity Önbellek & Ayarları"; Recommended = "Yedeklenebilir"; Type = "Ayarlar" },
            @{ Path = "$userProfile\.docker"; Name = "Docker Ayarları"; Recommended = "Yedeklenebilir"; Type = "Ayarlar" },
            @{ Path = "$userProfile\.npm"; Name = "NPM Önbelleği"; Recommended = "Gereksiz"; Type = "Önbellek" },
            @{ Path = "$userProfile\.pnpm-store"; Name = "PNPM Deposu"; Recommended = "Gereksiz"; Type = "Önbellek" }
        )
        
        foreach ($folder in $devFoldersToScan) {
            if (Test-Path $folder.Path) {
                $sizeBytes = Get-DirSize $folder.Path
                $sizeMB = [Math]::Round($sizeBytes / 1MB, 1)
                $sizeText = if ($sizeMB -gt 1024) { "$([Math]::Round($sizeMB / 1024, 2)) GB" } else { "$sizeMB MB" }
                
                $script:GlobalData.DeveloperFolders += [PSCustomObject]@{
                    Name        = $folder.Name
                    Path        = $folder.Path
                    Size        = $sizeText
                    SizeBytes   = $sizeBytes
                    Recommended = $folder.Recommended
                    Type        = $folder.Type
                }
            }
        }
        
        # Adım 6: Proje taraması ana thread'de yapılıyor (daha güvenilir)
        $SharedData.StatusText = "Sistem taraması tamamlanıyor..."
        $SharedData.Progress = 90
        
        # Adım 7: Yedekleme ve Bulut Uygulamaları
        $SharedData.StatusText = "Yedekleme durumları (OneDrive, Google Drive vb.) sorgulanıyor..."
        $SharedData.Progress = 95
        
        # OneDrive
        $oneDrivePath = $env:OneDriveConsumer
        if (-not $oneDrivePath) { $oneDrivePath = $env:OneDrive }
        if (-not $oneDrivePath) {
            $odReg = Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -ErrorAction SilentlyContinue
            if ($odReg -and $odReg.UserFolder) { $oneDrivePath = $odReg.UserFolder }
        }
        if ($oneDrivePath -and (Test-Path $oneDrivePath)) {
            $script:GlobalData.BackupApps += [PSCustomObject]@{
                Name        = "Microsoft OneDrive"
                Path        = $oneDrivePath
                Status      = "Aktif ve Bağlı"
                Recommended = "Buluttaki dosyalarınızı webden kontrol edin, yerel dosyaların senkronize olduğundan emin olun."
            }
        }
        
        # Google Drive
        $googleDrivePath = ""
        if (Test-Path "G:\My Drive") {
            $googleDrivePath = "G:\"
        }
        else {
            if (Test-Path "$userProfile\Google Drive") {
                $googleDrivePath = "$userProfile\Google Drive"
            }
        }
        if ($googleDrivePath) {
            $script:GlobalData.BackupApps += [PSCustomObject]@{
                Name        = "Google Drive"
                Path        = $googleDrivePath
                Status      = "Aktif (Sanal veya Yerel)"
                Recommended = "Sanal sürücüde (G:) duran dosyalar zaten buluttadır. Offline klasörlerinizi kontrol edin."
            }
        }
        
        # Tarayıcılar
        $browsersList = @(
            @{ Name = "Google Chrome"; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"; Rec = "Şifre, geçmiş ve yer imleri için bu profili yedekleyebilir veya Chrome senkronizasyonunu açabilirsiniz." },
            @{ Name = "Microsoft Edge"; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"; Rec = "Edge senkronizasyonunu açmak en kolayıdır, alternatif olarak bu klasörü yedekleyin." },
            @{ Name = "Mozilla Firefox"; Path = "$env:APPDATA\Mozilla\Firefox\Profiles"; Rec = "Firefox profil klasörünü doğrudan yedekleyebilirsiniz." }
        )
        
        foreach ($br in $browsersList) {
            if (Test-Path $br.Path) {
                $sizeBytes = Get-DirSize $br.Path
                $sizeMB = [Math]::Round($sizeBytes / 1MB, 1)
                $sizeText = "$sizeMB MB"
                $script:GlobalData.Browsers += [PSCustomObject]@{
                    Name        = $br.Name
                    Path        = $br.Path
                    Size        = $sizeText
                    SizeBytes   = $sizeBytes
                    Recommended = $br.Rec
                }
            }
        }
        
        # Verileri kaydet
        $SharedData.GlobalData = $script:GlobalData
        $SharedData.Progress = 100
        $SharedData.StatusText = "Tamamlandı!"
    }
    catch {
        $SharedData.Error = $_.Exception.Message
    }
    finally {
        $SharedData.IsCompleted = $true
    }
}

# Runspace ve Asenkron Çalıştırma Kurulumu
$Runspace = [runspacefactory]::CreateRunspace()
$Runspace.Open()
$PowerShellCmd = [powershell]::Create()
$PowerShellCmd.Runspace = $Runspace
# Kullanıcının geliştirme dizinlerini ve tüm disklerin kök klasörlerini dinamik olarak tespit et
$extraRoots = [System.Collections.Generic.List[string]]::new()

# 1. Standart kullanıcı profil dizinleri
$userPaths = @(
    "$env:USERPROFILE\source\repos",
    "$env:USERPROFILE\Projects",
    "$env:USERPROFILE\IdeaProjects",
    "$env:USERPROFILE\AndroidStudioProjects",
    "$env:USERPROFILE\workspace",
    "$env:USERPROFILE\Documents\Projects",
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Documents"
)
foreach ($path in $userPaths) {
    if (Test-Path $path -EA SilentlyContinue) {
        if (-not $extraRoots.Contains($path)) {
            $extraRoots.Add($path)
        }
    }
}

# 2. Disk kök dizinlerindeki 1. seviye klasörler (Sistem klasörleri hariç)
$excludePattern = '^(System Volume Information|\$RECYCLE\.BIN|Windows|Program Files|Program Files \(x86\)|ProgramData|AppData|Microsoft|WindowsPowerShell|Temp|Logs|Recovery|Intel|nvidia|MSOCache|Users|PerfLogs)$'
try {
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable' }
    foreach ($drive in $drives) {
        if ($drive.IsReady) {
            $rootPath = $drive.RootDirectory.FullName
            Get-ChildItem $rootPath -Directory -EA SilentlyContinue | Where-Object {
                $_.Name -notmatch $excludePattern
            } | ForEach-Object {
                if (-not $extraRoots.Contains($_.FullName)) {
                    $extraRoots.Add($_.FullName)
                }
            }
        }
    }
} catch {}

$PowerShellCmd.AddScript($ScanScript).AddArgument($SharedData).AddArgument($env:USERPROFILE).AddArgument($extraRoots.ToArray()) | Out-Null

$AsyncResult = $PowerShellCmd.BeginInvoke()

# Splash ekranını güncellemek için Timer tanımla
$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$Timer.Add_Tick({
        $lblStatus.Text = $SharedData.StatusText
        $progressBar.Value = $SharedData.Progress
    
        if ($SharedData.IsCompleted) {
            $Timer.Stop()
            $SplashForm.Close()
        }
    })
$Timer.Start()

# Splash formunu bloke ederek göster (Timer tetiklenmeye devam edecektir)
$SplashForm.ShowDialog() | Out-Null

# Eğer tarama esnasında bir hata oluştuysa ekrana yaz veya logla
if ($SharedData.Error) {
    [System.Windows.MessageBox]::Show("Tarama hatası: $($SharedData.Error)", "Hata", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit
}

# Verileri ana değişkene geri yükle
$GlobalData = $SharedData.GlobalData

# ==========================================
# PROJE TARAMA - Ana Thread'de (Runspace parametresi yerine)
# ==========================================
$SharedData.StatusText = "Projeler taranıyor..."

function Get-ProjectTypeName-Main($path) {
    # Güvenlik Kontrolleri: Disk kökleri, kullanıcı profil klasörü, 'Users' veya 'source' gibi genel klasörler proje olamaz.
    if ($path -match '^[a-zA-Z]:\\?$' -or 
        $path -eq $env:USERPROFILE -or 
        (Split-Path $path -Leaf) -eq 'Users' -or 
        (Split-Path $path -Leaf) -eq 'source' -or
        $path -eq (Split-Path $env:USERPROFILE -Parent)) {
        return $null
    }

    $hasGit = Test-Path (Join-Path $path ".git") -EA SilentlyContinue
    $g = if ($hasGit) { " (Git)" } else { "" }
    if (Test-Path (Join-Path $path "Assets\ProjectSettings") -EA SilentlyContinue) { return "Unity Projesi$g" }
    if (Test-Path (Join-Path $path "pubspec.yaml") -EA SilentlyContinue) { return "Flutter Projesi$g" }
    if (Test-Path (Join-Path $path "package.json") -EA SilentlyContinue) { return "Node.js Projesi$g" }
    $hasSln = (Get-ChildItem $path -Filter "*.sln" -EA SilentlyContinue) -or (Get-ChildItem $path -Filter "*.csproj" -EA SilentlyContinue)
    if ($hasSln -or (Test-Path (Join-Path $path ".vs") -EA SilentlyContinue)) { return "Visual Studio Projesi$g" }
    if (Test-Path (Join-Path $path "pom.xml") -EA SilentlyContinue) { return "Java Maven Projesi$g" }
    if ((Test-Path (Join-Path $path "requirements.txt") -EA SilentlyContinue) -or (Test-Path (Join-Path $path "manage.py") -EA SilentlyContinue)) { return "Python Projesi$g" }
    if (Test-Path (Join-Path $path "Cargo.toml") -EA SilentlyContinue) { return "Rust Projesi$g" }
    if (Test-Path (Join-Path $path "go.mod") -EA SilentlyContinue) { return "Go Projesi$g" }
    # Android Studio - IntelliJ IDEA'dan ONCE kontrol et (ikisi de .idea kullanır)
    $hasAndroid = (Test-Path (Join-Path $path "app\src\main\AndroidManifest.xml") -EA SilentlyContinue) -or
                  (Test-Path (Join-Path $path "app\AndroidManifest.xml") -EA SilentlyContinue) -or
                  ((Test-Path (Join-Path $path "gradlew") -EA SilentlyContinue) -and (Test-Path (Join-Path $path "local.properties") -EA SilentlyContinue))
    if ($hasAndroid) { return "Android Studio Projesi$g" }
    if ((Test-Path (Join-Path $path "build.gradle") -EA SilentlyContinue) -or (Test-Path (Join-Path $path ".idea") -EA SilentlyContinue)) { return "IntelliJ IDEA Projesi$g" }
    if (Test-Path (Join-Path $path ".vscode") -EA SilentlyContinue) { return "VS Code Projesi$g" }
    if ($hasGit) { return "Git Projesi" }
    return $null
}

$projectsFound = [System.Collections.Generic.List[PSCustomObject]]::new()
function Scan-Projects-Main($root, $depth, $max) {
    if ($depth -gt $max) { return }
    $pt = Get-ProjectTypeName-Main $root
    if ($pt) {
        try {
            $di = Get-Item $root -EA SilentlyContinue
            if ($di) {
                $sb = 0
                try {
                    $diObj = New-Object System.IO.DirectoryInfo($root)
                    $diObj.EnumerateFiles("*", [System.IO.SearchOption]::AllDirectories) | ForEach-Object { $sb += $_.Length }
                }
                catch {}
                $smb = [Math]::Round($sb / 1MB, 1)
                $stext = if ($smb -gt 1024) { "$([Math]::Round($smb/1024,2)) GB" } else { "$smb MB" }
                $script:projectsFound.Add([PSCustomObject]@{
                        Name         = $di.Name
                        Path         = $di.FullName
                        Type         = $pt
                        Size         = $stext
                        SizeBytes    = $sb
                        LastModified = $di.LastWriteTime.ToString("dd.MM.yyyy HH:mm")
                    })
            }
        }
        catch {}
        return
    }
    if ($depth -lt $max) {
        Get-ChildItem $root -Directory -EA SilentlyContinue | Where-Object {
            $_.Name -notmatch '^(node_modules|\.git|bin|obj|dist|venv|\.venv|packages|build)$'
        } | ForEach-Object { Scan-Projects-Main $_.FullName ($depth + 1) $max }
    }
}

# Dinamik olarak tespit edilen tüm geliştirme ve kullanıcı klasörlerini tara
foreach ($target in $extraRoots) {
    Scan-Projects-Main $target 0 3
}

$GlobalData.Projects = $projectsFound

# ==========================================
# 3. ANA DASHBOARD WPF ARAYÜZÜ XAML
# ==========================================
$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FormatBackup Analiz Aracı" Height="680" Width="1050" 
        WindowStartupLocation="CenterScreen" WindowStyle="None" 
        AllowsTransparency="False" Background="#121214"
        FontFamily="Segoe UI" xml:lang="tr-TR">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" ResizeBorderThickness="0" GlassFrameThickness="0"/>
    </WindowChrome.WindowChrome>
    
    <Window.Resources>
        <!-- Disk doluluk barı stili (gradıyan) -->
        <Style TargetType="ProgressBar" x:Key="GradientDiskBarStyle">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <!-- PART_Track: WPF bu elemana gore PART_Indicator genisligini hesaplar -->
                            <Border Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="6"/>
                            <Border Name="PART_Indicator" CornerRadius="6" HorizontalAlignment="Left">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                        <GradientStop Color="#9D4EDD" Offset="0.0"/>
                                        <GradientStop Color="#00B4D8" Offset="1.0"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Uygulamalar sekmesi filtre buton stili -->
        <Style TargetType="RadioButton" x:Key="AppFilterBtnStyle">
            <Setter Property="Background" Value="#1D1D22"/>
            <Setter Property="Foreground" Value="#A8A8B3"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#29292E"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border Name="Btn" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Btn" Property="Background" Value="#25252B"/>
                                <Setter Property="Foreground" Value="#E1E1E6"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Btn" Property="Background" Value="#2A1B3D"/>
                                <Setter TargetName="Btn" Property="BorderBrush" Value="#9D4EDD"/>
                                <Setter Property="Foreground" Value="#9D4EDD"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Windows Minimize Buton Stili -->
        <Style TargetType="Button" x:Key="WindowsMinimizeButtonStyle">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="45"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Border" Background="{TemplateBinding Background}">
                            <Path Data="M 0,0 L 10,0" Stroke="#E1E1E6" StrokeThickness="1.5" HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#2D2D30"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#3F3F41"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Windows Kapat Buton Stili -->
        <Style TargetType="Button" x:Key="WindowsCloseButtonStyle">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="45"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Border" Background="{TemplateBinding Background}">
                            <Path Data="M 0,0 L 10,10 M 0,10 L 10,0" Stroke="#E1E1E6" StrokeThickness="1.5" HorizontalAlignment="Center" VerticalAlignment="Center" SnapsToDevicePixels="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#E81123"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#F1707A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- DataGrid Genel Stili -->
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="RowBackground" Value="#1D1D22"/>
            <Setter Property="AlternatingRowBackground" Value="#16161B"/>
            <Setter Property="Foreground" Value="#E1E1E6"/>
            <Setter Property="GridLinesVisibility" Value="None"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#29292E"/>
            <Setter Property="RowHeaderWidth" Value="0"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#16161B"/>
            <Setter Property="Foreground" Value="#9D4EDD"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderThickness" Value="0,0,0,2"/>
            <Setter Property="BorderBrush" Value="#29292E"/>
        </Style>
        
        <Style TargetType="DataGridCell">
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                     <Setter Property="Background" Value="#2A1B3D"/>
                     <Setter Property="Foreground" Value="#00B4D8"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        
        <Style TargetType="DataGridRow">
            <Setter Property="Margin" Value="0,2"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#25252B"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Sol Menü RadioButton Stili -->
        <Style TargetType="RadioButton" x:Key="SidebarRadioButtonStyle">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#A8A8B3"/>
            <Setter Property="Padding" Value="15,10"/>
            <Setter Property="Margin" Value="0,3"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border Name="Border" Background="{TemplateBinding Background}" CornerRadius="8" BorderThickness="0" Padding="{TemplateBinding Padding}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <!-- Sol Dikey Neon Çizgi (Sadece seçiliyken görünür) -->
                                <Border Name="Indicator" Grid.Column="0" Width="4" Height="16" Background="#9D4EDD" CornerRadius="2" Margin="-5,0,10,0" Visibility="Collapsed"/>
                                <ContentPresenter Grid.Column="1" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#25252B"/>
                                <Setter Property="Foreground" Value="#E1E1E6"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#1D1D22"/>
                                <Setter TargetName="Indicator" Property="Visibility" Value="Visible"/>
                                <Setter Property="Foreground" Value="#9D4EDD"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Dışa Aktar Buton Stili -->
        <Style TargetType="Button" x:Key="ExportButtonStyle">
            <Setter Property="Background" Value="#9D4EDD"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="15,10"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Border" Background="{TemplateBinding Background}" CornerRadius="8" BorderThickness="0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#8A2BE2"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#6A1B9A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- TextBox Arama Kutusu Stili -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#1D1D22"/>
            <Setter Property="Foreground" Value="#E1E1E6"/>
            <Setter Property="BorderBrush" Value="#29292E"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Name="Border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="2,0" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter Property="BorderBrush" Value="#9D4EDD"/>
                                <Setter Property="Background" Value="#221C2B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Yedekle Buton Stili (Yeşil) -->
        <Style TargetType="Button" x:Key="BackupButtonStyle">
            <Setter Property="Background" Value="#4ECA8D"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="15,10"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="Border" Background="{TemplateBinding Background}" CornerRadius="8" BorderThickness="0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#3CB371"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#2E8B57"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Background="#121214" BorderBrush="#29292E" BorderThickness="1.5" CornerRadius="0">
        
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="45"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            
            <!-- ÜST BAŞLIK BAR (TitleBar) -->
            <Grid Grid.Row="0" Name="TitleBar" Background="#1A1A1E">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="20,0">
                    <TextBlock Text="⚡" FontSize="18" Foreground="#9D4EDD" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock Text="FormatBackup" FontSize="16" FontWeight="Bold" Foreground="#E1E1E6" VerticalAlignment="Center"/>
                    <TextBlock Text=" Analiz Aracı" FontSize="16" FontWeight="Light" Foreground="#00B4D8" VerticalAlignment="Center"/>
                </StackPanel>
                
                <!-- Windows Tarzı Kontrol Butonları -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Button Name="btnMinimize" Style="{StaticResource WindowsMinimizeButtonStyle}" ToolTip="Simge Durumuna Küçült"/>
                    <Button Name="btnClose" Style="{StaticResource WindowsCloseButtonStyle}" ToolTip="Kapat"/>
                </StackPanel>
            </Grid>
            
            <!-- ANA İÇERİK ALANI -->
            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="230"/> <!-- Sol Menü -->
                    <ColumnDefinition Width="*"/>   <!-- İçerik -->
                </Grid.ColumnDefinitions>
                
                <!-- SOL SİDEBAR (Gezinti Menüsü) -->
                <Border Grid.Column="0" Background="#16161B" BorderBrush="#29292E" BorderThickness="0,0,1,0" CornerRadius="0,0,0,16">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        
                        <!-- Kullanıcı Bilgisi -->
                        <StackPanel Grid.Row="0" Margin="20,20,20,10">
                            <TextBlock Name="txtUserWelcome" Text="Merhaba," FontSize="13" Foreground="#737380"/>
                            <TextBlock Name="txtPCName" Text="DESKTOP-NAME" FontSize="16" FontWeight="Bold" Foreground="#E1E1E6" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        
                        <!-- Navigasyon Linkleri (Butonlar) -->
                        <StackPanel Grid.Row="1" Margin="10,10,10,0">
                            <RadioButton Name="menuDashboard" Content="Genel Pano" IsChecked="True" Style="{StaticResource SidebarRadioButtonStyle}"/>
                            <RadioButton Name="menuApps" Content="Uygulamalar" Style="{StaticResource SidebarRadioButtonStyle}"/>
                            <RadioButton Name="menuProjects" Content="Projeler" Style="{StaticResource SidebarRadioButtonStyle}"/>
                            <RadioButton Name="menuDevTools" Content="Geliştirici Önbellekleri" Style="{StaticResource SidebarRadioButtonStyle}"/>
                            <RadioButton Name="menuCloud" Content="Bulut ve Tarayıcı" Style="{StaticResource SidebarRadioButtonStyle}"/>
                            <RadioButton Name="menuSystem" Content="Sistem Özellikleri" Style="{StaticResource SidebarRadioButtonStyle}"/>
                        </StackPanel>
                        
                        <!-- Alt Butonlar (Yedekleme ve Raporlama) -->
                        <StackPanel Grid.Row="2" Margin="15,15,15,20">
                            <Button Name="btnBackupProjects" Content="Projeleri Klasöre Yedekle" Height="38" Style="{StaticResource BackupButtonStyle}" Margin="0,0,0,10" Cursor="Hand"/>
                            <Button Name="btnExport" Content="Yedekleme Raporu Üret" Height="38" Style="{StaticResource ExportButtonStyle}" Cursor="Hand"/>
                        </StackPanel>
                    </Grid>
                </Border>
                
                <!-- SAĞ İÇERİK PANESİ (TabControl ile yönetilir) -->
                <TabControl Grid.Column="1" Name="mainTabControl" Background="Transparent" BorderThickness="0" Margin="20">
                    <TabControl.Resources>
                        <Style TargetType="TabItem">
                            <Setter Property="Visibility" Value="Collapsed"/> <!-- Sekme başlıklarını gizle -->
                        </Style>
                    </TabControl.Resources>
                    
                    <!-- TAB 1: DASHBOARD -->
                    <TabItem Header="Genel Pano">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <TextBlock Text="Sistem Durum Özeti" FontSize="20" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,0,0,15"/>
                                
                                <!-- İstatistik Kartları -->
                                <UniformGrid Columns="3" Rows="1" Margin="0,0,0,20">
                                    <!-- Kart 1: Toplam Uygulama -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="10" Margin="0,0,10,0" Padding="15">
                                        <StackPanel>
                                            <TextBlock Text="YÜKLÜ UYGULAMALAR" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="dashAppCount" Text="0" FontSize="28" FontWeight="Bold" Foreground="#9D4EDD" Margin="0,5,0,0"/>
                                            <TextBlock Text="Masaüstü ve Store" FontSize="12" Foreground="#737380" Margin="0,5,0,0"/>
                                        </StackPanel>
                                    </Border>
                                    
                                    <!-- Kart 2: Yazılım Projeleri -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="10" Margin="5,0,5,0" Padding="15">
                                        <StackPanel>
                                            <TextBlock Text="PROJELER VE BOYUTU" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="dashProjSize" Text="0 MB" FontSize="28" FontWeight="Bold" Foreground="#00B4D8" Margin="0,5,0,0"/>
                                            <TextBlock Name="dashProjCount" Text="0 proje tespit edildi" FontSize="12" Foreground="#737380" Margin="0,5,0,0"/>
                                        </StackPanel>
                                    </Border>
                                    
                                    <!-- Kart 3: Temizlenebilir Önbellek -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="10" Margin="10,0,0,0" Padding="15">
                                        <StackPanel>
                                            <TextBlock Text="GELİŞTİRİCİ ÖNBELLEKLERİ" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="dashCacheSize" Text="0 MB" FontSize="28" FontWeight="Bold" Foreground="#FF5F56" Margin="0,5,0,0"/>
                                            <TextBlock Text="Temizlenebilir önbellek boyutu" FontSize="12" Foreground="#737380" Margin="0,5,0,0"/>
                                        </StackPanel>
                                    </Border>
                                </UniformGrid>
                                
                                <!-- Diskler / SSD Bölümü -->
                                <TextBlock Text="Sürücüler ve SSD Bölümleri" FontSize="16" FontWeight="SemiBold" Foreground="#E1E1E6" Margin="0,10,0,10"/>
                                <ItemsControl Name="lstDisks">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="10" Margin="0,0,0,10" Padding="15">
                                                <Grid>
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="Auto"/>
                                                        <ColumnDefinition Width="*"/>
                                                        <ColumnDefinition Width="Auto"/>
                                                    </Grid.ColumnDefinitions>
                                                    
                                                    <!-- Sürücü Harfi ve Tip -->
                                                    <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,20,0">
                                                        <TextBlock Text="{Binding Letter}" FontSize="24" FontWeight="Bold" Foreground="#9D4EDD" HorizontalAlignment="Center"/>
                                                        <TextBlock Text="{Binding Type}" FontSize="11" Foreground="#737380" HorizontalAlignment="Center"/>
                                                    </StackPanel>
                                                    
                                                    <!-- İlerleme Çubuğu ve İsim -->
                                                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                                        <Grid>
                                                            <TextBlock Text="{Binding Label}" FontSize="14" FontWeight="SemiBold" Foreground="#E1E1E6"/>
                                                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                                                <TextBlock Text="Kullanılan: " FontSize="12" Foreground="#A8A8B3"/>
                                                                <TextBlock Text="{Binding UsedSpace}" FontSize="12" FontWeight="SemiBold" Foreground="#E1E1E6"/>
                                                                <TextBlock Text=" / " FontSize="12" Foreground="#737380"/>
                                                                <TextBlock Text="{Binding TotalSize}" FontSize="12" Foreground="#A8A8B3"/>
                                                            </StackPanel>
                                                        </Grid>
                                                        
                                                        <ProgressBar Height="12" Value="{Binding UsedPercent}" Minimum="0" Maximum="100" Margin="0,8,0,0" Background="#22222A" BorderThickness="0" Style="{StaticResource GradientDiskBarStyle}"/>
                                                    </StackPanel>
                                                    
                                                    <!-- Doluluk Yüzdesi -->
                                                    <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="20,0,0,0">
                                                        <TextBlock Text="{Binding UsedPercent, StringFormat={}{0}%}" FontSize="18" FontWeight="Bold" Foreground="#E1E1E6" HorizontalAlignment="Right"/>
                                                        <TextBlock Text="{Binding FreeSpace, StringFormat={}{0} boş}" FontSize="11" Foreground="#737380" HorizontalAlignment="Right"/>
                                                    </StackPanel>
                                                </Grid>
                                            </Border>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </StackPanel>
                        </ScrollViewer>
                    </TabItem>
                    
                    <!-- TAB 2: UYGULAMALAR -->
                    <TabItem Header="Uygulamalar">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="45"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            
                            <TextBlock Grid.Row="0" Text="Yüklü Uygulamalar Listesi" FontSize="20" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,0,0,10"/>
                            
                            <!-- Arama ve Filtreler -->
                            <Grid Grid.Row="1" Margin="0,0,0,10">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="250"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                
                                <TextBox Grid.Column="0" Name="txtAppSearch" Margin="0,0,10,0"/>
                                <!-- TextBox Placeholder -->
                                <TextBlock Grid.Column="0" IsHitTestVisible="False" Text="Uygulama ara..." VerticalAlignment="Center" HorizontalAlignment="Left" Margin="12,0,0,0" Foreground="#555555" Name="txtAppSearchPlaceholder"/>
                                
                                <StackPanel Grid.Column="2" Orientation="Horizontal">
                                    <RadioButton Name="radAllApps" Content="Tümü" IsChecked="True" Style="{StaticResource AppFilterBtnStyle}" Margin="0,0,5,0"/>
                                    <RadioButton Name="radDesktopApps" Content="Masaüstü" Style="{StaticResource AppFilterBtnStyle}" Margin="0,0,5,0"/>
                                    <RadioButton Name="radStoreApps" Content="Mağaza" Style="{StaticResource AppFilterBtnStyle}"/>
                                </StackPanel>
                            </Grid>
                            
                            <!-- Uygulama Tablosu -->
                            <DataGrid Grid.Row="2" Name="dgApps">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Uygulama Adı" Binding="{Binding Name}" Width="2.5*"/>
                                    <DataGridTextColumn Header="Yayıncı" Binding="{Binding Publisher}" Width="1.5*"/>
                                    <DataGridTextColumn Header="Sürüm" Binding="{Binding Version}" Width="*"/>
                                    <DataGridTextColumn Header="Yükleme Tarihi" Binding="{Binding InstallDate}" Width="*"/>
                                    <DataGridTextColumn Header="Tür" Binding="{Binding Type}" Width="Auto"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Grid>
                    </TabItem>
                    
                    <!-- TAB 3: PROJELER -->
                    <TabItem Header="Projeler">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="45"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            
                            <TextBlock Grid.Row="0" Text="Yazılım Projeleriniz" FontSize="20" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,0,0,10"/>
                            
                            <!-- Arama kutusu -->
                            <Grid Grid.Row="1" Margin="0,0,0,10">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="250"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                
                                <TextBox Grid.Column="0" Name="txtProjSearch" Margin="0,0,10,0"/>
                                <TextBlock Grid.Column="0" IsHitTestVisible="False" Text="Proje ara..." VerticalAlignment="Center" HorizontalAlignment="Left" Margin="12,0,0,0" Foreground="#555555" Name="txtProjSearchPlaceholder"/>
                            </Grid>
                            
                            <!-- Projeler Tablosu -->
                            <DataGrid Grid.Row="2" Name="dgProjects">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Proje Adı" Binding="{Binding Name}" Width="1.5*"/>
                                    <DataGridTextColumn Header="Tür" Binding="{Binding Type}" Width="*"/>
                                    <DataGridTextColumn Header="Boyut" Binding="{Binding Size}" SortMemberPath="SizeBytes" Width="*"/>
                                    <DataGridTextColumn Header="Son Değiştirilme" Binding="{Binding LastModified}" Width="1.2*"/>
                                    <DataGridTextColumn Header="Dosya Yolu" Binding="{Binding Path}" Width="3*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Grid>
                    </TabItem>
                    
                    <!-- TAB 4: GELİŞTİRİCİ ÖNBELLEKLERİ -->
                    <TabItem Header="Geliştirici Önbellekleri">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            
                            <StackPanel Grid.Row="0" Margin="0,0,0,15">
                                <TextBlock Text="Geliştirici Önbellek ve SDK Klasörleri" FontSize="20" FontWeight="Bold" Foreground="#E1E1E6"/>
                                <TextBlock Text="Bu klasörler genellikle format sonrası tekrar yüklenebilen önbellek dosyalarıdır. Disk alanından tasarruf etmek için yedeklemeyebilirsiniz." 
                                           FontSize="13" Foreground="#A8A8B3" Margin="0,5,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                            
                            <DataGrid Grid.Row="1" Name="dgDevFolders">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Klasör Türü" Binding="{Binding Name}" Width="1.5*"/>
                                    <DataGridTextColumn Header="Klasör Tipi" Binding="{Binding Type}" Width="*"/>
                                    <DataGridTextColumn Header="Boyut" Binding="{Binding Size}" SortMemberPath="SizeBytes" Width="*"/>
                                    <DataGridTextColumn Header="Öneri" Binding="{Binding Recommended}" Width="2.5*"/>
                                    <DataGridTextColumn Header="Tam Yol" Binding="{Binding Path}" Width="3.5*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Grid>
                    </TabItem>
                    
                    <!-- TAB 5: BULUT VE TARAYICI -->
                    <TabItem Header="Bulut ve Tarayıcı">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel>
                                <TextBlock Text="Bulut Yedekleme ve Tarayıcı Profilleri" FontSize="20" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,0,0,15"/>
                                
                                <!-- Bulut Yedekleme -->
                                <TextBlock Text="Aktif Bulut İstemcileri" FontSize="16" FontWeight="SemiBold" Foreground="#9D4EDD" Margin="0,0,0,10"/>
                                <DataGrid Name="dgBackupApps" Height="180" Margin="0,0,0,20">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Yedekleme Uygulaması" Binding="{Binding Name}" Width="1.5*"/>
                                        <DataGridTextColumn Header="Durum" Binding="{Binding Status}" Width="1.2*"/>
                                        <DataGridTextColumn Header="Öneri" Binding="{Binding Recommended}" Width="3.5*"/>
                                        <DataGridTextColumn Header="Dosya Konumu" Binding="{Binding Path}" Width="4*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                
                                <!-- Tarayıcı Profilleri -->
                                <TextBlock Text="Tarayıcı Veri Klasörleri (Şifreler &amp; Geçmiş)" FontSize="16" FontWeight="SemiBold" Foreground="#00B4D8" Margin="0,10,0,10"/>
                                <DataGrid Name="dgBrowsers" Height="180">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Tarayıcı" Binding="{Binding Name}" Width="1.5*"/>
                                        <DataGridTextColumn Header="Boyut" Binding="{Binding Size}" SortMemberPath="SizeBytes" Width="*"/>
                                        <DataGridTextColumn Header="Öneri" Binding="{Binding Recommended}" Width="3.5*"/>
                                        <DataGridTextColumn Header="Klasör Konumu" Binding="{Binding Path}" Width="4*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </StackPanel>
                        </ScrollViewer>
                    </TabItem>
                    
                    <!-- TAB 6: SİSTEM ÖZELLİKLERİ -->
                    <TabItem Header="Sistem Özellikleri">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                
                                <!-- Sol Kolon -->
                                <StackPanel Grid.Column="0" Margin="0,0,10,0">
                                    <TextBlock Text="Sistem Donanım Detayları" FontSize="18" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,0,0,15"/>
                                    
                                    <!-- Bilgisayar Modeli -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Bilgisayar Model Bilgisi" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysCompModel" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- CPU -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="İşlemci (CPU)" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysCPU" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                            <TextBlock Name="sysCPUCores" Text="-" FontSize="12" Foreground="#737380" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>
                                    
                                    <!-- RAM -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Bellek (RAM)" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysRAM" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0"/>
                                            <TextBlock Name="sysRAMDetails" Text="-" FontSize="12" Foreground="#737380" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>
                                    
                                    <!-- GPU -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Ekran Kartı (GPU)" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysGPU" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                            <TextBlock Name="sysGPUDetails" Text="-" FontSize="12" Foreground="#737380" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Ekran Çözünürlüğü -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Ekran Çözünürlüğü &amp; Yenileme" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysResolution" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Fiziksel Diskler -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Fiziksel Diskler" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysPhysicalDisks" Text="-" FontSize="13" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                                
                                <!-- Sağ Kolon -->
                                <StackPanel Grid.Column="1" Margin="10,0,0,0">
                                    <TextBlock Text="Yazılım &amp; Anakart Detayları" FontSize="18" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,0,0,15"/>
                                    
                                    <!-- OS -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="İşletim Sistemi" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysOS" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                            <TextBlock Name="sysOSVersion" Text="-" FontSize="12" Foreground="#737380" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Ürün Kimliği (Product ID) -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Windows Ürün Kimliği (Product ID)" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysProductID" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Yetki Seviyesi -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Kullanıcı Yetki Seviyesi" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysIsAdmin" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Sistem Uptime -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Sistem Çalışma Süresi (Uptime)" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysUptime" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>
                                    
                                    <!-- Motherboard -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Anakart" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysMotherboard" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>
                                    
                                    <!-- BIOS -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="BIOS Sürümü" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysBIOS" Text="-" FontSize="14" FontWeight="Bold" Foreground="#E1E1E6" Margin="0,3,0,0"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Antivirüs -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Antivirüs / Güvenlik Yazılımı" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysAntivirus" Text="-" FontSize="13" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>

                                    <!-- Ağ Adaptörleri -->
                                    <Border Background="#1D1D22" BorderBrush="#29292E" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,10">
                                        <StackPanel>
                                            <TextBlock Text="Ağ Bağlantısı" FontSize="11" Foreground="#A8A8B3" FontWeight="SemiBold"/>
                                            <TextBlock Name="sysNetwork" Text="-" FontSize="13" Foreground="#E1E1E6" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                        </StackPanel>
                                    </Border>
                                </StackPanel>
                            </Grid>
                        </ScrollViewer>
                    </TabItem>
                </TabControl>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

try {
    $StringReader2 = New-Object System.IO.StringReader($Xaml.Trim())
    $XmlReader2 = [System.Xml.XmlReader]::Create($StringReader2)
    $Form = [Windows.Markup.XamlReader]::Load($XmlReader2)
}
catch {
    [System.Windows.MessageBox]::Show("Ana Arayüz Yükleme Hatası:`n$($_.Exception.Message)", "Hata", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit
}

# WPF Kontrolleri Hazırlandı

# ==========================================
# 4. ARAYÜZ ELEMANLARINI DEĞİŞKENLERE BAĞLA
# ==========================================
[regex]::Matches($Xaml, 'Name="([a-zA-Z0-9_]+)"') | ForEach-Object {
    $VarName = $_.Groups[1].Value
    $Control = $Form.FindName($VarName)
    if ($Control) {
        Set-Variable -Name "wpf_$VarName" -Value $Control -Scope Script
    }
}

# Başlık Bilgisi
$wpf_txtPCName.Text = $GlobalData.SystemInfo.ComputerName
$wpf_txtUserWelcome.Text = "Merhaba, $($GlobalData.SystemInfo.UserName) ⚡"

# ==========================================
# 5. DAHİLİ KONTROLLERİ VE VERİLERİ DOLDUR
# ==========================================

# A) Dashboard İstatistikleri
$wpf_dashAppCount.Text = ($GlobalData.InstalledApps.Count + $GlobalData.StoreApps.Count).ToString()

# Yazılım Projeleri Toplam Boyut
$totalProjBytes = 0
foreach ($p in $GlobalData.Projects) { $totalProjBytes += $p.SizeBytes }
$totalProjMB = [Math]::Round($totalProjBytes / 1MB, 1)
$totalProjGB = [Math]::Round($totalProjBytes / 1GB, 2)
$wpf_dashProjSize.Text = if ($totalProjGB -gt 1) { "$totalProjGB GB" } else { "$totalProjMB MB" }
$wpf_dashProjCount.Text = "$($GlobalData.Projects.Count) proje tespit edildi"

# Önbellek Klasörleri Toplam Boyut
$totalCacheBytes = 0
foreach ($c in $GlobalData.DeveloperFolders) { $totalCacheBytes += $c.SizeBytes }
$totalCacheMB = [Math]::Round($totalCacheBytes / 1MB, 1)
$totalCacheGB = [Math]::Round($totalCacheBytes / 1GB, 2)
$wpf_dashCacheSize.Text = if ($totalCacheGB -gt 1) { "$totalCacheGB GB" } else { "$totalCacheMB MB" }

# B) Disk Listesi
$wpf_lstDisks.ItemsSource = $GlobalData.Disks

# C) Uygulamalar
$wpf_dgApps.ItemsSource = $GlobalData.InstalledApps + $GlobalData.StoreApps

# D) Projeler
$wpf_dgProjects.ItemsSource = $GlobalData.Projects

# E) Geliştirici Klasörleri
$wpf_dgDevFolders.ItemsSource = $GlobalData.DeveloperFolders

# Geliştirici klasöre çift tıklayınca Explorer'da aç
$wpf_dgDevFolders.Add_MouseDoubleClick({
        $row = $wpf_dgDevFolders.SelectedItem
        if ($row -and $row.Path -and (Test-Path $row.Path)) {
            Start-Process "explorer.exe" $row.Path
        }
    })

# F) Bulut ve Tarayıcılar
$wpf_dgBackupApps.ItemsSource = $GlobalData.BackupApps
$wpf_dgBrowsers.ItemsSource = $GlobalData.Browsers

# G) Sistem Bilgileri Detayları
$wpf_sysCompModel.Text = $GlobalData.SystemInfo.ComputerModel
$wpf_sysCPU.Text = $GlobalData.SystemInfo.CPUName
$wpf_sysCPUCores.Text = "$($GlobalData.SystemInfo.CPUCores) Fiziksel / $($GlobalData.SystemInfo.CPULogical) Mantıksal Çekirdek • Temel Hız: $($GlobalData.SystemInfo.CPUSpeed)"
$wpf_sysRAM.Text = $GlobalData.SystemInfo.RAMSize
$wpf_sysRAMDetails.Text = "$($GlobalData.SystemInfo.RAMSlots) • Hız: $($GlobalData.SystemInfo.RAMSpeed) • Üretici: $($GlobalData.SystemInfo.RAMManufacturer)"
$wpf_sysGPU.Text = $GlobalData.SystemInfo.GPUName
$wpf_sysGPUDetails.Text = "Grafik Belleği (VRAM): $($GlobalData.SystemInfo.GPUVRAM)"
$wpf_sysResolution.Text = $GlobalData.SystemInfo.ScreenResolution
$wpf_sysPhysicalDisks.Text = $GlobalData.SystemInfo.PhysicalDisks
$wpf_sysOS.Text = $GlobalData.SystemInfo.OSName
$wpf_sysOSVersion.Text = "Sürüm: $($GlobalData.SystemInfo.OSVersion) ($($GlobalData.SystemInfo.OSArchitecture)) • Kurulum: $($GlobalData.SystemInfo.OSInstallDate)"
$wpf_sysProductID.Text = $GlobalData.SystemInfo.ProductID
$wpf_sysIsAdmin.Text = $GlobalData.SystemInfo.IsAdminStatus
$wpf_sysUptime.Text = $GlobalData.SystemInfo.SystemUptime
$wpf_sysMotherboard.Text = $GlobalData.SystemInfo.Motherboard
$wpf_sysBIOS.Text = "Sürüm: $($GlobalData.SystemInfo.BIOSVersion) • Tarih: $($GlobalData.SystemInfo.BIOSDate)"
$wpf_sysAntivirus.Text = $GlobalData.SystemInfo.AntivirusStatus
$wpf_sysNetwork.Text = "$($GlobalData.SystemInfo.NetworkName) • IP: $($GlobalData.SystemInfo.NetworkIP) • MAC: $($GlobalData.SystemInfo.NetworkMAC)"

# ==========================================
# 6. BUTON VE ETKİLEŞİM HANDLER'LARI
# ==========================================

# Pencereyi Kapat / Minimize Et
$wpf_btnClose.Add_Click({ $Form.Close() })
$wpf_btnMinimize.Add_Click({ $Form.WindowState = [System.Windows.WindowState]::Minimized })

# Pencere Sürükleme (Drag & Drop)
$wpf_TitleBar.Add_MouseLeftButtonDown({
        $_.Handled = $true
        $Form.DragMove()
    })

# Sol Menü Tıklama İşlemleri (TabControl Sekme Değişimi)
$wpf_menuDashboard.Add_Checked({ $wpf_mainTabControl.SelectedIndex = 0 })
$wpf_menuApps.Add_Checked({ $wpf_mainTabControl.SelectedIndex = 1 })
$wpf_menuProjects.Add_Checked({ $wpf_mainTabControl.SelectedIndex = 2 })
$wpf_menuDevTools.Add_Checked({ $wpf_mainTabControl.SelectedIndex = 3 })
$wpf_menuCloud.Add_Checked({ $wpf_mainTabControl.SelectedIndex = 4 })
$wpf_menuSystem.Add_Checked({ $wpf_mainTabControl.SelectedIndex = 5 })

# Arama TextBox Placeholder Gizleme/Gösterme
$wpf_txtAppSearch.Add_TextChanged({
        if ($wpf_txtAppSearch.Text.Length -gt 0) {
            $wpf_txtAppSearchPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed
        }
        else {
            $wpf_txtAppSearchPlaceholder.Visibility = [System.Windows.Visibility]::Visible
        }
        Filter-Apps
    })

$wpf_txtProjSearch.Add_TextChanged({
        if ($wpf_txtProjSearch.Text.Length -gt 0) {
            $wpf_txtProjSearchPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed
        }
        else {
            $wpf_txtProjSearchPlaceholder.Visibility = [System.Windows.Visibility]::Visible
        }
        Filter-Projects
    })

# Uygulama Arama ve Tür Filtreleme Fonksiyonu
function Filter-Apps {
    $search = $wpf_txtAppSearch.Text.ToLower()
    $filtered = @()
    
    # Hangi kaynağı filtreliyoruz?
    $source = @()
    if ($wpf_radAllApps.IsChecked) {
        $source = $GlobalData.InstalledApps + $GlobalData.StoreApps
    }
    elseif ($wpf_radDesktopApps.IsChecked) {
        $source = $GlobalData.InstalledApps
    }
    elseif ($wpf_radStoreApps.IsChecked) {
        $source = $GlobalData.StoreApps
    }
    
    foreach ($app in $source) {
        if ($app.Name.ToLower().Contains($search) -or $app.Publisher.ToLower().Contains($search)) {
            $filtered += $app
        }
    }
    $wpf_dgApps.ItemsSource = $filtered
}

$wpf_radAllApps.Add_Checked({ Filter-Apps })
$wpf_radDesktopApps.Add_Checked({ Filter-Apps })
$wpf_radStoreApps.Add_Checked({ Filter-Apps })

# Proje Arama Fonksiyonu
function Filter-Projects {
    $search = $wpf_txtProjSearch.Text.ToLower()
    $filtered = @()
    foreach ($p in $GlobalData.Projects) {
        if ($p.Name.ToLower().Contains($search) -or $p.Type.ToLower().Contains($search) -or $p.Path.ToLower().Contains($search)) {
            $filtered += $p
        }
    }
    $wpf_dgProjects.ItemsSource = $filtered
}

# Projeler Tablosunda Çift Tıklama Olayı (Dosya Gezgini'nde Konumu Aç)
$wpf_dgProjects.Add_MouseDoubleClick({
        $selectedItem = $wpf_dgProjects.SelectedItem
        if ($selectedItem -and $selectedItem.Path) {
            if (Test-Path $selectedItem.Path) {
                Start-Process explorer.exe -ArgumentList "`"$($selectedItem.Path)`""
            }
        }
    })

# Bulut Yedekleme Klasörünü Çift Tıklama ile Aç
$wpf_dgBackupApps.Add_MouseDoubleClick({
        $selectedItem = $wpf_dgBackupApps.SelectedItem
        if ($selectedItem -and $selectedItem.Path) {
            if (Test-Path $selectedItem.Path) {
                Start-Process explorer.exe -ArgumentList "`"$($selectedItem.Path)`""
            }
        }
    })

# Tarayıcı Profil Klasörünü Çift Tıklama ile Aç
$wpf_dgBrowsers.Add_MouseDoubleClick({
        $selectedItem = $wpf_dgBrowsers.SelectedItem
        if ($selectedItem -and $selectedItem.Path) {
            if (Test-Path $selectedItem.Path) {
                Start-Process explorer.exe -ArgumentList "`"$($selectedItem.Path)`""
            }
        }
    })

# Projeleri Klasöre Yedekle Buton Olayı
$wpf_btnBackupProjects.Add_Click({
        if ($GlobalData.Projects.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Yedeklenecek proje bulunamadı!", "Uyarı", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }

        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Projelerin yedekleneceği klasörü seçin"
        $dialog.ShowNewFolderButton = $true
    
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $targetBase = $dialog.SelectedPath
            $backupFolder = Join-Path $targetBase "FormatBackup_Projects"
        
            if (-not (Test-Path $backupFolder)) {
                New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
            }
        
            # İmleci bekleme moduna al
            [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
        
            try {
                $successCount = 0
                $failCount = 0
            
                foreach ($p in $GlobalData.Projects) {
                    if (Test-Path $p.Path) {
                        $projDest = Join-Path $backupFolder $p.Name
                        try {
                            Copy-Item -Path $p.Path -Destination $projDest -Recurse -Force -ErrorAction Stop
                            $successCount++
                        }
                        catch {
                            $failCount++
                        }
                    }
                }
            
                [System.Windows.Input.Mouse]::OverrideCursor = $null
            
                $msg = "Yedekleme tamamlandı!`n`nBaşarılı: $successCount`nHatalı/Atlanan: $failCount`n`nYedek Konumu: $backupFolder"
                [System.Windows.MessageBox]::Show($msg, "Yedekleme Sonucu", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
            catch {
                [System.Windows.Input.Mouse]::OverrideCursor = $null
                [System.Windows.MessageBox]::Show("Yedekleme sırasında bir hata oluştu: $($_.Exception.Message)", "Hata", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            }
        }
    })

# ==========================================
# 7. HTML YEDEKLEME RAPORU ÜRETME VE KAYDETME
# ==========================================
$wpf_btnExport.Add_Click({
        $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
        $saveDialog.Filter = "HTML Dosyası (*.html)|*.html"
        $saveDialog.FileName = "FormatBackup_Raporu.html"
        $saveDialog.Title = "Yedekleme Raporunu Kaydet"
    
        if ($saveDialog.ShowDialog() -eq $true) {
            $filePath = $saveDialog.FileName
        
            # Verileri JSON formatına dönüştür
            $jsonData = $GlobalData | ConvertTo-Json -Depth 10
        
            # HTML Şablonu
            $htmlContent = @"
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FormatBackup Sistem Analiz Raporu</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg: #0c0c0e;
            --card-bg: #121216;
            --card-border: #22222a;
            --text-main: #e1e1e6;
            --text-sec: #a8a8b3;
            --primary: #9d4edd;
            --secondary: #00b4d8;
            --success: #4eca8d;
            --danger: #ff5f56;
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            background-color: var(--bg);
            color: var(--text-main);
            font-family: 'Inter', sans-serif;
            padding: 30px;
            font-size: 14px;
            line-height: 1.5;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--card-border);
            padding-bottom: 20px;
            margin-bottom: 30px;
        }
        
        .logo {
            font-size: 24px;
            font-weight: 800;
            color: var(--text-main);
        }
        
        .logo span {
            color: var(--secondary);
            font-weight: 300;
        }
        
        .os-tag {
            background-color: #1a1a24;
            color: var(--secondary);
            padding: 6px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
            border: 1px solid rgba(0, 180, 216, 0.2);
        }
        
        .grid-3 {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        
        .card {
            background-color: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 12px;
            padding: 20px;
        }
        
        .card-title {
            font-size: 11px;
            color: var(--text-sec);
            text-transform: uppercase;
            font-weight: 700;
            margin-bottom: 10px;
            letter-spacing: 1px;
        }
        
        .card-value {
            font-size: 28px;
            font-weight: 700;
            color: var(--primary);
        }
        
        .section-title {
            font-size: 18px;
            font-weight: 600;
            margin: 40px 0 15px 0;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
            border-radius: 8px;
            overflow: hidden;
            border: 1px solid var(--card-border);
        }
        
        th, td {
            padding: 12px 15px;
            text-align: left;
        }
        
        th {
            background-color: #1a1a24;
            color: var(--secondary);
            font-weight: 600;
            font-size: 13px;
        }
        
        tr {
            background-color: var(--card-bg);
            border-bottom: 1px solid var(--card-border);
        }
        
        tr:last-child {
            border-bottom: none;
        }
        
        tr:hover {
            background-color: #1c1c24;
        }
        
        .disk-item {
            display: flex;
            flex-direction: column;
            gap: 8px;
            margin-bottom: 15px;
        }
        
        .disk-header {
            display: flex;
            justify-content: space-between;
            font-size: 14px;
        }
        
        .progress-bar {
            height: 10px;
            background-color: #25252e;
            border-radius: 0px;
            overflow: hidden;
        }
        
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, var(--primary), var(--secondary));
            border-radius: 0px;
        }
        
        .search-box {
            width: 100%;
            padding: 12px;
            background-color: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 8px;
            color: var(--text-main);
            font-family: inherit;
            font-size: 14px;
            margin-bottom: 15px;
        }
        
        .search-box:focus {
            outline: none;
            border-color: var(--primary);
        }
        
        .status-badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 600;
        }
        
        .status-active {
            background-color: #1d3a2c;
            color: var(--success);
        }
        
        .status-recommend {
            background-color: #2b1b3d;
            color: var(--secondary);
        }
        
        .tab-btn {
            background: none;
            border: none;
            color: var(--text-sec);
            font-size: 15px;
            font-weight: 600;
            padding: 10px 20px;
            cursor: pointer;
            border-bottom: 2px solid transparent;
            transition: all 0.2s ease;
        }
        
        .tab-btn.active {
            color: var(--secondary);
            border-bottom-color: var(--secondary);
        }
        
        .tabs {
            display: flex;
            gap: 10px;
            border-bottom: 1px solid var(--card-border);
            margin-bottom: 20px;
        }
        
        .tab-content {
            display: none;
        }
        
        .tab-content.active {
            display: block;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="logo">⚡ FormatBackup <span>Analiz Raporu</span></div>
            <div class="os-tag">$($GlobalData.SystemInfo.OSName)</div>
        </header>
        
        <div class="grid-3">
            <div class="card">
                <div class="card-title">Yüklü Uygulama Sayısı</div>
                <div class="card-value" style="color: var(--primary)">$($GlobalData.InstalledApps.Count + $GlobalData.StoreApps.Count)</div>
            </div>
            <div class="card">
                <div class="card-title">Yazılım Projeleri Boyutu</div>
                <div class="card-value" style="color: var(--secondary)">$($wpf_dashProjSize.Text)</div>
            </div>
            <div class="card">
                <div class="card-title">Geliştirici Önbellekleri</div>
                <div class="card-value" style="color: var(--danger)">$($wpf_dashCacheSize.Text)</div>
            </div>
        </div>
        
        <div class="tabs">
            <button class="tab-btn active" onclick="switchTab(event, 'tab-general')">Genel &amp; Diskler</button>
            <button class="tab-btn" onclick="switchTab(event, 'tab-apps')">Uygulamalar</button>
            <button class="tab-btn" onclick="switchTab(event, 'tab-projects')">Yazılım Projeleri</button>
            <button class="tab-btn" onclick="switchTab(event, 'tab-dev')">Geliştirici Önbellekleri</button>
            <button class="tab-btn" onclick="switchTab(event, 'tab-cloud')">Bulut &amp; Tarayıcı</button>
        </div>
        
        <!-- GENEL VE DİSKLER -->
        <div id="tab-general" class="tab-content active">
            <div class="grid-3">
                <div class="card" style="grid-column: span 2;">
                    <div class="card-title">Sistem Donanım Özeti</div>
                    <table style="border: none; margin-top: 0;">
                        <tr><td style="font-weight:600; color: var(--secondary);">Bilgisayar Adı / Kullanıcı</td><td>$($GlobalData.SystemInfo.ComputerName) / $($GlobalData.SystemInfo.UserName)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Bilgisayar Modeli</td><td>$($GlobalData.SystemInfo.ComputerModel)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">İşletim Sistemi (OS)</td><td>$($GlobalData.SystemInfo.OSName) (Sürüm: $($GlobalData.SystemInfo.OSVersion), Kurulum: $($GlobalData.SystemInfo.OSInstallDate))</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Windows Ürün Kimliği</td><td>$($GlobalData.SystemInfo.ProductID)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Yetki Seviyesi</td><td>$($GlobalData.SystemInfo.IsAdminStatus)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Sistem Açık Kalma Süresi</td><td>$($GlobalData.SystemInfo.SystemUptime)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">İşlemci (CPU)</td><td>$($GlobalData.SystemInfo.CPUName) ($($GlobalData.SystemInfo.CPUCores) Çekirdek, Temel Hız: $($GlobalData.SystemInfo.CPUSpeed))</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Bellek (RAM)</td><td>$($GlobalData.SystemInfo.RAMSize) ($($GlobalData.SystemInfo.RAMSlots), Hız: $($GlobalData.SystemInfo.RAMSpeed), Üretici: $($GlobalData.SystemInfo.RAMManufacturer))</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Ekran Kartı (GPU)</td><td>$($GlobalData.SystemInfo.GPUName) (VRAM: $($GlobalData.SystemInfo.GPUVRAM))</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Ekran Çözünürlüğü</td><td>$($GlobalData.SystemInfo.ScreenResolution)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Anakart / BIOS</td><td>$($GlobalData.SystemInfo.Motherboard) (BIOS: $($GlobalData.SystemInfo.BIOSVersion), Tarih: $($GlobalData.SystemInfo.BIOSDate))</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Güvenlik / Antivirüs</td><td>$($GlobalData.SystemInfo.AntivirusStatus)</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Ağ Bağlantısı</td><td>$($GlobalData.SystemInfo.NetworkName) (IP: $($GlobalData.SystemInfo.NetworkIP), MAC: $($GlobalData.SystemInfo.NetworkMAC))</td></tr>
                        <tr><td style="font-weight:600; color: var(--secondary);">Fiziksel Diskler</td><td>$($GlobalData.SystemInfo.PhysicalDisks)</td></tr>
                    </table>
                </div>
                
                <div class="card">
                    <div class="card-title">Disk Bölümleri</div>
                    <div id="disk-list"></div>
                </div>
            </div>
        </div>
        
        <!-- UYGULAMALAR -->
        <div id="tab-apps" class="tab-content">
            <input type="text" class="search-box" id="appSearch" placeholder="Uygulama adı veya yayıncı ara..." onkeyup="filterApps()">
            <table id="appsTable">
                <thead>
                    <tr>
                        <th>Uygulama Adı</th>
                        <th>Yayıncı</th>
                        <th>Sürüm</th>
                        <th>Yükleme Tarihi</th>
                        <th>Tür</th>
                    </tr>
                </thead>
                <tbody id="appsBody"></tbody>
            </table>
        </div>
        
        <!-- PROJELER -->
        <div id="tab-projects" class="tab-content">
            <input type="text" class="search-box" id="projSearch" placeholder="Proje veya teknoloji ara..." onkeyup="filterProjects()">
            <table id="projectsTable">
                <thead>
                    <tr>
                        <th>Proje Adı</th>
                        <th>Tür</th>
                        <th>Boyut</th>
                        <th>Son Değiştirilme</th>
                        <th>Dosya Yolu</th>
                    </tr>
                </thead>
                <tbody id="projectsBody"></tbody>
            </table>
        </div>
        
        <!-- GELİŞTİRİCİ ÖNBELLEKLERİ -->
        <div id="tab-dev" class="tab-content">
            <table>
                <thead>
                    <tr>
                        <th>Klasör Adı</th>
                        <th>Klasör Tipi</th>
                        <th>Boyut</th>
                        <th>Öneri</th>
                        <th>Dosya Konumu</th>
                    </tr>
                </thead>
                <tbody id="devBody"></tbody>
            </table>
        </div>
        
        <!-- BULUT VE TARAYICI -->
        <div id="tab-cloud" class="tab-content">
            <div class="section-title">Bulut İstemcileri</div>
            <table id="cloudTable" style="margin-bottom: 30px;">
                <thead>
                    <tr>
                        <th>İstemci</th>
                        <th>Durum</th>
                        <th>Yol</th>
                        <th>Tavsiye</th>
                    </tr>
                </thead>
                <tbody id="cloudBody"></tbody>
            </table>
            
            <div class="section-title">Tarayıcı Profilleri</div>
            <table id="browserTable">
                <thead>
                    <tr>
                        <th>Tarayıcı</th>
                        <th>Boyut</th>
                        <th>Klasör Konumu</th>
                        <th>Tavsiye</th>
                    </tr>
                </thead>
                <tbody id="browserBody"></tbody>
            </table>
        </div>
    </div>

    <script>
        // Veri Yapısı
        const data = $jsonData;
        
        // Sekme Değiştirme
        function switchTab(e, tabId) {
            document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(content => content.classList.remove('active'));
            
            e.currentTarget.classList.add('active');
            document.getElementById(tabId).classList.add('active');
        }
        
        // Diskleri Doldur
        const diskList = document.getElementById('disk-list');
        data.Disks.forEach(d => {
            diskList.innerHTML += 
                '<div class="disk-item">' +
                    '<div class="disk-header">' +
                        '<strong>' + d.Letter + ' (' + (d.Label || 'Yeni Birim') + ')</strong>' +
                        '<span>' + d.UsedSpace + ' / ' + d.TotalSize + '</span>' +
                    '</div>' +
                    '<div class="progress-bar">' +
                        '<div class="progress-fill" style="width: ' + d.UsedPercent + '%"></div>' +
                    '</div>' +
                    '<div style="font-size: 11px; color: var(--text-sec); display: flex; justify-content: space-between;">' +
                        '<span>' + d.FreeSpace + ' boş</span>' +
                        '<span>' + d.UsedPercent + '% dolu</span>' +
                    '</div>' +
                '</div>';
        });
        
        // Uygulamaları Doldur
        const appsBody = document.getElementById('appsBody');
        const allApps = [...data.InstalledApps, ...data.StoreApps];
        function renderApps(list) {
            appsBody.innerHTML = '';
            list.forEach(a => {
                const badgeClass = a.Type === 'Masaüstü' ? 'status-recommend' : 'status-active';
                appsBody.innerHTML += 
                    '<tr>' +
                        '<td style="font-weight: 600;">' + a.Name + '</td>' +
                        '<td>' + (a.Publisher || 'Bilinmiyor') + '</td>' +
                        '<td>' + (a.Version || 'Bilinmiyor') + '</td>' +
                        '<td>' + (a.InstallDate || 'Bilinmiyor') + '</td>' +
                        '<td><span class="status-badge ' + badgeClass + '">' + a.Type + '</span></td>' +
                    '</tr>';
            });
        }
        renderApps(allApps);
        
        function filterApps() {
            const query = document.getElementById('appSearch').value.toLowerCase();
            const filtered = allApps.filter(a => 
                a.Name.toLowerCase().includes(query) || 
                (a.Publisher && a.Publisher.toLowerCase().includes(query))
            );
            renderApps(filtered);
        }
        
        // Projeleri Doldur
        const projectsBody = document.getElementById('projectsBody');
        function renderProjects(list) {
            projectsBody.innerHTML = '';
            list.forEach(p => {
                projectsBody.innerHTML += 
                    '<tr>' +
                        '<td style="font-weight: 600;">' + p.Name + '</td>' +
                        '<td>' + p.Type + '</td>' +
                        '<td style="color: var(--secondary); font-weight: 600;">' + p.Size + '</td>' +
                        '<td>' + p.LastModified + '</td>' +
                        '<td style="font-family: monospace; font-size: 12px; color: var(--text-sec);">' + p.Path + '</td>' +
                    '</tr>';
            });
        }
        renderProjects(data.Projects);
        
        function filterProjects() {
            const query = document.getElementById('projSearch').value.toLowerCase();
            const filtered = data.Projects.filter(p => 
                p.Name.toLowerCase().includes(query) || 
                p.Type.toLowerCase().includes(query) || 
                p.Path.toLowerCase().includes(query)
            );
            renderProjects(filtered);
        }
        
        // Geliştirici Klasörlerini Doldur
        const devBody = document.getElementById('devBody');
        data.DeveloperFolders.forEach(df => {
            devBody.innerHTML += 
                '<tr>' +
                    '<td style="font-weight: 600; color: var(--danger);">' + df.Name + '</td>' +
                    '<td>' + df.Type + '</td>' +
                    '<td style="font-weight: 600;">' + df.Size + '</td>' +
                    '<td>' + df.Recommended + '</td>' +
                    '<td style="font-family: monospace; font-size: 12px; color: var(--text-sec);">' + df.Path + '</td>' +
                '</tr>';
        });
        
        // Bulut ve Tarayıcı Doldur
        const cloudBody = document.getElementById('cloudBody');
        data.BackupApps.forEach(c => {
            cloudBody.innerHTML += 
                '<tr>' +
                    '<td style="font-weight: 600;">' + c.Name + '</td>' +
                    '<td><span class="status-badge status-active">' + c.Status + '</span></td>' +
                    '<td style="font-family: monospace; font-size: 12px;">' + c.Path + '</td>' +
                    '<td style="color: var(--text-sec); font-size: 12px;">' + c.Recommended + '</td>' +
                '</tr>';
        });
        
        const browserBody = document.getElementById('browserBody');
        data.Browsers.forEach(b => {
            browserBody.innerHTML += 
                '<tr>' +
                    '<td style="font-weight: 600;">' + b.Name + '</td>' +
                    '<td>' + b.Size + '</td>' +
                    '<td style="font-family: monospace; font-size: 12px; color: var(--text-sec);">' + b.Path + '</td>' +
                    '<td style="color: var(--text-sec); font-size: 12px;">' + b.Recommended + '</td>' +
                '</tr>';
        });
    </script>
</body>
</html>
"@
            [System.IO.File]::WriteAllText($filePath, $htmlContent, [System.Text.Encoding]::UTF8)
            [System.Windows.MessageBox]::Show("HTML Raporu başarıyla oluşturuldu!", "Başarılı", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    })

# ==========================================
# 8. UYGULAMAYI BAŞLAT
# ==========================================
$Form.ShowDialog() | Out-Null
$Form.ShowDialog() | Out-Null

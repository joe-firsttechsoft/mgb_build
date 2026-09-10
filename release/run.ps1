param(
    [ValidateSet("1-3_SIT", "UAT", "2-1_SIT", "2-2_SIT", "2-3_SIT")]
    [string]$BranchType
)

# 若未傳入參數，以互動選單詢問
if (-not $BranchType) {
    # 取得目前 mgbfep repo 的 branch，用於預設選項
    $UserNameEarly = [System.Environment]::UserName
    $RepoPathEarly = if ($IsWindows) { "C:\Users\$UserNameEarly\Repo\idea_clone\mgbfep" } else { "/Users/$UserNameEarly/Repo/idea_clone/mgbfep" }
    $CurrentGitBranch = (git -C $RepoPathEarly rev-parse --abbrev-ref HEAD 2>$null).Trim()

    # branch 名稱 → BranchType 反向對應
    $GitBranchToType = @{
        "FEP_1-3_SIT"   = "1-3_SIT"
        "FEP_1-3-2_UAT" = "UAT"
        "FEP_2-1"       = "2-1_SIT"
        "FEP_2-2"       = "2-2_SIT"
        "FEP_2-3"       = "2-3_SIT"
    }
    $CurrentBranchType = $GitBranchToType[$CurrentGitBranch]

    Write-Host ""
    Write-Host " 請選擇 Branch："
    Write-Host " [1] FEP_1-3_SIT"
    Write-Host " [2] FEP_2-1"
    Write-Host " [3] FEP_2-2"
    Write-Host " [4] FEP_2-3"
    Write-Host " [5] UAT（當前：$CurrentGitBranch）"
    if ($CurrentBranchType) {
        Write-Host " [Enter] 當前：$CurrentGitBranch（預設）" -ForegroundColor Cyan
    }
    $branchInput = Read-Host " 請輸入選項"
    $BranchType = switch ($branchInput.Trim()) {
        "1"  { "1-3_SIT" }
        "2"  { "2-1_SIT" }
        "3"  { "2-2_SIT" }
        "4"  { "2-3_SIT" }
        "5"  { "UAT" }
        ""   {
            if ($CurrentBranchType) { $CurrentBranchType }
            else { Write-Host " ❌ 無法判斷目前 branch，請手動輸入選項" -ForegroundColor Red; exit 1 }
        }
        default { Write-Host " ❌ 無效選項：$branchInput" -ForegroundColor Red; exit 1 }
    }
}

# =============================================
# 環境設定
# =============================================
$ScriptDir = $PSScriptRoot
# 跨平台取得目前使用者名稱（$env:USERNAME 僅 Windows 有，macOS/Linux 需用 $env:USER）
$UserName = [System.Environment]::UserName
$RepoPath  = if ($IsWindows) {
    "C:\Users\$UserName\Repo\idea_clone\mgbfep"
} else {
    "/Users/$UserName/Repo/idea_clone/mgbfep"
}
# docker-build 是本 repo（release/ 的上一層）的同層資料夾，
# 用相對路徑推算，避免不同機器上 repo 資料夾名稱不一致（例如 Windows 上叫 FEP_BUILD）導致路徑找不到
$DockerBuildDir = Join-Path (Split-Path $ScriptDir -Parent) "docker-build"

$Python = if ($IsWindows) {
    Join-Path $ScriptDir "myenv\Scripts\python.exe"
} else {
    Join-Path $ScriptDir "myenv/bin/python3"
}

if (-not (Test-Path $Python)) {
    Write-Host " ❌ 找不到虛擬環境 Python：$Python" -ForegroundColor Red
    Write-Host " 此機器尚未建立 myenv（venv 不能跨平台搬用，每台機器需自行建立），請執行：" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   cd `"$ScriptDir`""
    if ($IsWindows) {
        Write-Host "   python -m venv myenv"
        Write-Host "   .\myenv\Scripts\python.exe -m pip install requests pandas openpyxl"
    } else {
        Write-Host "   python3 -m venv myenv"
        Write-Host "   ./myenv/bin/python3 -m pip install requests pandas openpyxl"
    }
    Write-Host ""
    exit 1
}

$env:RELEASE_NOTE_INPUT = Join-Path $ScriptDir "ReleaseNoteUpdateData.txt"
$env:RELEASE_NOTE_PATH  = Join-Path $RepoPath "source" "fep-release-note"

# 避免 macOS 在 exFAT 外接碟上建立 ._ resource fork 檔案（Windows/Linux 忽略此變數）
$env:COPYFILE_DISABLE = "1"

$GitBranch = switch ($BranchType) {
    "1-3_SIT" { "FEP_1-3_SIT" }
    "UAT"     { "FEP_1-3-2_UAT" }
    "2-1_SIT" { "FEP_2-1" }
    "2-2_SIT" { "FEP_2-2" }
    "2-3_SIT" { "FEP_2-3" }
}

# 依平台選擇對應的 .env（路徑格式不同，Windows/macOS 分開維護）
$EnvFileName = if ($IsWindows) { ".env.windows" } else { ".env.macos" }
$EnvFile = Join-Path $DockerBuildDir $EnvFileName
if (-not (Test-Path $EnvFile)) {
    Write-Host " ❌ 找不到 $EnvFileName：$EnvFile" -ForegroundColor Red
    Write-Host " 請從 $EnvFileName.example 複製一份，依本機路徑修改後使用" -ForegroundColor Yellow
    exit 1
}
$EnvVars = @{}
Get-Content $EnvFile | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
    $key, $val = $_ -split '=', 2
    $EnvVars[$key.Trim()] = $val.Trim()
}
$OutputPath = $EnvVars["HOST_OUTPUT_PATH"]
if (-not $OutputPath) {
    Write-Host " ❌ .env 中未設定 HOST_OUTPUT_PATH：$EnvFile" -ForegroundColor Red
    exit 1
}

Write-Host "================================================"
Write-Host " FEP Release Note 更新 & 包版工具"
Write-Host " Branch : $GitBranch"
Write-Host "================================================"

# 記錄原始目錄，腳本結束（含中途 exit）時切回去，避免切換到專案資料夾
$OriginalLocation = Get-Location

try {

Set-Location $RepoPath

# =============================================
# Helper：步驟失敗時詢問是否繼續或中止
# =============================================
function Test-StepResult {
    param(
        [string]$StepName,
        [int]$Code = $LASTEXITCODE
    )
    if ($Code -ne 0) {
        Write-Host ""
        Write-Host " ❌ $StepName 執行失敗（exit code: $Code）" -ForegroundColor Red
        $cont = Read-Host " [Enter] 繼續後續步驟 / [Q] 中止"
        if ($cont -imatch '^[Qq]') { exit $Code }
    }
}

# =============================================
# [1/7] git reset --hard（清空未 commit 變更，避免下一步 checkout 失敗）
# =============================================
Write-Host ""
Write-Host "[1/7] git reset"
Write-Host "------------------------------------------------"

# 顯示未 commit 的差異
$diffStat = git diff --stat HEAD 2>$null
$statusOut = git status --short 2>$null
if ($diffStat -or $statusOut) {
    Write-Host " 📋 目前未 commit 的變更："
    if ($statusOut) { $statusOut | ForEach-Object { Write-Host "   $_" } }
    if ($diffStat)  { $diffStat  | ForEach-Object { Write-Host "   $_" } }
    Write-Host "------------------------------------------------"
    $resetChoice = Read-Host " git reset --hard  [S] 略過 / [Enter] 執行（將捨棄以上變更）"
    if ($resetChoice -ieq "S") {
        Write-Host " ⏭️  略過 git reset（未 commit 變更可能導致下一步 checkout 失敗）" -ForegroundColor Yellow
    } else {
        Write-Host " git reset --hard HEAD"
        git reset --hard HEAD
        Test-StepResult "git reset --hard HEAD"
    }
} else {
    Write-Host " ✅ 目前無未 commit 的變更，略過 reset"
}

# =============================================
# [2/7] git checkout + git pull（僅在非目標 branch 時 checkout；pull 可 skip）
# =============================================
Write-Host ""
$currentBranch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
if ($currentBranch -ne $GitBranch) {
    Write-Host "[2/7] git checkout $GitBranch（目前：$currentBranch）"
    git checkout $GitBranch
    Test-StepResult "git checkout $GitBranch"
} else {
    Write-Host "[2/7] 已在 $GitBranch，略過 checkout"
}

$pullChoice = Read-Host " git pull origin $GitBranch  [S] 略過 / [Enter] 執行"
if ($pullChoice -ieq "S") {
    Write-Host " ⏭️  略過 git pull"
    if ($EnvVars["GIT_PULL"] -ine "true") {
        Write-Host " ⚠️  警告：略過 pull 且 container GIT_PULL 非 true，docker build 可能使用舊版程式碼" -ForegroundColor Yellow
    }
} else {
    Write-Host " git pull origin $GitBranch"
    git pull origin $GitBranch
    Test-StepResult "git pull origin $GitBranch"
}

# 初始化（UAT 模式略過 [3-5/7]，確保後續步驟變數已定義）
$step3Choice = "S"
$skipCommit  = $true

if ($BranchType -eq 'UAT') {
    Write-Host ""
    Write-Host "[3-5/7] UAT 模式 → 略過 SharePoint 讀取 / release note 更新 / git commit"
} else {
    # =============================================
    # [3/7] SharePoint 讀取 → txt（可 skip）
    # =============================================
    Write-Host ""
    Write-Host "------------------------------------------------"
    $step3Choice = Read-Host "[3/7] SharePoint 讀取 → txt  [S] 略過 / [Enter] 執行"
    if ($step3Choice -ieq "S") {
        if (-not (Test-Path $env:RELEASE_NOTE_INPUT)) {
            Write-Host " ❌ 錯誤：略過下載但 txt 不存在：$($env:RELEASE_NOTE_INPUT)" -ForegroundColor Red
            $cont = Read-Host " [Enter] 繼續後續步驟 / [Q] 中止"
            if ($cont -imatch '^[Qq]') { exit 1 }
        }
        Write-Host " ⏭️  略過，使用現有 txt"
    } else {
        & $Python (Join-Path $ScriptDir "fetch_release_script.py") $BranchType
        Test-StepResult "SharePoint 讀取（fetch_release_script.py）"
    }

    # 確認 txt 內容（僅在有下載時需確認）
    if ($step3Choice -ine "S") {
        Write-Host ""
        Write-Host "------------------------------------------------"
        Write-Host " 📄 txt 內容（本次下載）：$($env:RELEASE_NOTE_INPUT)"
        Write-Host "------------------------------------------------"
        Get-Content $env:RELEASE_NOTE_INPUT | ForEach-Object { Write-Host "   $_" }
        Write-Host "------------------------------------------------"
        Read-Host " 確認無誤後按 Enter 繼續，或按 Ctrl+C 中止"
    }

    # =============================================
    # [4/7] txt → release note（可 skip，skip 則自動 skip [5]）
    # =============================================
    $skipCommit = $false
    Write-Host ""
    Write-Host "------------------------------------------------"
    $step4Choice = Read-Host "[4/7] 更新 release note  [S] 略過（連帶略過 git commit）/ [Enter] 執行"
    if ($step4Choice -ieq "S") {
        $skipCommit = $true
        Write-Host " ⏭️  略過更新 release note，自動略過 [5/7] git commit"
    } else {
        & $Python (Join-Path $ScriptDir "UpdateReleaseNote.py")
        Test-StepResult "更新 release note（UpdateReleaseNote.py）"

        Write-Host ""
        Write-Host "------------------------------------------------"
        Write-Host " 請確認以下 release note 變更是否正確"
        Write-Host "------------------------------------------------"
        git diff source/fep-release-note/
        Write-Host "------------------------------------------------"
        Read-Host " 確認無誤後按 Enter 繼續，或按 Ctrl+C 中止"
    }

    # =============================================
    # [5/7] git commit release note（[4] skip 則自動 skip，否則可 skip）
    # =============================================
    Write-Host ""
    if ($skipCommit) {
        Write-Host "[5/7] git commit → [4/7] 已略過，自動略過"
    } else {
        Write-Host "------------------------------------------------"
        $step5Choice = Read-Host "[5/7] git commit release note  [S] 略過 / [Enter] 執行"
        if ($step5Choice -ieq "S") {
            Write-Host " ⏭️  略過 git commit"
        } else {
            git add (Join-Path "source" "fep-release-note")
            git commit -m "更新版號"

            Write-Host ""
            Write-Host "------------------------------------------------"
            Write-Host " 請確認 commit 內容是否正確"
            Write-Host "------------------------------------------------"
            git show --stat HEAD
            Write-Host "------------------------------------------------"
            Read-Host " 確認無誤後按 Enter 繼續，或按 Ctrl+C 中止"
        }
    }
}

# =============================================
# Helper functions
# =============================================
function Get-MavenModules {
    param([string]$TxtPath)
    if (-not (Test-Path $TxtPath)) { return @() }
    $content = Get-Content $TxtPath -Raw

    $releaseNames = [regex]::Matches($content, '"([^"]+)\{') | ForEach-Object {
        $_.Groups[1].Value -split "`n" | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    }

    $prefixMap = [ordered]@{
        "fep-batch-task"     = "fep-batch-task"
        "fep-batch-cmdline"  = "fep-batch-cmdline"
        "fep-enckey-cmdline" = "fep-enckey-cmdline"
        "fep-batch"          = "fep-batch"
        "fep-server"         = "fep-server"
        "fep-gateway"        = "fep-gateway"
        "fep-service"        = "fep-service"
        "fep-notify"         = "fep-notify"
        "fep-web"            = "fep-web"
    }

    $result = @()
    foreach ($name in $releaseNames) {
        foreach ($prefix in $prefixMap.Keys) {
            if ($name -eq $prefix -or $name.StartsWith("$prefix-")) {
                if ($prefixMap[$prefix] -notin $result) { $result += $prefixMap[$prefix] }
                break
            }
        }
    }
    return $result
}

function Select-BuildMode {
    param([string]$Current)

    $options = @(
        @{ Key="1"; Mode="+web";    Desc="全部服務 + WAR（SIT 過版最常用）" },
        @{ Key="2"; Mode="-Pwar";   Desc="JAR + WAR（fep-war profile）" },
        @{ Key="3"; Mode="-web";    Desc="僅 fep-web.war" },
        @{ Key="4"; Mode="-enclib"; Desc="僅 enclib 模組" },
        @{ Key="5"; Mode="-safeaa"; Desc="僅 safeaa core" },
        @{ Key="6"; Mode="";        Desc="完整建置（僅 JAR，不含 WAR）" }
    )

    Write-Host " BUILD_MODE（目前 .env：$(if ($Current) { $Current } else { '（空白）' })）"
    Write-Host ""
    foreach ($opt in $options) {
        $marker = if ($opt.Mode -eq $Current) { "►" } else { " " }
        Write-Host " $marker [$($opt.Key)] $($opt.Mode.PadRight(10)) $($opt.Desc)"
    }
    Write-Host ""
    $choice = Read-Host " 輸入選項編號更改，或直接按 Enter 維持現有設定（Ctrl+C 中止）"

    if ($choice -match '^[1-6]$') {
        $sel = $options | Where-Object { $_.Key -eq $choice }
        Write-Host " ✅ BUILD_MODE：$(if ($sel.Mode) { $sel.Mode } else { '（空白）' })  →  $($sel.Desc)"
        return $sel.Mode
    }
    Write-Host " ✅ 維持現有 BUILD_MODE：$(if ($Current) { $Current } else { '（空白）' })"
    return $Current
}

# =============================================
# Helper：Native build（Windows 本機直接呼叫 mvn，不走 Docker）
# 邏輯與 entrypoint.sh 一致：依 BuildMode / BuildModules 執行 mvn，並收集 WAR / batch-task JAR
# =============================================
function Invoke-NativeBuild {
    param(
        [string]$Mvn,
        [string]$JavaHome,
        [string]$RepoPath,
        [string]$OutputPath,
        [string]$BuildMode,
        [string]$BuildModules
    )

    if ($JavaHome) {
        $env:JAVA_HOME = $JavaHome
        $env:PATH = "$(Join-Path $JavaHome 'bin')$([System.IO.Path]::PathSeparator)$env:PATH"
    }

    $fepPath      = Join-Path $RepoPath "source\fep"
    $assemblyArgs = @("-Dassembly-output-path=$OutputPath", "-Dassembly-batch-task-output-path=$OutputPath")
    $collectWar   = $false
    $collectJar   = $true

    if ($BuildModules) {
        Write-Host " [Maven] 部分建置：$BuildModules"
        Push-Location $fepPath
        & $Mvn clean install -pl $BuildModules -am @assemblyArgs -f pom.xml -B
        Test-StepResult "mvn 部分 build（$BuildModules）"
        if ($BuildModules -match "fep-web") {
            & $Mvn install -pl fep-web -Pwar -am @assemblyArgs -f pom.xml -B
            Test-StepResult "mvn fep-web WAR"
            $collectWar = $true
        }
        Pop-Location
    } else {
        switch ($BuildMode) {
            "+web" {
                Write-Host " [Maven] 全 build + WAR"
                Push-Location $fepPath
                & $Mvn clean install @assemblyArgs -f pom.xml -B
                Test-StepResult "mvn clean install"
                & $Mvn install -pl fep-web -Pwar -am @assemblyArgs -f pom.xml -B
                Test-StepResult "mvn fep-web WAR"
                Pop-Location
                $collectWar = $true
            }
            "-Pwar" {
                Write-Host " [Maven] 全 build（JAR + WAR）"
                Push-Location $fepPath
                & $Mvn clean install -Pwar @assemblyArgs -f pom.xml -B
                Test-StepResult "mvn clean install -Pwar"
                Pop-Location
                $collectWar = $true
            }
            "-web" {
                Write-Host " [Maven] 僅 fep-web WAR"
                Push-Location $fepPath
                & $Mvn clean install -pl fep-web -Pwar -am @assemblyArgs -f pom.xml -B
                Test-StepResult "mvn fep-web WAR"
                Pop-Location
                $collectJar = $false
                $collectWar = $true
            }
            "-enclib" {
                Write-Host " [Maven] 僅 enclib"
                Push-Location (Join-Path $RepoPath "enclib\fep-enclib")
                & $Mvn clean install -pl enclib -am -f pom.xml -B
                Test-StepResult "mvn enclib"
                Pop-Location
                $collectJar = $false
            }
            "-safeaa" {
                Write-Host " [Maven] 僅 safeaa"
                Push-Location (Join-Path $RepoPath "safeaa")
                & $Mvn clean install -f pom.xml -B
                Test-StepResult "mvn safeaa"
                Pop-Location
                $collectJar = $false
            }
            default {
                Write-Host " [Maven] 全 build（僅 JAR）"
                Push-Location $fepPath
                & $Mvn clean install @assemblyArgs -f pom.xml -B
                Test-StepResult "mvn clean install"
                Pop-Location
            }
        }
    }

    if ($collectJar) {
        $batchDir = Join-Path $RepoPath "source\fep-assembly-batch-task"
        if (Test-Path $batchDir) {
            Get-ChildItem $batchDir -Filter "fep-batch-task*.jar" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Copy-Item $_.FullName $OutputPath -Force
                    Write-Host " [Output] 收集 $($_.Name)"
                }
        }
    }

    if ($collectWar) {
        $warFile = Join-Path $RepoPath "source\fep-war\fep-web.war"
        if (Test-Path $warFile) {
            Copy-Item $warFile $OutputPath -Force
            Write-Host " [Output] 收集 fep-web.war"
        } else {
            Write-Host " ⚠️  找不到 WAR：$warFile" -ForegroundColor Yellow
        }
    }
}

# =============================================
# [6/7] Maven build（可 skip，連帶 skip [7/7] 整理）
# =============================================
$skipBuild = $false
$AutoModules = @()
Write-Host ""
Write-Host "------------------------------------------------"
Write-Host " 輸出路徑：$OutputPath"
Write-Host "------------------------------------------------"
$step6Choice = Read-Host "[6/7] Maven build  [S] 略過（連帶略過 [7/7] 整理）/ [Enter] 執行"
if ($step6Choice -ieq "S") {
    $skipBuild = $true
    Write-Host " ⏭️  略過 build，自動略過 [7/7] 整理"
}

if ($skipBuild) {
    Write-Host ""
    Write-Host "[6/7] build → 已略過"
} else {
    $AutoModules  = Get-MavenModules -TxtPath $env:RELEASE_NOTE_INPUT
    $BuildMode    = $EnvVars["BUILD_MODE"]
    $BuildModules = ""

    $isCmdlineOnly = ($AutoModules | Where-Object { $_ -notmatch "cmdline" }).Count -eq 0 -and $AutoModules.Count -gt 0

    Write-Host ""
    Write-Host "[6/7] Maven 包版"
    Write-Host "------------------------------------------------"
    Write-Host " Branch   : $GitBranch（由本 script 指定，覆蓋 .env）"
    Write-Host " GIT_PULL : $($EnvVars['GIT_PULL'])"
    Write-Host " 輸出路徑 : $OutputPath"
    Write-Host ""

    if ($BranchType -eq 'UAT') {
        # UAT：直接全 build，選 BUILD_MODE
        Write-Host " UAT 模式：全 build"
        $BuildMode = Select-BuildMode -Current $BuildMode
    } else {
        if ($isCmdlineOnly) {
            Write-Host " 📋 release note 僅含 cmdline 模組，不需要包版" -ForegroundColor Yellow
            Read-Host " 按 Enter 結束，或按 Ctrl+C 中止"
            exit 0
        }

        $txtSource = if ($step3Choice -ieq "S") { "⚠️  使用既有 txt（非本次下載）" } else { "本次下載" }
        Write-Host " [A] 全 build（手動選擇 BUILD_MODE）"
        if ($AutoModules.Count -gt 0) {
            Write-Host " [B] 依 release note 部分 build  【來源：$txtSource】"
            Write-Host "     偵測到的 Maven 模組：$($AutoModules -join ', ')"
        } else {
            Write-Host " [B] 依 release note 部分 build  ⚠️  未偵測到可對應模組，無法選擇"
        }
        Write-Host "------------------------------------------------"
        $buildChoice = Read-Host " 請選擇 [A/B]（預設 B）"
        if ($buildChoice -match '^\s*$') { $buildChoice = "B" }

        Write-Host ""
        if ($buildChoice -ieq "B" -and $AutoModules.Count -gt 0) {
            $BuildModules = $AutoModules -join ","
            Write-Host " ✅ 部分 build 模組：$BuildModules"
        } else {
            $BuildMode = Select-BuildMode -Current $BuildMode
        }
    }

    $env:BUILD_MODE    = $BuildMode
    $env:BUILD_MODULES = $BuildModules
    $env:BRANCH        = $GitBranch

    # Windows：手動選擇 Native / Docker 建置方式
    $useNative      = $false
    $NativeMvnCmd   = "mvn"
    $NativeJavaHome = $EnvVars["JAVA_HOME"]

    if ($IsWindows) {
        Write-Host ""
        Write-Host " [N] Native build（直接呼叫 mvn，速度較快）"
        Write-Host " [D] Docker container build"
        $platformChoice = Read-Host " 請選擇 [N/D]（預設 N）"
        $useNative = $platformChoice -inotmatch '^[Dd]'
    }

    if ($useNative) {
        Write-Host ""
        Write-Host " 🔨 Native build 開始"
        Write-Host "------------------------------------------------"
        Invoke-NativeBuild `
            -Mvn         $NativeMvnCmd `
            -JavaHome    $NativeJavaHome `
            -RepoPath    $RepoPath `
            -OutputPath  $OutputPath `
            -BuildMode   $BuildMode `
            -BuildModules $BuildModules
    } else {
        # [Windows 限定] Maven cache volume 初始化檢查（僅在 volume 不存在時觸發）
        if ($IsWindows) {
            $m2Path = $EnvVars["M2_PATH"]
            if ($m2Path -and -not ($m2Path -match '[/\\]')) {
                $null = docker volume inspect $m2Path 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $localM2 = "C:\Users\$UserName\.m2"
                    Write-Host ""
                    Write-Host " ⚠️  Maven cache volume '$m2Path' 尚未建立（首次使用）" -ForegroundColor Yellow
                    if (Test-Path $localM2) {
                        Write-Host " 偵測到本機 .m2：$localM2"
                        $initChoice = Read-Host " 是否將現有 .m2 複製進 volume？（Y/Enter=是，N=略過，略過則 Maven 需重新下載 ~2.5GB）"
                        if ($initChoice -inotmatch '^[Nn]') {
                            Write-Host " 複製中，請稍候（約 1~2 分鐘）..."
                            docker run --rm -v "${m2Path}:/target" -v "${localM2}:/source:ro" alpine sh -c "cp -a /source/. /target/"
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host " ✅ Maven cache 已複製至 volume：$m2Path" -ForegroundColor Green
                            } else {
                                Write-Host " ❌ 複製失敗，後續 build 將從網路重新下載依賴" -ForegroundColor Red
                            }
                        } else {
                            Write-Host " ⏭️  略過複製，Maven 將在 build 時從網路下載依賴" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host " ℹ️  未找到本機 .m2（$localM2），Maven 將在 build 時自動下載依賴"
                    }
                }
            }
        }

        Set-Location $DockerBuildDir
        docker compose --env-file $EnvFileName run --rm fep-builder
        Test-StepResult "Docker build"
        Set-Location $RepoPath
    }
}

# =============================================
# [7/7] 整理產出物（[6/7] skip 則自動 skip）
# =============================================
Write-Host ""
Write-Host "------------------------------------------------"
Write-Host " 📦 [7/7] 整理產出物"
Write-Host "------------------------------------------------"

$DeployPath = $OutputPath  # 若 skip build 則 OpenPath 指向 OutputPath

if ($skipBuild) {
    Write-Host "[7/7] 整理產出物 → [6/7] 已略過，自動略過"
} else {
    $step7Choice = Read-Host " [S] 略過整理 / [Enter] 執行"
    if ($step7Choice -ieq "S") {
        Write-Host " ⏭️  略過整理"
    } else {
        # 建立時間戳資料夾：build-output/<Branch>/yyyyMMddHHmm[-all]/
        $timestamp      = Get-Date -Format "yyyyMMddHHmm"
        $folderName     = if (-not $BuildModules -and $BranchType -ne 'UAT') { "${timestamp}-all" } else { $timestamp }
        $BuildOutputDir = Join-Path (Split-Path $OutputPath -Parent) "build-output"
        $DeployPath     = Join-Path $BuildOutputDir $GitBranch $folderName
        $FepAppPath     = Join-Path $DeployPath "fep-app"
        New-Item -ItemType Directory -Path $FepAppPath -Force | Out-Null
        Write-Host " 目的資料夾：$DeployPath"
        Write-Host ""

        # 載入模組清單（fetch_release_script.py 產出的 BuildModuleData.json）
        $Services  = @()
        $BatchJars = @()
        $moduleDataFile = Join-Path $ScriptDir "BuildModuleData.json"
        if (Test-Path $moduleDataFile) {
            $moduleData = Get-Content $moduleDataFile -Raw | ConvertFrom-Json
            $Services   = @($moduleData.services)
            $BatchJars  = @($moduleData.batch_jars)
            Write-Host " 服務清單（H 欄）：$($Services -join ', ')"
            Write-Host " Batch JAR（I 欄）：$($BatchJars -join ', ')"
        } else {
            Write-Host " ⚠️  找不到 BuildModuleData.json，將解壓全部 bin tar.gz" -ForegroundColor Yellow
        }
        Write-Host ""

        if ($BuildModules) {
            # 部分 build：依 H 欄服務清單整理
            if ($Services.Count -gt 0) {
                foreach ($service in $Services) {
                    if ($service -eq "fep-web") {
                        # WAR：複製到 fep-app/
                        $warFile = Get-ChildItem $OutputPath -Filter "fep-web.war" -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($warFile) {
                            Copy-Item $warFile.FullName $FepAppPath -Force
                            Write-Host " [war]  複製：$($warFile.Name) → fep-app/"
                        } else {
                            Write-Host " ⚠️  找不到 fep-web.war" -ForegroundColor Yellow
                        }
                    } elseif ($service -eq "fep-batch-task") {
                        # fep-batch-task：無 tar.gz，僅複製 I 欄 fep-batch-task- 開頭的 jar 到 fep-app/
                        foreach ($jar in ($BatchJars | Where-Object { $_ -like 'fep-batch-task-*' })) {
                            $jarFile = Get-ChildItem $OutputPath -Filter $jar -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($jarFile) {
                                Copy-Item $jarFile.FullName $FepAppPath -Force
                                Write-Host " [jar]  複製：$($jarFile.Name) → fep-app/"
                            } else {
                                Write-Host " ⚠️  找不到 jar：$jar" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        # 一般服務：解壓 bin tar.gz
                        # Pattern 1: {service}-bin*.tar.gz（如 fep-batch-cmdline → fep-batch-cmdline-bin.tar.gz）
                        $tarFiles = Get-ChildItem $OutputPath -Filter "$service-bin*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object Name
                        if (-not $tarFiles) {
                            # Pattern 2: {base}-bin-{suffix}*.tar.gz（如 fep-server-atm → fep-server-bin-atm.tar.gz）
                            $lastDash = $service.LastIndexOf('-')
                            if ($lastDash -gt 0) {
                                $altFilter = "$($service.Substring(0, $lastDash))-bin-$($service.Substring($lastDash + 1))*.tar.gz"
                                $tarFiles = Get-ChildItem $OutputPath -Filter $altFilter -ErrorAction SilentlyContinue | Sort-Object Name
                            }
                        }
                        if ($tarFiles) {
                            foreach ($tar in $tarFiles) {
                                Write-Host " [tar]  解壓縮：$($tar.Name)"
                                tar -xzf $tar.FullName -C $DeployPath
                            }
                        } else {
                            Write-Host " ⚠️  找不到 $service 的 bin tar.gz" -ForegroundColor Yellow
                        }
                    }
                }
            } else {
                Write-Host " ⚠️  BuildModuleData.json 無服務清單，將解壓全部 bin tar.gz" -ForegroundColor Yellow
                Get-ChildItem $OutputPath -Filter "*-bin*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object Name |
                    ForEach-Object { Write-Host " [tar]  解壓縮：$($_.Name)"; tar -xzf $_.FullName -C $DeployPath }
            }
        } else {
            # 全 build / UAT：解壓全部 tar.gz + 複製 war + 複製所有 jar
            $allTars = Get-ChildItem $OutputPath -Filter "*-bin*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object Name
            if ($allTars) {
                foreach ($tar in $allTars) {
                    Write-Host " [tar]  解壓縮：$($tar.Name)"
                    tar -xzf $tar.FullName -C $DeployPath
                }
            } else {
                Write-Host " ⚠️  OutputPath 中找不到任何 bin tar.gz" -ForegroundColor Yellow
            }

            $warFile = Get-ChildItem $OutputPath -Filter "fep-web.war" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($warFile) {
                Copy-Item $warFile.FullName $FepAppPath -Force
                Write-Host " [war]  複製：$($warFile.Name) → fep-app/"
            }

            Get-ChildItem $OutputPath -Filter "*.jar" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Copy-Item $_.FullName $FepAppPath -Force
                    Write-Host " [jar]  複製：$($_.Name) → fep-app/"
                }
        }

        # 清除 macOS 產生的 ._ resource fork 檔案
        Get-ChildItem $DeployPath -Filter "._*" -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host " 🧹 已清除 ._ 隱藏檔案"
    }
}

$OpenPath = if (Test-Path $DeployPath) { $DeployPath } else { $OutputPath }

Write-Host ""
Write-Host " 📂 產出物列表："
if (Test-Path $OpenPath) {
    Get-ChildItem $OpenPath | ForEach-Object { Write-Host "   $($_.Name)" }
    Invoke-Item $OpenPath
} else {
    Write-Host "   （資料夾不存在）"
}
Write-Host ""
Write-Host "------------------------------------------------"
Write-Host " ⚠️  請確認產出物是否正確"
Write-Host " 📁 輸出路徑：$OpenPath"
Write-Host "------------------------------------------------"
Read-Host " 確認無誤後按 Enter 繼續，或按 Ctrl+C 中止"

# =============================================
# Config 提醒
# =============================================
$ConfigFolder = switch ($BranchType) {
    "1-3_SIT" { Join-Path $RepoPath "source" "SIT套config" }
    "UAT"     { Join-Path $RepoPath "source" "UAT套config" }
    "2-1_SIT" { Join-Path $RepoPath "source" "SIT套config" }
    "2-2_SIT" { Join-Path $RepoPath "source" "SIT套config" }
    "2-3_SIT" { Join-Path $RepoPath "source" "SIT套config" }
}

Write-Host ""
if (Test-Path $ConfigFolder) {
    Invoke-Item $ConfigFolder
} else {
    Write-Host " ⚠️  Config 資料夾不存在：$ConfigFolder"
}
Write-Host "================================================"
Write-Host " ⚠️  請記得套用 $BranchType Config"
Write-Host " 📁 Config 路徑：$ConfigFolder"
Write-Host "================================================"
Read-Host " 確認 Config 無誤後按 Enter 結束"

Write-Host ""
Write-Host "================================================"
Write-Host " ✅ 完成"
Write-Host "================================================"

} finally {
    Set-Location $OriginalLocation
}
